output "region" {
  value = var.region
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_kubeconfig_command" {
  description = "Run this to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "mongodb_public_ip" {
  description = "SSH here: ssh ubuntu@<ip>. Intentionally reachable from the internet."
  value       = aws_instance.mongo.public_ip
}

output "mongodb_private_ip" {
  value = aws_instance.mongo.private_ip
}

output "mongodb_backup_bucket" {
  value = aws_s3_bucket.backups.id
}

output "mongodb_backup_bucket_public_url" {
  description = "Anonymous listing URL. Prove the exposure by opening this in a logged-out browser."
  value       = "https://${aws_s3_bucket.backups.id}.s3.${var.region}.amazonaws.com/"
}

output "mongodb_secret_arn" {
  description = "Secrets Manager entry holding the MongoDB credentials."
  value       = aws_secretsmanager_secret.mongo.arn
}

output "mongodb_uri" {
  description = "Connection string handed to the app via a Kubernetes Secret."
  value       = local.mongodb_uri
  sensitive   = true
}

output "app_namespace" {
  value = kubernetes_namespace_v1.app.metadata[0].name
}

output "cloudtrail_name" {
  value = aws_cloudtrail.main.name
}

output "security_alerts_topic" {
  value = aws_sns_topic.alerts.arn
}

output "permissions_boundary_arn" {
  value = aws_iam_policy.guardrail_boundary.arn
}
