output "argocd_admin_group_id" {
  description = "IAM Identity Center group ID granted managed Argo CD administrator access."
  value       = aws_identitystore_group.argocd_admins.group_id
}

output "github_connection_arn" {
  description = "ARN of the AWS CodeConnections GitHub connection used by managed Argo CD."
  value       = aws_codeconnections_connection.github.arn
}

output "gitops_repo_url" {
  description = "AWS CodeConnections Git HTTP endpoint for the GitOps repository."
  value       = local.gitops_repo_url
}

output "vpc_id" {
  description = "ID of the platform VPC."
  value       = module.platform_cluster.vpc_id
}

output "vpc_arn" {
  description = "ARN of the platform VPC."
  value       = module.platform_cluster.vpc_arn
}

output "private_subnet_ids" {
  description = "IDs of the three private platform subnets."
  value       = module.platform_cluster.private_subnet_ids
}

output "public_subnet_ids" {
  description = "IDs of the three public platform subnets."
  value       = module.platform_cluster.public_subnet_ids
}
