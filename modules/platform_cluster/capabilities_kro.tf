resource "aws_eks_capability" "kro" {
  cluster_name              = module.eks.cluster_name
  capability_name           = "${local.cluster_name}-kro"
  type                      = "KRO"
  role_arn                  = aws_iam_role.kro_capability.arn
  delete_propagation_policy = "RETAIN"

  tags = var.tags

  depends_on = [aws_iam_role.kro_capability]
}
