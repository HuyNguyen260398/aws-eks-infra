data "aws_caller_identity" "current" {}

data "aws_ssoadmin_instances" "current" {}

locals {
  identity_store_id            = one(data.aws_ssoadmin_instances.current.identity_store_ids)
  identity_center_instance_arn = one(data.aws_ssoadmin_instances.current.arns)
  connection_id                = element(reverse(split("/", aws_codeconnections_connection.github.arn)), 0)
  gitops_repo_url = format(
    "https://codeconnections.%s.amazonaws.com/git-http/%s/%s/%s/%s/%s.git",
    var.aws_region,
    data.aws_caller_identity.current.account_id,
    var.aws_region,
    local.connection_id,
    var.github_owner,
    var.github_repository,
  )
  tags = {
    Environment = "platform"
    ManagedBy   = "Terraform"
    Project     = var.resource_prefix
  }
}

check "single_identity_center_instance" {
  assert {
    condition     = length(data.aws_ssoadmin_instances.current.identity_store_ids) == 1
    error_message = "Exactly one IAM Identity Center instance must be available in this AWS account."
  }
}

check "platform_root_inputs" {
  assert {
    condition = (
      can(cidrnetmask(var.vpc_cidr)) &&
      length(trimspace(var.kubernetes_version)) > 0 &&
      length(var.public_access_cidrs) > 0 &&
      alltrue([for cidr in var.public_access_cidrs : cidr != "0.0.0.0/0" && can(cidrnetmask(cidr))])
    )
    error_message = "The platform root requires a valid VPC CIDR, Kubernetes version, and restricted public access CIDRs."
  }
}

resource "aws_identitystore_group" "argocd_admins" {
  display_name      = "${var.resource_prefix}-argocd-admins"
  description       = "Administrators for the ${var.resource_prefix} managed Argo CD capability"
  identity_store_id = local.identity_store_id
}

resource "aws_identitystore_group_membership" "argocd_admins" {
  for_each          = var.argocd_admin_user_ids
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.argocd_admins.group_id
  member_id         = each.value
}

resource "aws_codeconnections_connection" "github" {
  name          = "${var.resource_prefix}-github"
  provider_type = "GitHub"
  tags          = local.tags
}

module "platform_cluster" {
  source = "../../modules/platform_cluster"

  aws_region                   = var.aws_region
  resource_prefix              = var.resource_prefix
  environment                  = "platform"
  vpc_cidr                     = var.vpc_cidr
  kubernetes_version           = var.kubernetes_version
  public_access_cidrs          = var.public_access_cidrs
  identity_store_id            = local.identity_store_id
  identity_center_instance_arn = local.identity_center_instance_arn
  argocd_admin_group_id        = aws_identitystore_group.argocd_admins.group_id
  github_connection_arn        = aws_codeconnections_connection.github.arn
  gitops_repo_url              = local.gitops_repo_url
  tags                         = local.tags
}

module "platform_cluster_bootstrap" {
  source = "../../modules/platform_cluster_bootstrap"

  cluster_name                          = module.platform_cluster.cluster_name
  cluster_arn                           = module.platform_cluster.cluster_arn
  environment                           = "platform"
  gitops_repo_url                       = local.gitops_repo_url
  gitops_platform_path                  = var.gitops_platform_path
  gitops_revision                       = var.gitops_revision
  vpc_id                                = module.platform_cluster.vpc_id
  aws_region                            = var.aws_region
  aws_load_balancer_controller_role_arn = module.platform_cluster.aws_load_balancer_controller_role_arn
  adot_role_arn                         = module.platform_cluster.adot_role_arn
  fargate_log_group_name                = module.platform_cluster.fargate_log_group_name
  efs_file_system_id                    = module.platform_cluster.efs_file_system_id
  jenkins_efs_access_point_id           = module.platform_cluster.jenkins_efs_access_point_id

  depends_on = [module.platform_cluster]
}
