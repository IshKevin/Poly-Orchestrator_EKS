data "aws_caller_identity" "current" {}

locals {
  name_prefix  = "${var.project_name}-${var.environment}"
  cluster_name = "${var.project_name}-${var.environment}-cluster"

  # Normalize assumed-role ARN → IAM role ARN so aws_eks_access_entry accepts it.
  # IAM users and roles pass through unchanged.
  raw_caller_arn = data.aws_caller_identity.current.arn
  caller_arn = (
    can(regex(":assumed-role/", local.raw_caller_arn))
    ? format(
        "arn:aws:iam::%s:role/%s",
        data.aws_caller_identity.current.account_id,
        regex(":assumed-role/([^/]+)/", local.raw_caller_arn)[0]
      )
    : local.raw_caller_arn
  )
}

# ── IAM: Cluster Role ─────────────────────────────────────────────────────────

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name_prefix}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── IAM: Node Role ────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name_prefix}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = "1.35"

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    security_group_ids      = [var.cluster_security_group_id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  enabled_cluster_log_types = []

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = false
  }

  tags = merge(var.tags, { Name = local.cluster_name })

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# ── Launch Template ───────────────────────────────────────────────────────────
# Attaches both the EKS-managed cluster SG and our custom node SG.
# http_put_response_hop_limit = 2 is required for pods to reach IMDSv2.

resource "aws_launch_template" "node" {
  name_prefix = "${local.name_prefix}-node-lt-"

  vpc_security_group_ids = [
    aws_eks_cluster.this.vpc_config[0].cluster_security_group_id,
    var.node_security_group_id,
  ]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${local.name_prefix}-node" })
  }

  tags = var.tags
}

# ── Managed Node Group ────────────────────────────────────────────────────────

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name_prefix}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = [var.instance_type]

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  update_config {
    max_unavailable = 1
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-nodes" })

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
  ]
}

# ── OIDC Provider (required for IRSA) ─────────────────────────────────────────

data "tls_certificate" "cluster" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = merge(var.tags, { Name = "${local.name_prefix}-oidc" })
}

# ── EKS Access Entry for the Terraform caller ─────────────────────────────────
# Grants the IAM identity running terraform apply cluster-admin access so the
# Kubernetes and Helm providers can authenticate via aws eks get-token.

resource "aws_eks_access_entry" "terraform_caller" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.caller_arn
  type          = "STANDARD"

  tags = var.tags
}

resource "aws_eks_access_policy_association" "terraform_caller_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.caller_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.terraform_caller]
}
