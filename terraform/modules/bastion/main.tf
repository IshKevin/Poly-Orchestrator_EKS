locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ── AMI: Amazon Linux 2023 (SSM agent pre-installed) ─────────────────────────

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── IAM Role: SSM Session Manager access ─────────────────────────────────────

data "aws_iam_policy_document" "bastion_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  name               = "${local.name_prefix}-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "bastion_db_read" {
  name = "bastion-db-read"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["rds:DescribeDBInstances"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["elasticache:DescribeCacheClusters"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${local.name_prefix}-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ── Security Group: outbound only (SSM tunnels inbound) ───────────────────────

resource "aws_security_group" "bastion" {
  name        = "${local.name_prefix}-sg-bastion"
  description = "Bastion: SSM-managed, outbound to RDS/Redis only"
  vpc_id      = var.vpc_id

  egress {
    description = "Allow all outbound (SSM endpoints, RDS, Redis)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.name_prefix}-sg-bastion" })
}

# ── Open RDS SG to bastion ────────────────────────────────────────────────────

resource "aws_security_group_rule" "rds_from_bastion" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  description              = "PostgreSQL from bastion (SSM)"
  security_group_id        = var.rds_sg_id
  source_security_group_id = aws_security_group.bastion.id
}

# ── Open Redis SG to bastion ──────────────────────────────────────────────────

resource "aws_security_group_rule" "redis_from_bastion" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  description              = "Redis from bastion (SSM)"
  security_group_id        = var.redis_sg_id
  source_security_group_id = aws_security_group.bastion.id
}

# ── EC2 Bastion Instance (private subnet, no public IP) ───────────────────────

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = var.private_subnet_id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = false

  user_data = <<-EOF
    #!/bin/bash
    set -e
    dnf update -y
    # PostgreSQL 16 client via PGDG repo (AL2023 ships only pg15 by default)
    dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm || true
    dnf -qy module disable postgresql || true
    dnf install -y postgresql16 --nogpgcheck
    # Redis CLI — valkey is the AL2023 successor to redis6
    dnf install -y valkey || dnf install -y redis || true
    # Useful admin tools
    dnf install -y jq nc
    # Symlink valkey-cli as redis-cli for convenience
    if command -v valkey-cli &>/dev/null && ! command -v redis-cli &>/dev/null; then
      ln -s /usr/bin/valkey-cli /usr/local/bin/redis-cli
    fi
  EOF

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-bastion"
    # Tag used to identify the instance in SSM Fleet Manager
    "ssm:SessionTarget" = "true"
  })
}
