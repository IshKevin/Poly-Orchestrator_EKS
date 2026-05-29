terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # Uncomment to store state remotely (recommended for teams)
  # backend "s3" {
  #   bucket         = "shopnow-terraform-state"
  #   key            = "shopnow/eks/dev/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "shopnow-terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# Helm and Kubernetes providers are configured from EKS cluster outputs.
# On first apply, run:
#   terraform apply -target=module.ecr -target=module.eks
# Then push images, then:
#   terraform apply
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
      command     = "aws"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    command     = "aws"
  }
}

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
  cluster_name = "${var.project_name}-${var.environment}-cluster"
}

# ── Networking ────────────────────────────────────────────────────────────────

module "networking" {
  source = "./modules/networking"

  project_name         = var.project_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
  cluster_name         = local.cluster_name
  tags                 = local.common_tags
}

# ── Security Groups ───────────────────────────────────────────────────────────

module "security" {
  source = "./modules/security"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = module.networking.vpc_id
  tags         = local.common_tags
}

# ── ECR ───────────────────────────────────────────────────────────────────────

module "ecr" {
  source = "./modules/ecr"

  project_name = var.project_name
  environment  = var.environment
  repositories = {
    frontend = { scan_on_push = true, keep_image_count = 10 }
    backend  = { scan_on_push = true, keep_image_count = 10 }
  }
  tags = local.common_tags
}

# ── RDS PostgreSQL ────────────────────────────────────────────────────────────

module "rds" {
  source = "./modules/rds"

  project_name       = var.project_name
  environment        = var.environment
  private_subnet_ids = module.networking.private_subnet_ids
  security_group_id  = module.security.rds_sg_id
  instance_class     = var.db_instance_class
  db_name            = var.db_name
  db_username        = var.db_username
  db_password        = var.db_password
  tags               = local.common_tags
}

# ── ElastiCache Redis ─────────────────────────────────────────────────────────

module "elasticache" {
  source = "./modules/elasticache"

  project_name       = var.project_name
  environment        = var.environment
  private_subnet_ids = module.networking.private_subnet_ids
  security_group_id  = module.security.redis_sg_id
  node_type          = var.redis_node_type
  tags               = local.common_tags
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────

module "eks" {
  source = "./modules/eks"

  project_name              = var.project_name
  environment               = var.environment
  private_subnet_ids        = module.networking.private_subnet_ids
  public_subnet_ids         = module.networking.public_subnet_ids
  node_security_group_id    = module.security.node_sg_id
  cluster_security_group_id = module.security.cluster_sg_id
  instance_type             = var.node_instance_type
  tags                      = local.common_tags

  depends_on = [module.networking, module.security]
}

# ── AWS Load Balancer Controller ──────────────────────────────────────────────

module "alb_controller" {
  source = "./modules/alb-controller"

  project_name      = var.project_name
  environment       = var.environment
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_url   = module.eks.oidc_issuer_url
  vpc_id            = module.networking.vpc_id
  tags              = local.common_tags

  depends_on = [module.eks]
}

# ── SSM Bastion (private EC2 for console shell access to RDS/Redis) ───────────

module "bastion" {
  source = "./modules/bastion"

  project_name      = var.project_name
  environment       = var.environment
  vpc_id            = module.networking.vpc_id
  private_subnet_id = module.networking.private_subnet_ids[0]
  instance_type     = var.bastion_instance_type
  rds_sg_id         = module.security.rds_sg_id
  redis_sg_id       = module.security.redis_sg_id
  tags              = local.common_tags

  depends_on = [module.networking, module.security]
}

# ── Jenkins CI/CD (optional) ──────────────────────────────────────────────────

module "jenkins" {
  count  = var.jenkins_enabled ? 1 : 0
  source = "./modules/jenkins"

  project_name     = var.project_name
  environment      = var.environment
  vpc_id           = module.networking.vpc_id
  public_subnet_id = module.networking.public_subnet_ids[0]
  instance_type    = var.jenkins_instance_type
  allowed_cidr     = var.jenkins_allowed_cidr
  eks_cluster_name = module.eks.cluster_name
  ecr_repository_arns = [
    module.ecr.repository_arns["frontend"],
    module.ecr.repository_arns["backend"],
  ]
  tags = local.common_tags
}
