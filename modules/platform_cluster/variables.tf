variable "aws_region" {
  description = "AWS Region in which the platform cluster resources are created."
  type        = string
}

variable "resource_prefix" {
  description = "Prefix applied to platform cluster resource names."
  type        = string
}

variable "environment" {
  description = "Environment name applied to platform cluster resources."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block assigned to the platform VPC."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "kubernetes_version" {
  description = "Amazon EKS Kubernetes version for the platform cluster."
  type        = string
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to access the public Amazon EKS API endpoint."
  type        = set(string)
}

variable "identity_store_id" {
  description = "IAM Identity Center identity store ID for platform access management."
  type        = string
}

variable "identity_center_instance_arn" {
  description = "ARN of the IAM Identity Center instance used by managed Argo CD."
  type        = string
}

variable "argocd_admin_group_id" {
  description = "IAM Identity Center group ID granted managed Argo CD administrator access."
  type        = string
}

variable "github_connection_arn" {
  description = "ARN of the AWS CodeConnections GitHub connection used by managed Argo CD."
  type        = string
}

variable "gitops_repo_url" {
  description = "AWS CodeConnections Git HTTP endpoint for the GitOps repository."
  type        = string
}

variable "tags" {
  description = "Tags applied to platform cluster resources."
  type        = map(string)
}
