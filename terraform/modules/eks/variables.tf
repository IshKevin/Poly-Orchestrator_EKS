variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS worker nodes"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs included in the cluster VPC config for LB support"
  type        = list(string)
}

variable "node_security_group_id" {
  description = "Custom SG applied to worker nodes via launch template (alongside the EKS cluster SG)"
  type        = string
}

variable "cluster_security_group_id" {
  description = "Additional security group attached to the EKS control plane ENIs"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for managed node group workers"
  type        = string
  default     = "t3.medium"
}

variable "tags" {
  description = "Tags to merge onto every resource in this module"
  type        = map(string)
  default     = {}
}
