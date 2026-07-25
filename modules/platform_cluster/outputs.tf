output "vpc_id" {
  description = "ID of the platform VPC."
  value       = module.vpc.vpc_id
}

output "vpc_arn" {
  description = "ARN of the platform VPC."
  value       = module.vpc.vpc_arn
}

output "private_subnet_ids" {
  description = "IDs of the three private platform subnets."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "IDs of the three public platform subnets."
  value       = module.vpc.public_subnets
}

output "cluster_name" {
  description = "Name of the Amazon EKS platform cluster."
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "ARN of the Amazon EKS platform cluster."
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "API endpoint of the Amazon EKS platform cluster."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the Amazon EKS platform cluster."
  value       = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider used for EKS IRSA roles."
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "URL of the IAM OIDC provider used for EKS IRSA roles."
  value       = module.eks.oidc_provider
}

output "fargate_profile_status" {
  description = "Status of each Amazon EKS Fargate profile."
  value = {
    for name, profile in module.eks.fargate_profiles : name => profile.fargate_profile_status
  }
}

output "fargate_log_group_name" {
  description = "Name of the CloudWatch log group for Fargate application logs."
  value       = aws_cloudwatch_log_group.fargate.name
}

output "adot_role_arn" {
  description = "ARN of the IAM role used by the ADOT collector service account."
  value       = aws_iam_role.adot.arn
}

output "aws_load_balancer_controller_role_arn" {
  description = "ARN of the IAM role used by the AWS Load Balancer Controller service account."
  value       = aws_iam_role.load_balancer_controller.arn
}

output "argocd_capability_arn" {
  description = "ARN of the managed Argo CD EKS capability."
  value       = aws_eks_capability.argocd.arn
}

output "ack_capability_arn" {
  description = "ARN of the managed ACK EKS capability."
  value       = aws_eks_capability.ack.arn
}

output "kro_capability_arn" {
  description = "ARN of the managed kro EKS capability."
  value       = aws_eks_capability.kro.arn
}

output "argocd_capability_role_name" {
  description = "Name of the IAM role assumed by the managed Argo CD capability."
  value       = aws_iam_role.argocd_capability.name
}

output "efs_file_system_id" {
  description = "ID of the EFS filesystem backing platform application storage."
  value       = aws_efs_file_system.apps.id
}

output "jenkins_efs_access_point_id" {
  description = "ID of the EFS access point scoping Jenkins to /jenkins-home."
  value       = aws_efs_access_point.jenkins.id
}
