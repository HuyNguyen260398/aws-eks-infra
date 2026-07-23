variable "aws_profile" {
  description = "AWS CLI profile used to manage the Terraform state foundation."
  type        = string
  default     = "default"
}

variable "aws_region" {
  description = "AWS Region in which to create the Terraform state foundation."
  type        = string
  default     = "ap-southeast-1"
}

variable "resource_prefix" {
  description = "Prefix applied to Terraform state resource names and tags."
  type        = string
  default     = "aws-eks-infra"
}
