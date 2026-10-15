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

output "aws_load_balancer_controller_role_arn" {
  description = "ARN of the IAM role used by the AWS Load Balancer Controller service account."
  value       = aws_iam_role.load_balancer_controller.arn
}

output "argocd_capability_arn" {
  description = "ARN of the managed Argo CD EKS capability."
  value       = aws_eks_capability.argocd.arn
}

output "argocd_capability_role_name" {
  description = "Name of the IAM role assumed by the managed Argo CD capability."
  value       = aws_iam_role.argocd_capability.name
}

output "node_group_name" {
  description = "Name of the general-purpose EKS managed node group."
  # node_group_id is "<cluster>:<node group>".
  value = element(split(":", module.eks.eks_managed_node_groups["general"].node_group_id), 1)
}

output "node_security_group_id" {
  description = "Security group attached to general node-group instances and their Pods. The AWS Load Balancer Controller adds ALB ingress rules to it."
  value       = module.eks.node_security_group_id
}

output "ebs_csi_driver_role_arn" {
  description = "ARN of the IAM role the EBS CSI controller assumes through EKS Pod Identity."
  value       = aws_iam_role.ebs_csi_driver.arn
}

output "keda_operator_role_arn" {
  description = "ARN of the IAM role the KEDA operator runs as. Scaler roles trust this ARN."
  value       = aws_iam_role.keda_operator.arn
}
