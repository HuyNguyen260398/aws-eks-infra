resource "aws_eks_capability" "ack" {
  cluster_name              = module.eks.cluster_name
  capability_name           = "${local.cluster_name}-ack"
  type                      = "ACK"
  role_arn                  = aws_iam_role.ack_capability.arn
  delete_propagation_policy = "RETAIN"

  tags = var.tags

  depends_on = [aws_iam_role.ack_capability]
}
