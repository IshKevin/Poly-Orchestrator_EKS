#!/bin/bash
# Initial deploy — run once from your local machine to bootstrap the full stack.
# After this, Jenkins handles all subsequent deploys on code push.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-shopnow}"
ENV_NAME="${ENV_NAME:-dev}"
EKS_CLUSTER="${PROJECT_NAME}-${ENV_NAME}-cluster"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."

log() { echo "==> $*"; }

# ── Step 1: Create ECR repos ──────────────────────────────────────────────────
log "[1/5] Creating ECR repositories"
cd "${REPO_ROOT}/production/terraform"
terraform init -input=false
terraform apply -auto-approve -input=false -target=module.ecr

# ── Step 2: Build & push Docker images ───────────────────────────────────────
log "[2/5] Building and pushing Docker images"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_FRONTEND="${ECR_BASE}/${PROJECT_NAME}-${ENV_NAME}-frontend"
ECR_BACKEND="${ECR_BASE}/${PROJECT_NAME}-${ENV_NAME}-backend"

log "    Frontend: ${ECR_FRONTEND}"
log "    Backend:  ${ECR_BACKEND}"

aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${ECR_BASE}"

docker build -t "${ECR_FRONTEND}:latest" "${REPO_ROOT}/app/frontend"
docker push "${ECR_FRONTEND}:latest"

docker build -t "${ECR_BACKEND}:latest" "${REPO_ROOT}/app/backend"
docker push "${ECR_BACKEND}:latest"

# ── Step 3: Provision EKS cluster first (providers depend on it) ──────────────
log "[3/5] Provisioning EKS cluster (required before Helm/Kubernetes providers)"
terraform apply -auto-approve -input=false \
    -target=module.networking \
    -target=module.security \
    -target=module.rds \
    -target=module.elasticache \
    -target=module.eks

# ── Step 4: Full apply (ALB controller + Jenkins) ─────────────────────────────
log "[4/5] Provisioning remaining infrastructure (ALB controller, bastion, Jenkins)"
terraform apply -auto-approve -input=false

# ── Step 5: Deploy to Kubernetes ──────────────────────────────────────────────
log "[5/5] Deploying Kubernetes workloads"

log "    Updating kubeconfig"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER}"

log "    Patching ConfigMap with Terraform outputs"
DB_HOST=$(terraform output -raw rds_endpoint)
REDIS_HOST=$(terraform output -raw redis_endpoint)

# Substitute placeholder values in the k8s manifests
sed -i "s|REPLACE_WITH_RDS_ENDPOINT|${DB_HOST}|g"     "${REPO_ROOT}/k8s/production/configmap.yaml"
sed -i "s|REPLACE_WITH_REDIS_ENDPOINT|${REDIS_HOST}|g" "${REPO_ROOT}/k8s/production/configmap.yaml"
sed -i "s|REPLACE_WITH_ECR_BACKEND_URL|${ECR_BACKEND}|g"   "${REPO_ROOT}/k8s/production/backend/deployment.yaml"
sed -i "s|REPLACE_WITH_ECR_FRONTEND_URL|${ECR_FRONTEND}|g" "${REPO_ROOT}/k8s/production/frontend/deployment.yaml"

log "    Installing metrics-server (required for HPA)"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

log "    Applying Kubernetes manifests"
kubectl apply -f "${REPO_ROOT}/k8s/production/namespace.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/production/configmap.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/production/secrets.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/production/backend/"
kubectl apply -f "${REPO_ROOT}/k8s/production/frontend/"
kubectl apply -f "${REPO_ROOT}/k8s/production/ingress.yaml"

log "    Waiting for deployments to be ready (up to 5 min)..."
kubectl rollout status deployment/backend  -n shopnow --timeout=300s
kubectl rollout status deployment/frontend -n shopnow --timeout=300s

log "    Fetching ALB DNS name (may take 1-2 min to provision)..."
ALB_DNS=$(kubectl get ingress shopnow -n shopnow \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "provisioning...")

BASTION_ID=$(terraform output -raw bastion_instance_id 2>/dev/null || echo "")
BASTION_CMD=$(terraform output -raw bastion_ssm_command 2>/dev/null || echo "")

echo ""
echo "==> Deploy complete!"
echo "    App URL:    http://${ALB_DNS}"
echo "    Cluster:    ${EKS_CLUSTER}"
echo ""
echo "    ── Database & Redis console access (private, SSM) ──"
echo "    Bastion ID: ${BASTION_ID}"
echo "    Open shell: ${BASTION_CMD}"
echo "      (or: AWS Console → Systems Manager → Session Manager → Start Session)"
echo "    In the shell:"
echo "      psql -h \$(aws rds describe-db-instances --query 'DBInstances[0].Endpoint.Address' --output text) -U shopnow -d shopnow"
echo "      redis-cli -h \$(aws elasticache describe-cache-clusters --show-cache-node-info --query 'CacheClusters[0].CacheNodes[0].Endpoint.Address' --output text)"
echo ""
echo "    To update images in the future, push to your git branch"
echo "    and let Jenkins trigger the pipeline, or run:"
echo "      kubectl set image deployment/backend  backend=\${ECR_BACKEND}:<tag>  -n shopnow"
echo "      kubectl set image deployment/frontend frontend=\${ECR_FRONTEND}:<tag> -n shopnow"
