# GitHub CodeConnections

The `environments/platform` Terraform root creates the IAM Identity Center group used for managed Argo CD administrators and the AWS CodeConnections connection used to read this repository. Terraform never stores GitHub credentials.

## Prerequisites

- The Terraform state bootstrap is applied and its S3 bucket and KMS key outputs are available.
- IAM Identity Center is enabled in the AWS account and the administrator Identity Store user IDs are known.
- The operator can authorize a GitHub connection for their fork, `<github_owner>/<github_repository>`.

## Configure and initialize

Copy `terraform.tfvars.example` and `backend.hcl.example` to ignored local files. Replace the example public CIDR, Identity Store user ID, state bucket, and KMS key values.

```bash
cp environments/platform/terraform.tfvars.example environments/platform/terraform.tfvars
cp environments/platform/backend.hcl.example environments/platform/backend.hcl
terraform -chdir=environments/platform init -backend-config=backend.hcl
terraform -chdir=environments/platform plan -out=tfplan
terraform -chdir=environments/platform apply tfplan
```

After Terraform creates the connection, open AWS Developer Tools → Connections, select `<resource_prefix>-github` (`aws-eks-infra-github` with the default prefix), and complete the GitHub authorization. Restrict the GitHub App installation to the single GitOps repository, `<github_owner>/<github_repository>`.

## Verify

```bash
aws codeconnections get-connection \
  --connection-arn "$(terraform -chdir=environments/platform output -raw github_connection_arn)" \
  --query 'Connection.ConnectionStatus' \
  --output text
```

The expected result is `AVAILABLE`. The GitOps endpoint is available from the `gitops_repo_url` Terraform output.
