variable "aws_profile" {
  description = "AWS CLI profile used to manage the platform environment."
  type        = string
  default     = "default"
}

variable "aws_region" {
  description = "AWS Region in which to create the platform environment."
  type        = string
  default     = "ap-southeast-1"
}

variable "resource_prefix" {
  description = "Prefix applied to platform resource names and tags."
  type        = string
  default     = "aws-eks-infra"
}

variable "vpc_cidr" {
  description = "CIDR block assigned to the platform VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 or IPv6 CIDR block."
  }
}

variable "kubernetes_version" {
  description = "Amazon EKS Kubernetes version for the platform cluster."
  type        = string
  default     = "1.35"
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to access the public Amazon EKS API endpoint."
  type        = set(string)

  validation {
    condition = length(var.public_access_cidrs) > 0 && alltrue([
      for cidr in var.public_access_cidrs : cidr != "0.0.0.0/0" && can(cidrnetmask(cidr))
    ])
    error_message = "public_access_cidrs must contain valid CIDRs and must not include 0.0.0.0/0."
  }
}

variable "github_owner" {
  description = "GitHub organization or user that owns your fork of this repository."
  type        = string

  validation {
    condition     = length(trimspace(var.github_owner)) > 0
    error_message = "github_owner must not be empty."
  }
}

variable "github_repository" {
  description = "Name of your fork of this repository, used as the GitOps source of truth."
  type        = string

  validation {
    condition     = length(trimspace(var.github_repository)) > 0
    error_message = "github_repository must not be empty."
  }
}

variable "gitops_platform_path" {
  description = "Repository path containing managed Argo CD platform configuration."
  type        = string
  default     = "gitops/platform/"

  validation {
    condition     = startswith(var.gitops_platform_path, "gitops/platform/") && endswith(var.gitops_platform_path, "/")
    error_message = "gitops_platform_path must be rooted at gitops/platform/ and end with a slash."
  }
}

variable "gitops_revision" {
  description = "Git revision managed Argo CD reconciles for platform configuration."
  type        = string
  default     = "main"

  validation {
    condition     = length(trimspace(var.gitops_revision)) > 0
    error_message = "gitops_revision must not be empty."
  }
}

variable "argocd_admin_user_ids" {
  description = "Existing IAM Identity Center user IDs granted managed Argo CD administrator access."
  type        = set(string)

  validation {
    condition     = length(var.argocd_admin_user_ids) > 0
    error_message = "argocd_admin_user_ids must contain at least one IAM Identity Center user ID."
  }
}


variable "monthly_budget_usd" {
  description = "Account-wide monthly cost budget in USD. Alerts fire at 50%, 80% and 100% of actual spend and at 100% of forecast spend."
  type        = number
  default     = 400

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than zero."
  }
}

variable "budget_notification_emails" {
  description = "Email addresses notified by the account budget. AWS Budgets sends to them directly; no subscription confirmation is needed."
  type        = set(string)

  validation {
    condition = length(var.budget_notification_emails) > 0 && alltrue([
      for email in var.budget_notification_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", email))
    ])
    error_message = "budget_notification_emails must contain at least one valid email address."
  }
}

variable "node_instance_type" {
  description = "Graviton (arm64) EC2 instance type for the general-purpose managed node group."
  type        = string
  default     = "t4g.large"
}

variable "node_count" {
  description = "Fixed size of the general-purpose managed node group, one node per Availability Zone at the default of 3."
  type        = number
  default     = 3
}
