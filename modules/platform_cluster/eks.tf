module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name                                     = local.cluster_name
  kubernetes_version                       = var.kubernetes_version
  authentication_mode                      = "API"
  endpoint_private_access                  = true
  endpoint_public_access                   = true
  endpoint_public_access_cidrs             = var.public_access_cidrs
  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true
  enabled_log_types                        = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  compute_config = {
    enabled = false
  }

  addons = {
    coredns = {
      before_compute = true
      configuration_values = jsonencode({
        computeType = "Fargate"
      })
    }
    adot = {}
  }

  fargate_profiles = {
    system = {
      name            = "${local.cluster_name}-system"
      subnet_ids      = module.vpc.private_subnets
      create_iam_role = false
      iam_role_arn    = aws_iam_role.fargate_pod_execution.arn
      selectors       = [{ namespace = "kube-system" }]
    }
    platform_addons = {
      name            = "${local.cluster_name}-platform-addons"
      subnet_ids      = module.vpc.private_subnets
      create_iam_role = false
      iam_role_arn    = aws_iam_role.fargate_pod_execution.arn
      selectors = [
        { namespace = "argo-rollouts" },
        { namespace = "opentelemetry-operator-system" },
        { namespace = "amazon-cloudwatch" },
      ]
    }
    future_workloads = {
      name            = "${local.cluster_name}-future-workloads"
      subnet_ids      = module.vpc.private_subnets
      create_iam_role = false
      iam_role_arn    = aws_iam_role.fargate_pod_execution.arn
      selectors       = [{ namespace = "apps-*" }]
    }
  }

  tags = var.tags
}
