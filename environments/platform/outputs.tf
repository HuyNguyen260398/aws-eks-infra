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
