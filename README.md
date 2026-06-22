# Poly-Orchestrator EKS — ShopNow on Kubernetes

## Project Summary

This project deploys **ShopNow**, a 3-tier e-commerce application, across three different Kubernetes environments to demonstrate how the same workload can be orchestrated in fundamentally different ways — from a local development cluster all the way to a fully managed cloud setup and a self-managed bare-metal-style cluster on EC2.

The three options covered are:

| Option | Environment | Kubernetes Type |
|---|---|---|
| 1 | Local (Minikube) | Single-node local cluster |
| 2 | AWS EKS | AWS-managed control plane |
| 3 | EC2 (kubeadm + Ansible) | Self-managed cluster |

---

## Application Architecture

ShopNow is a standard 3-tier web app:

- **Frontend** — Node.js / Express: serves the SPA and proxies `/api` calls to the backend
- **Backend** — Python Flask: REST API handling products, cart, and orders
- **Database** — PostgreSQL (RDS in AWS, containerized in local)
- **Cache / Sessions** — Redis (ElastiCache in AWS, containerized in local)

### Traffic Flow (EKS / Production)

```
Internet
   │
   ▼
[ALB] ← provisioned by AWS Load Balancer Controller via Ingress
   │
   ├── /api/*  ──▶  [Backend Service]  ──▶  [Backend Pods]
   │                                              │
   └── /*      ──▶  [Frontend Service] ──▶  [Frontend Pods]
                                                  │
                                           [RDS PostgreSQL]
                                           [ElastiCache Redis]
                                           (both in private subnets)
```

---

## Option 1 — Local (Minikube)

For local development and testing, the app runs on a single-node Minikube cluster. PostgreSQL and Redis run as Kubernetes workloads (no managed cloud services needed).

**What I built:**
- Kubernetes manifests for all app components under `k8s/local/`
- Postgres and Redis deployed as in-cluster pods (replacing RDS/ElastiCache)
- NGINX ingress for local routing
- Jenkins container setup for a local CI environment (`local/jenkins/`)

This option demonstrates how to replicate a cloud-like Kubernetes setup entirely on a laptop.

---

## Option 2 — Amazon EKS (Fully Managed)

The production deployment uses Amazon EKS, AWS's managed Kubernetes service. All infrastructure is provisioned with Terraform, organized into 8 modules.

**What I built:**

### Infrastructure (Terraform)

| Module | What it provisions |
|---|---|
| `networking` | VPC, public/private subnets, IGW, NAT Gateway |
| `security` | Security groups for ALB, EKS nodes, RDS, Redis |
| `ecr` | Elastic Container Registry repos for backend and frontend |
| `eks` | EKS cluster (Kubernetes 1.30), managed node group (`t3.medium`) |
| `alb-controller` | AWS Load Balancer Controller via IRSA + Helm |
| `rds` | RDS PostgreSQL 16 in private subnets |
| `elasticache` | ElastiCache Redis 7 in private subnets |
| `jenkins` | Optional Jenkins EC2 instance for CI/CD |

### Kubernetes Workloads

- Backend and frontend deployments with **HorizontalPodAutoscaler** (min 2 / max 6 pods, scales at 60% CPU)
- **ALB Ingress** routing `/api/*` to backend and `/*` to frontend
- ConfigMap for environment variables, Kubernetes Secret for database credentials

### Key Design Decisions

**Two-step Terraform apply** — The EKS cluster must exist before the Helm and Kubernetes Terraform providers can initialize, because they need the cluster endpoint at plan time. I solved this by splitting the apply: first `terraform apply -target=module.eks`, then `terraform apply` for everything else. This is encoded in `production/scripts/initial-deploy.sh`.

**IRSA (IAM Roles for Service Accounts)** — Instead of giving nodes broad IAM permissions, the ALB controller gets a dedicated IAM role bound to its Kubernetes service account via OIDC federation. This follows the least-privilege principle.

**IP target mode for ALB** — The ingress is configured in IP target mode so the ALB routes directly to pod IPs rather than going through NodePort, reducing one network hop.

### CI/CD with Jenkins

The `production/Jenkinsfile` defines a pipeline that:
1. Runs backend (pytest) and frontend (npm test) tests **in parallel**
2. Builds and pushes Docker images to ECR with a git-tag-based version
3. Performs rolling updates via `kubectl set image` + `kubectl rollout status`

---

## Option 3 — Self-Managed Kubernetes on EC2 (kubeadm + Ansible)

This option deliberately avoids EKS to demonstrate what running Kubernetes without a managed control plane looks like. Terraform provisions raw EC2 instances; Ansible installs and configures kubeadm on them.

**What I built:**

### Infrastructure (Terraform — flat, no modules)

