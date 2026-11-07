data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "fargate_pod_execution_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks-fargate-pods.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "fargate_pod_execution_logs" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${local.cluster_name}/fargate/*:*",
    ]
  }
}

resource "aws_iam_role" "fargate_pod_execution" {
  name               = "${local.cluster_name}-fargate-pod-execution"
  assume_role_policy = data.aws_iam_policy_document.fargate_pod_execution_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "fargate_pod_execution" {
  role       = aws_iam_role.fargate_pod_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}

resource "aws_iam_role_policy" "fargate_pod_execution_logs" {
  name   = "${local.cluster_name}-fargate-logs"
  role   = aws_iam_role.fargate_pod_execution.id
  policy = data.aws_iam_policy_document.fargate_pod_execution_logs.json
}
