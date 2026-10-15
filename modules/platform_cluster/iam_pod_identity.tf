# EKS Pod Identity roles. Pod Identity works only on EC2 nodes, never on
# Fargate, so every Pod using these roles must be scheduled on the general
# node group (see the system Fargate profile's label selectors in eks.tf).
# The source conditions stop another account's or cluster's Pod Identity
# agent from assuming these roles (confused deputy).

data "aws_iam_policy_document" "pod_identity_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [module.eks.cluster_arn]
    }
  }
}

resource "aws_iam_role" "ebs_csi_driver" {
  name               = "${local.cluster_name}-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# KEDA reads queue depth on behalf of each ScaledObject by assuming the role
# that ScaledObject's TriggerAuthentication names. This role can only assume
# other roles; what it may read is decided by each target role's trust policy,
# which must name this role's ARN.
data "aws_iam_policy_document" "keda_operator" {
  statement {
    sid       = "AssumeScalerRoles"
    effect    = "Allow"
    actions   = ["sts:AssumeRole", "sts:TagSession"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*"]
  }
}

resource "aws_iam_role" "keda_operator" {
  name               = "${local.cluster_name}-keda-operator"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy" "keda_operator" {
  name   = "${local.cluster_name}-keda-operator"
  role   = aws_iam_role.keda_operator.id
  policy = data.aws_iam_policy_document.keda_operator.json
}

# The association may exist before the namespace or ServiceAccount does; it
# takes effect for Pods started after both exist.
resource "aws_eks_pod_identity_association" "keda_operator" {
  cluster_name    = module.eks.cluster_name
  namespace       = "keda"
  service_account = "keda-operator"
  role_arn        = aws_iam_role.keda_operator.arn

  tags = var.tags
}
