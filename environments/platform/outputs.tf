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

output "cluster_name" {
  description = "Name of the Amazon EKS platform cluster."
  value       = module.platform_cluster.cluster_name
}

output "cluster_arn" {
  description = "ARN of the Amazon EKS platform cluster."
  value       = module.platform_cluster.cluster_arn
}

output "cluster_endpoint" {
  description = "API endpoint of the Amazon EKS platform cluster."
  value       = module.platform_cluster.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the Amazon EKS platform cluster."
  value       = module.platform_cluster.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider used for EKS IRSA roles."
  value       = module.platform_cluster.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "URL of the IAM OIDC provider used for EKS IRSA roles."
  value       = module.platform_cluster.oidc_provider_url
}

output "fargate_profile_status" {
  description = "Status of each Amazon EKS Fargate profile."
  value       = module.platform_cluster.fargate_profile_status
}

output "jenkins_certificate_arn" {
  description = "ARN of the validated ACM certificate for the Jenkins public hostname. Empty when public exposure is disabled."
  value       = module.platform_cluster.jenkins_certificate_arn
}

output "jenkins_public_hostname" {
  description = "Public DNS name serving Jenkins. Empty when public exposure is disabled."
  value       = module.platform_cluster.jenkins_public_hostname
}
