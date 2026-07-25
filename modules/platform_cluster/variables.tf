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

variable "jenkins_public_hostname" {
  description = "Public DNS name for the Jenkins Ingress, e.g. jenkins.example.com. Empty disables public HTTPS exposure."
  type        = string
  default     = ""
}

variable "route53_hosted_zone_name" {
  description = "Public Route 53 hosted zone containing jenkins_public_hostname. Required when jenkins_public_hostname is set."
  type        = string
  default     = ""
}

variable "jenkins_alb_name" {
  description = "Pinned name of the Jenkins ALB, matching alb.ingress.kubernetes.io/load-balancer-name on the Ingress."
  type        = string
  default     = "aws-eks-infra-jenkins"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{1,32}$", var.jenkins_alb_name))
    error_message = "jenkins_alb_name must be 1-32 alphanumeric or hyphen characters."
  }
}

variable "jenkins_dns_record_enabled" {
  description = "Create the Route 53 alias record for Jenkins. Enable only after the Ingress has created the ALB; see docs/operations/public-workload-access.md."
  type        = bool
  default     = false
}
