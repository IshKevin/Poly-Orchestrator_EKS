locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ── ALB ───────────────────────────────────────────────────────────────────────
# Internet-facing ALB managed by AWS Load Balancer Controller via Ingress

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-sg-alb"
  description = "ALB: allow HTTP/HTTPS from internet"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = { http = 80, https = 443 }
    content {
      description = ingress.key
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-sg-alb" })
}

# ── EKS Cluster (additional SG for control plane ENIs) ───────────────────────

resource "aws_security_group" "cluster" {
  name        = "${local.name_prefix}-sg-eks-cluster"
  description = "EKS cluster: additional SG for control plane ENIs"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Allow nodes to reach API server"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.node.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-sg-eks-cluster" })
}

# ── EKS Worker Nodes ──────────────────────────────────────────────────────────
# Used in a launch template so both this SG and the EKS cluster SG are attached.
# ALB Controller (IP target mode) registers pod IPs directly; it auto-manages
# ingress rules on this SG for each Ingress/Service it reconciles.

resource "aws_security_group" "node" {
  name        = "${local.name_prefix}-sg-eks-node"
  description = "EKS worker nodes: allow pod traffic from ALB and node-to-node"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Frontend pods from ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "Backend pods from ALB"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "Node-to-node and pod-to-pod within the node SG"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-sg-eks-node" })
}

# ── RDS ───────────────────────────────────────────────────────────────────────

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-sg-rds"
  description = "RDS: allow PostgreSQL from EKS worker nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.node.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-sg-rds" })
}

# ── ElastiCache ───────────────────────────────────────────────────────────────

resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-sg-redis"
  description = "Redis: allow inbound from EKS worker nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from EKS nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.node.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-sg-redis" })
}
