# Poly-Orchestrator EKS — ShopNow on Amazon EKS

ShopNow is a 3-tier e-commerce demo running on Amazon EKS (Elastic Kubernetes Service). This project is the EKS counterpart to [Poly-Orchestrator ECS](../Poly-Orchestrator_ECS/).

## Architecture Overview

```
Internet
   │
   ▼
[ALB] ← provisioned by AWS Load Balancer Controller (Ingress)
   │
   ├── /api/*  ──▶  [Backend Service:5000]  ──▶  [Backend Pods × 2-6]
   │                                                    │        │
   └── /*      ──▶  [Frontend Service:3000] ──▶  [Frontend Pods × 2-6]
                                                        │        │
                                                   [RDS PG]  [ElastiCache Redis]
                                                   (private subnet)
```

**Components:**

| Layer | Technology |
|---|---|
| Frontend | Node.js / Express — static SPA + `/api` proxy |
| Backend | Python Flask — REST API (products, cart, orders) |
| Database | Amazon RDS PostgreSQL 16 (private subnet, encrypted) |
| Cache / Sessions | Amazon ElastiCache Redis 7 (private subnet) |
| Container registry | Amazon ECR (one repo per service) |
| Compute | EKS managed node group — `t3.medium`, min 1 / desired 2 / max 4 |
| Ingress | AWS Load Balancer Controller — internet-facing ALB, IP target mode |
| Autoscaling | HorizontalPodAutoscaler — min 2 / max 6 pods, 60% CPU threshold |
| CI/CD | Jenkins (optional EC2 instance) |

## Repository Structure

```
.
├── app/                     # Application source code (shared)
│   ├── backend/             # Python Flask API + Dockerfile
│   ├── frontend/            # Node.js frontend + Dockerfile
│   └── docker-compose.yml   # Quick local run (Docker Compose, no K8s)
├── k8s/                     # All Kubernetes manifests
│   ├── production/          # Manifests for AWS / EKS
│   │   ├── namespace.yaml
│   │   ├── configmap.yaml
│   │   ├── secrets.yaml
│   │   ├── ingress.yaml
│   │   ├── backend/         # Deployment, Service, HPA
│   │   └── frontend/        # Deployment, Service, HPA
│   └── local/               # Manifests for Minikube
│       ├── namespace.yaml
│       ├── configmap.yaml
│       ├── secrets.yaml
│       ├── ingress.yaml
│       ├── postgres.yaml    # Local-only — replaced by RDS on AWS
│       ├── redis.yaml       # Local-only — replaced by ElastiCache on AWS
│       ├── backend/
│       └── frontend/
├── production/              # AWS infrastructure & CI/CD
│   ├── terraform/           # Terraform (VPC, EKS, RDS, Redis, ECR…)
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── terraform.tfvars.example
│   │   └── modules/
│   ├── scripts/
│   │   └── initial-deploy.sh  # One-shot bootstrap script
│   └── Jenkinsfile            # CI/CD pipeline definition
└── local/                   # Local development environment
    ├── jenkins/             # Jenkins container setup (Dockerfile + compose)
    └── scripts/
        └── install-jenkins.sh
```

## Prerequisites

- AWS CLI v2 configured (`aws configure`)
- Terraform >= 1.6
- Docker
- kubectl
- helm 3
- An IAM user/role with admin-level permissions for EKS, EC2, RDS, ElastiCache, IAM, ECR

## Two-Step Deploy

### Step 1 — Bootstrap (run once)

```bash
# Copy and edit the example vars file
cp production/terraform/terraform.tfvars.example production/terraform/terraform.tfvars
# Edit terraform.tfvars: set region, db_password, availability_zones, etc.

# Run the automated bootstrap script
chmod +x production/scripts/initial-deploy.sh
./production/scripts/initial-deploy.sh
```

The script performs these steps in order:

1. `terraform apply -target=module.ecr` — creates ECR repositories
2. `docker build` + `docker push` — pushes `:latest` images to ECR
3. `terraform apply -target=module.eks ...` — creates the EKS cluster (required before Helm/Kubernetes providers)
4. `terraform apply` — provisions remaining resources (ALB controller, Jenkins, RDS, Redis)
5. `kubectl apply -f k8s/production/` — deploys workloads

