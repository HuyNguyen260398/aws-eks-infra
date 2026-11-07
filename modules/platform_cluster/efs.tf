# Amazon EFS provides the only Fargate-compatible persistent storage (EBS
# requires EC2 nodes). Jenkins mounts JENKINS_HOME through the access point
# below. Fargate mounts efs.csi.aws.com volumes natively, so no EFS CSI driver
# is installed in the cluster.

data "aws_iam_policy_document" "efs_kms" {
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
}

resource "aws_kms_key" "efs" {
  description             = "KMS key for ${local.cluster_name} EFS application storage"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.efs_kms.json

  tags = var.tags
}

resource "aws_kms_alias" "efs" {
  name          = "alias/${local.cluster_name}-efs"
  target_key_id = aws_kms_key.efs.key_id
}

resource "aws_efs_file_system" "apps" {
  creation_token = "${local.cluster_name}-apps"
  encrypted      = true
  kms_key_id     = aws_kms_key.efs.arn

  tags = merge(var.tags, { Name = "${local.cluster_name}-apps" })
}

resource "aws_security_group" "efs" {
  name_prefix = "${local.cluster_name}-efs-"
  description = "Allow NFS from the EKS cluster to the application EFS filesystem"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, { Name = "${local.cluster_name}-efs" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "efs_nfs" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS 2049 from Fargate pods on the EKS cluster security group"
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.cluster_primary_security_group_id
}

// Keyed by availability zone, not by subnet ID: subnet IDs are unknown until the
// VPC applies, and for_each keys must be known at plan time. local.availability_zones
// resolves from a data source during plan, so the keys are static and stable.
resource "aws_efs_mount_target" "apps" {
  for_each = {
    for index, az in local.availability_zones : az => module.vpc.private_subnets[index]
  }

  file_system_id  = aws_efs_file_system.apps.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "jenkins" {
  file_system_id = aws_efs_file_system.apps.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/jenkins-home"

    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "0755"
    }
  }

  tags = merge(var.tags, { Name = "${local.cluster_name}-jenkins" })
}
