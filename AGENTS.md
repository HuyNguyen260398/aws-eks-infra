# Repository Guidelines

## Scope

This repository manages one Fargate-only EKS platform. Keep application deployments and architecture improvements in separate plans.

## Validation

Run `make terraform-check` for HCL changes and `make yaml-check` for GitOps changes. Never commit state, plans, credentials, `backend.hcl`, or `terraform.tfvars`.

## Terraform

Format with `terraform fmt -recursive`. Use `snake_case`, explicit descriptions, typed variables, provider constraints, and deterministic tags. Customer-controlled AWS resources belong in Terraform.

## GitOps

Terraform owns only Argo CD bootstrap objects. Argo CD owns resources under `gitops/platform/` and future resources under `gitops/workloads/`. Never assign the same resource to both owners.

## Commits

Use one Conventional Commit per completed plan task. Include the exact validation commands in pull-request descriptions.