> **Note:** Steps 3 and 4 are split because the Helm and Kubernetes Terraform providers need the EKS cluster endpoint at plan time.

### Step 2 — Verify

```bash
# Wait ~2 min for the ALB to provision, then:
kubectl get ingress shopnow -n shopnow

# Should show an ADDRESS like:
# k8s-shopnow-shopnow-xxxx.us-east-1.elb.amazonaws.com
```

Open `http://<ADDRESS>` in your browser.

## Updating Images via Jenkins

1. Enable Jenkins by setting `jenkins_enabled = true` in `production/terraform/terraform.tfvars` and running `terraform apply`.
2. Open the Jenkins URL from `terraform output jenkins_url`.
3. Complete the setup wizard and create a Pipeline job pointing at this repository with `production/Jenkinsfile` as the pipeline script path.
4. On each push, Jenkins:
   - Runs backend (pytest) and frontend (npm test) in parallel
   - Builds and pushes tagged Docker images to ECR
   - Runs `kubectl set image` + `kubectl rollout status` for backend, then frontend

### Manual image update (without Jenkins)

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export ECR_BACKEND="${ECR_BASE}/shopnow-dev-backend"
export ECR_FRONTEND="${ECR_BASE}/shopnow-dev-frontend"
export IMAGE_TAG=v1.2.3

aws ecr get-login-password --region ${AWS_REGION} | \
    docker login --username AWS --password-stdin ${ECR_BASE}

docker build -t ${ECR_BACKEND}:${IMAGE_TAG}  ./app/backend  && docker push ${ECR_BACKEND}:${IMAGE_TAG}
docker build -t ${ECR_FRONTEND}:${IMAGE_TAG} ./app/frontend && docker push ${ECR_FRONTEND}:${IMAGE_TAG}

aws eks update-kubeconfig --region ${AWS_REGION} --name shopnow-dev-cluster

kubectl set image deployment/backend  backend=${ECR_BACKEND}:${IMAGE_TAG}   -n shopnow
kubectl rollout status deployment/backend -n shopnow

kubectl set image deployment/frontend frontend=${ECR_FRONTEND}:${IMAGE_TAG} -n shopnow
kubectl rollout status deployment/frontend -n shopnow
```

## Local Development

```bash
cd app
docker compose up --build
```

Opens the frontend at `http://localhost:3000` and the API at `http://localhost:5000/api/health`.

## Kubernetes Manifests

| File | Purpose |
|---|---|
| `k8s/production/namespace.yaml` | `shopnow` namespace |
| `k8s/production/configmap.yaml` | Non-secret env vars (DB_HOST, REDIS_HOST, etc.) |
| `k8s/production/secrets.yaml` | Base64-encoded DB_PASSWORD — replace with ESO in prod |
| `k8s/production/backend/` | Deployment (2 replicas), ClusterIP Service, HPA |
| `k8s/production/frontend/` | Deployment (2 replicas), ClusterIP Service, HPA |
| `k8s/production/ingress.yaml` | ALB Ingress: `/api` → backend, `/` → frontend |

## Terraform Module Map

```
production/terraform/
├── main.tf                  Root: wires modules + configures Helm/K8s providers
├── modules/
│   ├── networking/          VPC, subnets (with ELB tags), IGW, NAT GW
│   ├── security/            ALB SG, cluster SG, node SG, RDS SG, Redis SG
│   ├── ecr/                 ECR repos + lifecycle policies
│   ├── eks/                 EKS cluster, managed node group, OIDC provider
│   ├── alb-controller/      IRSA role, K8s service account, Helm release
│   ├── rds/                 RDS PostgreSQL 16
│   ├── elasticache/         ElastiCache Redis 7
│   └── jenkins/             Optional Jenkins EC2 instance
```

## Teardown

```bash
# Delete Kubernetes resources first (removes the ALB)
kubectl delete -f k8s/production/

# Then destroy Terraform-managed infrastructure
cd production/terraform
terraform destroy -auto-approve
```