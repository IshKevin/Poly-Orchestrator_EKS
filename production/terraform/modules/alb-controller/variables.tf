variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for IRSA"
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL of the EKS cluster (https://...)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID — passed to the ALB Controller Helm chart"
  type        = string
}

variable "tags" {
  description = "Tags to merge onto AWS resources in this module"
  type        = map(string)
  default     = {}
}
