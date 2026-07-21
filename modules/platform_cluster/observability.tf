data "aws_iam_policy_document" "observability_kms" {
  #checkov:skip=CKV_AWS_109: The account-root KMS administration statement is the AWS-recommended default key-policy baseline.
  #checkov:skip=CKV_AWS_111: The account-root KMS administration statement intentionally grants write-capable key management.
  #checkov:skip=CKV_AWS_356: KMS key policies require wildcard resources because KMS keys do not support resource ARNs here.
  statement {
    sid    = "EnableAccountRootAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowCloudWatchLogsEncryption"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values = [
        "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${local.cluster_name}/*",
        "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/vpc-flow-logs/${local.cluster_name}",
      ]
    }
  }
}

resource "aws_kms_key" "observability" {
  description             = "KMS key for ${local.cluster_name} observability logs"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.observability_kms.json

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "eks_control_plane" {
  #checkov:skip=CKV_AWS_338: The platform retention requirement is 30 days.
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.observability.arn

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "fargate" {
  #checkov:skip=CKV_AWS_338: The platform retention requirement is 30 days.
  name              = "/aws/eks/${local.cluster_name}/fargate"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.observability.arn

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "container_insights" {
  #checkov:skip=CKV_AWS_338: The platform retention requirement is 30 days.
  name              = "/aws/eks/${local.cluster_name}/containerinsights"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.observability.arn

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  #checkov:skip=CKV_AWS_338: The platform retention requirement is 30 days.
  name              = "/aws/vpc-flow-logs/${local.cluster_name}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.observability.arn

  tags = var.tags
}

data "aws_iam_policy_document" "vpc_flow_logs_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "vpc_flow_logs" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"]
  }
}

resource "aws_iam_role" "vpc_flow_logs" {
  name               = "${local.cluster_name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.vpc_flow_logs_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  name   = "${local.cluster_name}-vpc-flow-logs"
  role   = aws_iam_role.vpc_flow_logs.id
  policy = data.aws_iam_policy_document.vpc_flow_logs.json
}

resource "aws_flow_log" "vpc" {
  iam_role_arn             = aws_iam_role.vpc_flow_logs.arn
  log_destination          = aws_cloudwatch_log_group.vpc_flow_logs.arn
  log_destination_type     = "cloud-watch-logs"
  max_aggregation_interval = 60
  traffic_type             = "ALL"
  vpc_id                   = module.vpc.vpc_id

  tags = var.tags
}
