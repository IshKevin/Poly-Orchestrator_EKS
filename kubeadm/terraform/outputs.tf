output "control_plane_public_ip" {
  description = "Public IP of the kubeadm control-plane node (used by Ansible and kubectl)"
  value       = aws_instance.control_plane.public_ip
}

output "control_plane_private_ip" {
  description = "Private IP of the control-plane node (used by kubeadm --apiserver-advertise-address)"
  value       = aws_instance.control_plane.private_ip
}

output "worker_public_ips" {
  description = "Public IPs of all worker nodes"
  value       = aws_instance.workers[*].public_ip
}

output "worker_private_ips" {
  description = "Private IPs of all worker nodes"
  value       = aws_instance.workers[*].private_ip
}

output "nlb_dns_name" {
  description = "DNS name of the NLB fronting nginx-ingress. App is reachable at http://<nlb_dns_name>"
  value       = aws_lb.nginx_ingress.dns_name
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (host:port)"
  value       = aws_db_instance.postgres.endpoint
}

output "rds_host" {
  description = "RDS PostgreSQL hostname only (without port)"
  value       = aws_db_instance.postgres.address
}

output "redis_endpoint" {
  description = "ElastiCache Redis endpoint (host)"
  value       = aws_elasticache_cluster.redis.cache_nodes[0].address
}

output "ecr_backend_url" {
  description = "Full ECR URL for the backend image"
  value       = aws_ecr_repository.backend.repository_url
}

output "ecr_frontend_url" {
  description = "Full ECR URL for the frontend image"
  value       = aws_ecr_repository.frontend.repository_url
}

output "ecr_registry" {
  description = "ECR registry hostname (account.dkr.ecr.region.amazonaws.com)"
  value       = split("/", aws_ecr_repository.backend.repository_url)[0]
}

output "key_pair_name" {
  description = "EC2 key pair name used for SSH"
  value       = var.key_pair_name
}

output "aws_region" {
  description = "AWS region where resources were created"
  value       = var.aws_region
}
