locals {
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 3)
  cluster_name       = "${var.resource_prefix}-${var.environment}"

  public_subnets = [
    for index in range(length(local.availability_zones)) : cidrsubnet(var.vpc_cidr, 8, index)
  ]

  private_subnets = [
    for index in range(length(local.availability_zones)) : cidrsubnet(var.vpc_cidr, 8, index + length(local.availability_zones))
  ]
}

check "platform_cluster_inputs" {
  assert {
    condition = (
      length(trimspace(var.aws_region)) > 0 &&
      length(trimspace(var.kubernetes_version)) > 0 &&
      length(var.public_access_cidrs) > 0 &&
      alltrue([for cidr in var.public_access_cidrs : can(cidrnetmask(cidr))]) &&
      length(trimspace(var.identity_store_id)) > 0 &&
      length(trimspace(var.argocd_admin_group_id)) > 0 &&
      length(trimspace(var.github_connection_arn)) > 0 &&
      length(trimspace(var.gitops_repo_url)) > 0
    )
    error_message = "The platform cluster requires Region, EKS, endpoint CIDR, Identity Center, and GitHub connection inputs."
  }
}
