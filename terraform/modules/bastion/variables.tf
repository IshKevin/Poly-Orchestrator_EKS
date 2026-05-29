variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to place the bastion into"
  type        = string
}

variable "private_subnet_id" {
  description = "Private subnet ID for the bastion (no public IP needed — SSM provides access)"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the bastion"
  type        = string
  default     = "t3.micro"
}

variable "rds_sg_id" {
  description = "RDS security group ID — bastion SG is added as an ingress source"
  type        = string
}

variable "redis_sg_id" {
  description = "Redis security group ID — bastion SG is added as an ingress source"
  type        = string
}

variable "tags" {
  description = "Tags to merge onto every resource in this module"
  type        = map(string)
  default     = {}
}