A single Terraform configuration provisions:
- VPC, subnets, security groups, IAM roles
- 1 control-plane EC2 node + 2 worker nodes (all `t3.medium`, Ubuntu 22.04)
- RDS PostgreSQL and ElastiCache Redis (same as EKS option)
- ECR repos for container images
- **Network Load Balancer** targeting worker NodePort 30080 — this is the app's public URL

No modules were used here intentionally, to keep the infrastructure visible in one file rather than abstracted.

### Cluster Setup (Ansible — 4 roles)

| Role | What it does |
|---|---|
| `common` | Installs containerd, kubeadm, kubelet, kubectl on all nodes |
| `control-plane` | Runs `kubeadm init`, installs Calico CNI, exposes kubeconfig |
| `worker` | Runs `kubeadm join` to attach each worker to the cluster |
| `cluster-addons` | Installs nginx-ingress via Helm, installs metrics-server |

A helper script (`generate-inventory.sh`) reads Terraform outputs and automatically writes the Ansible inventory file, so there's no manual IP copying between the two tools.

### Key Design Decisions

**No AWS Cloud Controller Manager** — Unlike EKS, a self-managed cluster has no AWS CCM. Instead of trying to integrate one, the NLB is owned entirely by Terraform and hardcoded to target worker NodePort 30080. This keeps the cluster portable and avoids cloud-specific dependencies inside Kubernetes.

**Calico CNI** — Chosen over Flannel for its support of NetworkPolicy, which allows fine-grained pod-to-pod traffic control if needed later. Pod CIDR is `192.168.0.0/16` (Calico's default, chosen to avoid overlap with the VPC CIDR `10.0.0.0/16`).

**ECR pull via imagePullSecret** — kubeadm nodes have no built-in ECR credential helper. The deploy script logs into ECR and creates a short-lived `ecr-secret` in the cluster so pods can pull images. The secret is valid for 12 hours (AWS ECR token lifetime).

**kubeconfig patched to public IP** — By default, `kubeadm init` writes the control-plane's private IP into the kubeconfig. The Ansible role patches this to the public IP so `kubectl` works from outside AWS without a VPN. The API server certificate also includes the public IP via `--apiserver-cert-extra-sans`.

### Architecture

```
Internet
   │
   ▼
[NLB :80] ← Terraform-provisioned, targets worker NodePort 30080
   │
   ▼
[nginx-ingress (NodePort 30080)]
   │
   ├── /api/*  ──▶  [Backend Pods × 2]
   └── /*      ──▶  [Frontend Pods × 2]
                          │
                    [RDS PostgreSQL]
                    [ElastiCache Redis]

EC2 fleet:
  control-plane  t3.medium  (public subnet)
  worker-1       t3.medium  (public subnet)
  worker-2       t3.medium  (public subnet)
```

---

## Comparison: EKS vs kubeadm

| | EKS (Option 2) | kubeadm on EC2 (Option 3) |
|---|---|---|
| Control plane | AWS-managed | Self-managed on EC2 |
| Ingress | AWS ALB (via ALB Controller + IRSA) | nginx-ingress + Terraform NLB |
| CNI | AWS VPC CNI | Calico |
| Node scaling | Managed node group (auto-scaling) | Fixed EC2 count |
| Cloud integration | Native (IAM, ALB, ECR credential helper) | Manual (imagePullSecret, NLB in Terraform) |
| Operational overhead | Low | High — you own the control plane |
| Best for | Production workloads | Learning, on-prem-style environments |

---

## Repository Structure

```
.
├── app/                        # Shared application source code
│   ├── backend/                # Python Flask API + Dockerfile
│   ├── frontend/               # Node.js frontend + Dockerfile
│   └── docker-compose.yml      # Local run without Kubernetes
│
├── k8s/
│   ├── local/                  # Minikube manifests (includes postgres + redis pods)
│   └── production/             # EKS/AWS manifests (uses RDS + ElastiCache)
│
├── production/                 # EKS option
│   ├── terraform/              # 8-module Terraform (VPC → EKS → ALB → RDS → Redis)
│   ├── scripts/
│   │   └── initial-deploy.sh   # Automated two-step bootstrap
│   └── Jenkinsfile             # CI/CD pipeline
│
├── kubeadm/                    # Self-managed option
│   ├── terraform/              # Flat Terraform (EC2 nodes, NLB, RDS, Redis, ECR)
│   ├── ansible/                # 4-role playbook (common → control-plane → worker → addons)
│   ├── k8s/                    # Manifests with nginx IngressClass + imagePullSecrets
│   └── scripts/
│       ├── deploy.sh           # End-to-end orchestrator
│       └── generate-inventory.sh  # Terraform outputs → Ansible inventory
│
└── local/
    ├── jenkins/                # Jenkins Docker container setup
    └── scripts/
        └── install-jenkins.sh
```
