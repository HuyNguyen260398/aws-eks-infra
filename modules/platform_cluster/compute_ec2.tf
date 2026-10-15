# Fargate Pods carry the cluster primary security group. Node-group Pods carry
# the node security group the EKS module creates. Neither group admits the
# other by default, so without these rules EC2 Pods cannot resolve DNS
# (CoreDNS runs on Fargate) and Fargate controllers cannot call webhooks or
# metrics endpoints served from nodes. Pod-to-Pod policy inside a namespace is
# NetworkPolicy's job, not the security groups'.

resource "aws_vpc_security_group_ingress_rule" "fargate_from_nodes" {
  security_group_id            = module.eks.cluster_primary_security_group_id
  description                  = "All traffic from node-group Pods to Fargate Pods"
  ip_protocol                  = "-1"
  referenced_security_group_id = module.eks.node_security_group_id

  tags = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_fargate" {
  security_group_id            = module.eks.node_security_group_id
  description                  = "All traffic from Fargate Pods to node-group Pods"
  ip_protocol                  = "-1"
  referenced_security_group_id = module.eks.cluster_primary_security_group_id

  tags = var.tags
}
