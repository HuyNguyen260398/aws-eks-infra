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

  # vpc-cni, kube-proxy and the Pod Identity Agent are created before the node
  # group (before_compute): the module builds the cluster with
  # bootstrap_self_managed_addons = false, so without them EC2 nodes never
  # become Ready. enableNetworkPolicy makes the VPC CNI enforce NetworkPolicy
  # objects; without it they are accepted and silently ignored. Fargate Pods
  # are never subject to NetworkPolicy either way.
  #
  # CoreDNS must be created *after* the Fargate profiles. before_compute = true
  # would schedule it while no profile selects it, so the add-on sits DEGRADED
  # until it times out. The ADOT add-on is deliberately absent: it hard-requires
  # cert-manager, so Argo CD installs cert-manager and the OpenTelemetry
  # operator instead. Terraform still owns the ADOT IRSA role.
  addons = {
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
    kube-proxy = {
      before_compute = true
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
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
    # Created after the node group: its controller Deployment needs EC2
    # capacity for Pod Identity, and its node DaemonSet only runs on EC2.
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi_driver.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  fargate_profiles = {
    # Label-scoped, not the whole namespace: the VPC CNI, kube-proxy, Pod
    # Identity Agent and EBS CSI driver also live in kube-system and must run
    # on EC2. DaemonSets cannot run on Fargate, and EKS Pod Identity does not
    # work there. Only CoreDNS and the load balancer controller (IRSA) stay.
    system = {
      name            = "${local.cluster_name}-system"
      subnet_ids      = module.vpc.private_subnets
      create_iam_role = false
      iam_role_arn    = aws_iam_role.fargate_pod_execution.arn
      selectors = [
        { namespace = "kube-system", labels = { "k8s-app" = "kube-dns" } },
        { namespace = "kube-system", labels = { "app.kubernetes.io/name" = "aws-load-balancer-controller" } },
      ]
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

  # One fixed-size Graviton node group for workloads Fargate cannot host:
  # EBS-backed StatefulSets, DaemonSet collectors, and Pods using EKS Pod
  # Identity. No cluster autoscaler: KEDA scales Pods, not nodes. The launch
  # template defaults to IMDSv2 with a hop limit of 1, so Pods cannot reach
  # the node role's credentials through instance metadata.
  eks_managed_node_groups = {
    general = {
      name            = "${local.cluster_name}-general"
      use_name_prefix = false
      # The module's default role name ("<name>-eks-node-group" as a prefix)
      # exceeds IAM's 38-character name_prefix limit.
      iam_role_name            = "${local.cluster_name}-node"
      iam_role_use_name_prefix = false

      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"
      subnet_ids     = module.vpc.private_subnets

      min_size     = var.node_count
      max_size     = var.node_count
      desired_size = var.node_count

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      update_config = {
        max_unavailable = 1
      }

      node_repair_config = {
        enabled = true
      }
    }
  }

  tags = var.tags
}
