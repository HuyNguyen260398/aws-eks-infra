variable "cluster_name" {
  description = "Name of the Amazon EKS cluster registered with managed Argo CD."
  type        = string
}

variable "cluster_arn" {
  description = "ARN of the Amazon EKS cluster registered with managed Argo CD."
  type        = string
}

variable "environment" {
  description = "Platform environment represented by the registered Argo CD cluster."
  type        = string
}

variable "gitops_repo_url" {
  description = "AWS CodeConnections Git HTTP URL for the GitOps repository."
  type        = string
}

variable "gitops_platform_path" {
  description = "Repository path containing platform GitOps configuration, including a trailing slash."
  type        = string
}

variable "gitops_revision" {
  description = "Git revision managed Argo CD reconciles."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC containing the platform cluster."
  type        = string
}

variable "aws_region" {
  description = "AWS Region containing the platform cluster."
  type        = string
}

variable "aws_load_balancer_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller; populated when that controller is added."
  type        = string
}

variable "adot_role_arn" {
  description = "IRSA role ARN for the ADOT collector service account."
  type        = string
}

variable "fargate_log_group_name" {
  description = "CloudWatch log group receiving Fargate container logs."
  type        = string
}

variable "efs_file_system_id" {
  description = "ID of the EFS filesystem backing platform application storage."
  type        = string
}

variable "jenkins_efs_access_point_id" {
  description = "ID of the EFS access point scoping Jenkins to /jenkins-home."
  type        = string
}
