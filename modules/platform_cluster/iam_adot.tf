data "aws_iam_policy_document" "adot_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:amazon-cloudwatch:adot-collector"]
    }
  }
}

resource "aws_iam_role" "adot" {
  name               = "${local.cluster_name}-adot"
  assume_role_policy = data.aws_iam_policy_document.adot_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "adot_cloudwatch_agent" {
  role       = aws_iam_role.adot.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "adot_xray" {
  role       = aws_iam_role.adot.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
}
