variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name, used as a prefix for all resources"
  type        = string
  default     = "shopnow"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "kubeadm"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (k8s nodes live here)"
  type        = list(string)
  default     = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (RDS, Redis)"
  type        = list(string)
  default     = ["10.1.11.0/24", "10.1.12.0/24"]
}

variable "availability_zones" {
  description = "Availability zones to use (must match subnet count)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "node_ami" {
  description = "Ubuntu 22.04 LTS AMI ID. Defaults to the latest Canonical AMI in the region if null."
  type        = string
  default     = null
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair for SSH access. The private key must be at ~/.ssh/<key_pair_name>.pem on your machine."
  type        = string
}

variable "admin_cidr" {
  description = "Your public IP in CIDR notation for SSH and API server access (e.g. 203.0.113.10/32)"
  type        = string
}

variable "control_plane_instance_type" {
  description = "EC2 instance type for the kubeadm control-plane node"
  type        = string
  default     = "t3.medium"
}

variable "worker_instance_type" {
  description = "EC2 instance type for kubeadm worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "shopnow"
}

variable "db_username" {
  description = "PostgreSQL master username"
  type        = string
  default     = "shopnow"
}

variable "db_password" {
  description = "PostgreSQL master password"
  type        = string
  sensitive   = true
}

variable "redis_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}
