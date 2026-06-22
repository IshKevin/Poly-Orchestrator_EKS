#!/bin/bash
# Full kubeadm deployment — runs end-to-end:
#   1. Terraform provisions infra (EC2 nodes, RDS, Redis, ECR, NLB)
#   2. Docker images built and pushed to ECR
#   3. Ansible configures the kubeadm cluster
#   4. kubectl deploys the application
#
# Prerequisites:
#   - AWS CLI configured (aws configure)
#   - Terraform >= 1.6, Ansible >= 2.14, kubectl, jq, docker
#   - EC2 key pair created and PEM file at ~/.ssh/<key_pair_name>.pem
#   - kubeadm/terraform/terraform.tfvars filled in from terraform.tfvars.example
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."
TF_DIR="${SCRIPT_DIR}/../terraform"
ANSIBLE_DIR="${SCRIPT_DIR}/../ansible"
K8S_DIR="${SCRIPT_DIR}/../k8s"

log() { echo "==> $*"; }

# ── Step 1: Provision infrastructure ─────────────────────────────────────────

log "[1/6] Provisioning infrastructure with Terraform"
terraform -chdir="${TF_DIR}" init -input=false
terraform -chdir="${TF_DIR}" apply -auto-approve -input=false

# ── Step 2: Build and push Docker images ──────────────────────────────────────

log "[2/6] Building and pushing Docker images to ECR"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_BACKEND=$(terraform -chdir="${TF_DIR}" output -raw ecr_backend_url)
ECR_FRONTEND=$(terraform -chdir="${TF_DIR}" output -raw ecr_frontend_url)
ECR_REGISTRY=$(terraform -chdir="${TF_DIR}" output -raw ecr_registry)

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

docker build -t "${ECR_BACKEND}:latest" "${REPO_ROOT}/app/backend"
docker push "${ECR_BACKEND}:latest"

docker build -t "${ECR_FRONTEND}:latest" "${REPO_ROOT}/app/frontend"
docker push "${ECR_FRONTEND}:latest"

# ── Step 3: Generate Ansible inventory ────────────────────────────────────────

log "[3/6] Generating Ansible inventory from Terraform outputs"
bash "${SCRIPT_DIR}/generate-inventory.sh"

CONTROL_PLANE_IP=$(terraform -chdir="${TF_DIR}" output -raw control_plane_public_ip)
CONTROL_PLANE_PRIVATE_IP=$(terraform -chdir="${TF_DIR}" output -raw control_plane_private_ip)
KEY_PAIR_NAME=$(terraform -chdir="${TF_DIR}" output -raw key_pair_name)
SSH_KEY="${HOME}/.ssh/${KEY_PAIR_NAME}.pem"
NLB_DNS=$(terraform -chdir="${TF_DIR}" output -raw nlb_dns_name)
RDS_HOST=$(terraform -chdir="${TF_DIR}" output -raw rds_host)
REDIS_ENDPOINT=$(terraform -chdir="${TF_DIR}" output -raw redis_endpoint)

log "    Waiting 60s for EC2 instances to finish booting..."
sleep 60

# ── Step 4: Configure cluster with Ansible ────────────────────────────────────

log "[4/6] Configuring kubeadm cluster with Ansible"
cd "${ANSIBLE_DIR}"
ansible-playbook site.yml \
  -i inventory.ini \
  -e @extravars.yml \
  -e "control_plane_public_ip=${CONTROL_PLANE_IP}" \
  -e "control_plane_private_ip=${CONTROL_PLANE_PRIVATE_IP}"

# ── Step 5: Fetch kubeconfig ──────────────────────────────────────────────────

log "[5/6] Fetching kubeconfig from control-plane"
KUBECONFIG_PATH="${HOME}/.kube/kubeadm-shopnow"
mkdir -p "${HOME}/.kube"
scp -i "${SSH_KEY}" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "ubuntu@${CONTROL_PLANE_IP}:/home/ubuntu/.kube/config" \
  "${KUBECONFIG_PATH}"
export KUBECONFIG="${KUBECONFIG_PATH}"
log "    Kubeconfig saved to ${KUBECONFIG_PATH}"

# ── Step 6: Deploy application ────────────────────────────────────────────────

log "[6/6] Deploying ShopNow application"

# Create ECR image pull secret (valid for 12 hours; re-run this step to refresh)
log "    Creating ECR image pull secret"
aws ecr get-login-password --region "${AWS_REGION}" \
  | kubectl create secret docker-registry ecr-secret \
      --docker-server="${ECR_REGISTRY}" \
      --docker-username=AWS \
      --docker-password-stdin \
      --namespace=shopnow \
      --dry-run=client -o yaml \
  | kubectl apply -f -

# Substitute placeholders in a temp copy of the manifests
TMP_K8S=$(mktemp -d)
cp -r "${K8S_DIR}/." "${TMP_K8S}/"

sed -i "s|REPLACE_WITH_RDS_HOST|${RDS_HOST}|g"              "${TMP_K8S}/configmap.yaml"
sed -i "s|REPLACE_WITH_REDIS_ENDPOINT|${REDIS_ENDPOINT}|g"  "${TMP_K8S}/configmap.yaml"
sed -i "s|REPLACE_WITH_ECR_BACKEND_URL|${ECR_BACKEND}|g"    "${TMP_K8S}/backend/deployment.yaml"
sed -i "s|REPLACE_WITH_ECR_FRONTEND_URL|${ECR_FRONTEND}|g"  "${TMP_K8S}/frontend/deployment.yaml"

log "    Applying Kubernetes manifests"
kubectl apply -f "${TMP_K8S}/namespace.yaml"
kubectl apply -f "${TMP_K8S}/configmap.yaml"
kubectl apply -f "${TMP_K8S}/secrets.yaml"
kubectl apply -f "${TMP_K8S}/backend/"
kubectl apply -f "${TMP_K8S}/frontend/"
kubectl apply -f "${TMP_K8S}/ingress.yaml"

rm -rf "${TMP_K8S}"

log "    Waiting for deployments to be ready (up to 5 min)..."
kubectl rollout status deployment/backend  -n shopnow --timeout=300s
kubectl rollout status deployment/frontend -n shopnow --timeout=300s

echo ""
echo "==> Deploy complete!"
echo ""
echo "    App URL:        http://${NLB_DNS}"
echo "    Kubeconfig:     export KUBECONFIG=${KUBECONFIG_PATH}"
echo "    Control plane:  ssh -i ${SSH_KEY} ubuntu@${CONTROL_PLANE_IP}"
echo ""
echo "    To refresh the ECR pull secret after 12 hours:"
echo "      KUBECONFIG=${KUBECONFIG_PATH} bash ${SCRIPT_DIR}/deploy.sh  # or just re-run step 6"
echo ""
echo "    To update images after a code change:"
echo "      docker build -t ${ECR_BACKEND}:latest ${REPO_ROOT}/app/backend && docker push ${ECR_BACKEND}:latest"
echo "      KUBECONFIG=${KUBECONFIG_PATH} kubectl rollout restart deployment/backend -n shopnow"
