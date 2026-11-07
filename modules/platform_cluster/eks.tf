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

  cloudwatch_log_group_retention_in_days = 30
  cloudwatch_log_group_kms_key_id        = aws_kms_key.observability.arn

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  compute_config = {
    enabled = false
  }

  # CoreDNS must be created *after* the Fargate profiles. before_compute = true
  # is for node-based clusters; on a Fargate-only cluster it schedules CoreDNS
  # while no profile selects kube-system, so the add-on sits DEGRADED until it
  # times out. The ADOT add-on is deliberately absent: it hard-requires
  # cert-manager, so Argo CD installs cert-manager and the OpenTelemetry
  # operator instead. Terraform still owns the ADOT IRSA role.
  addons = {
    coredns = {
      configuration_values = jsonencode({
        computeType = "Fargate"
      })
      # EKS creates the default CoreDNS Deployment when the cluster is created,
      # before any Fargate profile exists, so those first Pods are permanently
      # unschedulable and the add-on reports DEGRADED. Clearing it needs a
      # `kubectl -n kube-system rollout restart deployment coredns` once the
      # kube-system profile is ACTIVE — see docs/operations/deploy-platform.md.
      # The default 20m create timeout leaves no room for that manual step.
      timeouts = {
        create = "40m"
      }
    }
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
        { namespace = "cert-manager" },
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
