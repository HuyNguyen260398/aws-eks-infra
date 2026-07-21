output "vpc_id" {
  description = "ID of the platform VPC."
  value       = module.vpc.vpc_id
}

output "vpc_arn" {
  description = "ARN of the platform VPC."
  value       = module.vpc.vpc_arn
}

output "private_subnet_ids" {
  description = "IDs of the three private platform subnets."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "IDs of the three public platform subnets."
  value       = module.vpc.public_subnets
}
