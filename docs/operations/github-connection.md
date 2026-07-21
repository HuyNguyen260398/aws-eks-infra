# GitHub CodeConnections

The `environments/platform` Terraform root creates the IAM Identity Center group used for managed Argo CD administrators and the AWS CodeConnections connection used to read this repository. Terraform never stores GitHub credentials.

## Prerequisites

- The Terraform state bootstrap is applied and its S3 bucket and KMS key outputs are available.
- IAM Identity Center is enabled in the AWS account and the administrator Identity Store user IDs are known.
- The operator can authorize a GitHub connection for `HuyNguyen260398/aws-eks-infra`.

## Configure and initialize

Copy `terraform.tfvars.example` and `backend.hcl.example` to ignored local files. Replace the example public CIDR, Identity Store user ID, state bucket, and KMS key values.

```bash
cp environments/platform/terraform.tfvars.example environments/platform/terraform.tfvars
cp environments/platform/backend.hcl.example environments/platform/backend.hcl
terraform -chdir=environments/platform init -backend-config=backend.hcl
terraform -chdir=environments/platform plan -out=tfplan
terraform -chdir=environments/platform apply tfplan
```

After Terraform creates the connection, open AWS Developer Tools → Connections, select `aws-eks-infra-github`, and complete the GitHub authorization. Restrict the GitHub App installation to `HuyNguyen260398/aws-eks-infra`.

## Verify

```bash
aws codeconnections get-connection \
  --connection-arn "$(terraform -chdir=environments/platform output -raw github_connection_arn)" \
  --query 'Connection.ConnectionStatus' \
  --output text
```

The expected result is `AVAILABLE`. The GitOps endpoint is available from the `gitops_repo_url` Terraform output.
