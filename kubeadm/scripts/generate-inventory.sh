#!/bin/bash
# Reads Terraform outputs and generates:
#   - kubeadm/ansible/inventory.ini  (Ansible SSH inventory)
#   - kubeadm/ansible/extravars.yml  (extra-vars for ansible-playbook)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"
ANSIBLE_DIR="${SCRIPT_DIR}/../ansible"

log() { echo "==> $*"; }

log "Reading Terraform outputs..."

CONTROL_PLANE_PUBLIC_IP=$(terraform -chdir="${TF_DIR}" output -raw control_plane_public_ip)
CONTROL_PLANE_PRIVATE_IP=$(terraform -chdir="${TF_DIR}" output -raw control_plane_private_ip)
WORKER_PUBLIC_IPS=$(terraform -chdir="${TF_DIR}" output -json worker_public_ips | jq -r '.[]')
KEY_PAIR_NAME=$(terraform -chdir="${TF_DIR}" output -raw key_pair_name)
RDS_HOST=$(terraform -chdir="${TF_DIR}" output -raw rds_host)
REDIS_ENDPOINT=$(terraform -chdir="${TF_DIR}" output -raw redis_endpoint)
ECR_BACKEND=$(terraform -chdir="${TF_DIR}" output -raw ecr_backend_url)
ECR_FRONTEND=$(terraform -chdir="${TF_DIR}" output -raw ecr_frontend_url)
ECR_REGISTRY=$(terraform -chdir="${TF_DIR}" output -raw ecr_registry)
AWS_REGION=$(terraform -chdir="${TF_DIR}" output -raw aws_region)

SSH_KEY="${HOME}/.ssh/${KEY_PAIR_NAME}.pem"
SSH_ARGS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# ── inventory.ini ─────────────────────────────────────────────────────────────

INVENTORY_FILE="${ANSIBLE_DIR}/inventory.ini"
{
  echo "[control_plane]"
  echo "control-plane ansible_host=${CONTROL_PLANE_PUBLIC_IP} ansible_user=ubuntu ansible_ssh_private_key_file=${SSH_KEY} ansible_ssh_common_args='${SSH_ARGS}'"
  echo ""
  echo "[workers]"
  i=1
  while IFS= read -r ip; do
    echo "worker-${i} ansible_host=${ip} ansible_user=ubuntu ansible_ssh_private_key_file=${SSH_KEY} ansible_ssh_common_args='${SSH_ARGS}'"
    i=$((i + 1))
  done <<< "${WORKER_PUBLIC_IPS}"
  echo ""
  echo "[k8s_cluster:children]"
  echo "control_plane"
  echo "workers"
} > "${INVENTORY_FILE}"

# ── extravars.yml ─────────────────────────────────────────────────────────────

EXTRAVARS_FILE="${ANSIBLE_DIR}/extravars.yml"
{
  echo "control_plane_public_ip: \"${CONTROL_PLANE_PUBLIC_IP}\""
  echo "control_plane_private_ip: \"${CONTROL_PLANE_PRIVATE_IP}\""
  echo "rds_host: \"${RDS_HOST}\""
  echo "redis_endpoint: \"${REDIS_ENDPOINT}\""
  echo "ecr_backend_url: \"${ECR_BACKEND}\""
  echo "ecr_frontend_url: \"${ECR_FRONTEND}\""
  echo "ecr_registry: \"${ECR_REGISTRY}\""
  echo "aws_region: \"${AWS_REGION}\""
} > "${EXTRAVARS_FILE}"

log "Generated ${INVENTORY_FILE}"
log "Generated ${EXTRAVARS_FILE}"
log "Control plane: ${CONTROL_PLANE_PUBLIC_IP} (private: ${CONTROL_PLANE_PRIVATE_IP})"
log "SSH key:       ${SSH_KEY}"
