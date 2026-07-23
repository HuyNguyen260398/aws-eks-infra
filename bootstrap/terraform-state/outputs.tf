output "state_bucket_name" {
  description = "Name of the protected S3 bucket that stores Terraform state."
  value       = aws_s3_bucket.terraform_state.id
}

output "state_kms_key_arn" {
  description = "ARN of the KMS key that encrypts Terraform state."
  value       = aws_kms_key.terraform_state.arn
}
