# Identifiers that workload repositories (for example Cashight's Terraform)
# read instead of hardcoding. Read-only facts about this platform; Terraform
# here does not configure the ALB - the group name is the IngressGroup that
# GitOps workloads join (docs/operations/public-workload-access.md), and the
# value below must stay identical to that annotation.
locals {
  platform_parameter_prefix = "/${var.resource_prefix}/platform"

  published_parameters = {
    "cluster-name" = {
      value       = module.platform_cluster.cluster_name
      description = "Name of the platform EKS cluster."
    }
    "alb-group-name" = {
      value       = "platform-public"
      description = "IngressGroup name of the shared internet-facing ALB."
    }
    "keda-operator-role-arn" = {
      value       = module.platform_cluster.keda_operator_role_arn
      description = "IAM role the KEDA operator runs as; scaler roles must trust it."
    }
    "codeconnections-git-http-base" = {
      value       = local.codeconnections_git_http_base
      description = "CodeConnections Git-HTTP base; a repository URL is <base>/<owner>/<repo>.git."
    }
  }
}

resource "aws_ssm_parameter" "published" {
  #checkov:skip=CKV2_AWS_34: Non-secret identifiers published for other repositories; SecureString would add KMS calls and nothing else.
  for_each = local.published_parameters

  name        = "${local.platform_parameter_prefix}/${each.key}"
  description = each.value.description
  type        = "String"
  value       = each.value.value

  tags = local.tags
}
