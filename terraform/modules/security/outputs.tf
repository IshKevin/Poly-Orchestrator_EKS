output "alb_sg_id" {
  description = "ALB security group ID"
  value       = aws_security_group.alb.id
}

output "cluster_sg_id" {
  description = "EKS cluster additional security group ID"
  value       = aws_security_group.cluster.id
}

output "node_sg_id" {
  description = "EKS worker node security group ID"
  value       = aws_security_group.node.id
}

output "rds_sg_id" {
  description = "RDS security group ID"
  value       = aws_security_group.rds.id
}

output "redis_sg_id" {
  description = "Redis security group ID"
  value       = aws_security_group.redis.id
}
