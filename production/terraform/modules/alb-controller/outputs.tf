output "iam_role_arn" {
  description = "IAM role ARN for the AWS Load Balancer Controller (IRSA)"
  value       = aws_iam_role.alb_controller.arn
}

output "helm_release_status" {
  description = "Status of the aws-load-balancer-controller Helm release"
  value       = helm_release.alb_controller.status
}
