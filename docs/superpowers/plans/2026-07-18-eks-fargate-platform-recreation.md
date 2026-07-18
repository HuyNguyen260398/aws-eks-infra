# EKS Fargate Platform Recreation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Terraform-managed, Fargate-only Amazon EKS platform whose managed Argo CD capability reconciles platform configuration from `HuyNguyen260398/aws-eks-infra` through AWS CodeConnections, without deploying an application.

**Architecture:** A one-time Terraform root creates the protected S3/KMS state foundation, and one `environments/platform` root composes reusable networking, EKS Fargate, capabilities, and Argo CD bootstrap modules. Terraform owns customer-controlled AWS resources and the minimum GitOps bootstrap; managed Argo CD owns ongoing Kubernetes platform configuration under `gitops/platform/`.

**Tech Stack:** Terraform 1.10.5+, AWS Provider `~> 6.0`, Kubernetes Provider `~> 3.0`, terraform-aws-modules EKS `~> 21.0`, VPC `~> 6.0`, Amazon EKS 1.35, AWS Fargate, EKS Capabilities, AWS CodeConnections, IAM Identity Center, Argo CD, Argo Rollouts, AWS Load Balancer Controller, ADOT, Helm, Kustomize, TFLint, Checkov, yamllint, and kubeconform.

## Global Constraints

- Create only one environment named `platform`; do not add development, staging, or production roots.
- Use only Fargate compute; do not enable EKS Auto Mode, EC2 node groups, Karpenter, Auto Scaling groups, or DaemonSets.
- Do not deploy a sample application, service namespace, Ingress, load balancer, ECR repository, or ACK service resource.
- Use the existing GitHub repository `HuyNguyen260398/aws-eks-infra`, branch `main`, with `gitops/platform` and `gitops/workloads` path boundaries.
- Authenticate Argo CD through Terraform-managed AWS CodeConnections; never store a PAT, SSH key, GitHub App key, or GitHub credential in Terraform, Kubernetes, or Git.
- Manage all customer-controlled AWS resources introduced by this plan in Terraform. The existing AWS account, IAM Identity Center instance/users, GitHub repository, GitHub authorization handshake, and AWS-managed Fargate runtime are documented exceptions.
- Use S3 native state locking with `use_lockfile = true`; do not create a DynamoDB lock table.
- Every task must pass its listed checks and end with exactly one Conventional Commit.
- Keep service deployment and post-parity improvements out of this plan.

---

## Planned File Map

- `bootstrap/terraform-state/`: owns the S3/KMS remote-state foundation and nothing else.
- `environments/platform/`: owns the single deployable platform composition, provider configuration, backend declaration, variables, and outputs.
- `modules/platform_cluster/`: owns VPC, EKS Fargate, logging, controller IAM, and capability AWS resources.
- `modules/platform_cluster_bootstrap/`: owns Argo CD cluster registration and the root ApplicationSet.
- `modules/ack_iam_role_selector/`: reusable ACK namespace IAM module; created but not instantiated.
- `gitops/platform/bootstrap/`: child ApplicationSets discovered by the Terraform-created root ApplicationSet.
- `gitops/platform/config/`: Fargate-compatible controllers, observability, and kro resources.
- `gitops/platform/charts/namespace-config/`: reusable namespace tenancy chart with no release in this plan.
- `gitops/workloads/README.md`: empty workload contract for future service plans.
- `.github/workflows/terraform-ci.yaml`: HCL/Terraform blocking checks.
- `.github/workflows/yaml-ci.yaml`: YAML, Helm, Kustomize, and Kubernetes blocking checks.
- `scripts/`: prerequisite, readiness, drift, and destroy helpers with no hidden mutation.
- `docs/operations/`: exact bootstrap, deployment, validation, and recovery runbooks.

### Task 1: Initialize the Repository Contract

**Files:**
- Create: `AGENTS.md`
- Create: `.gitignore`
- Create: `README.md`
- Create: `Makefile`
- Create: `gitops/workloads/README.md`
- Create directories described in the planned file map

**Interfaces:**
- Consumes: the approved design specification.
- Produces: stable paths and top-level commands used by every later task.

- [ ] **Step 1: Create the directory skeleton**

Create all directories from the planned file map. Keep empty directories only when Task 1 adds a README; Git does not track empty directories.

- [ ] **Step 2: Add repository exclusions**

Create `.gitignore` with these exact rules:

```gitignore
**/.terraform/*
*.tfstate
*.tfstate.*
*.tfplan
*.tflock
backend.hcl
terraform.tfvars
override.tf
override.tf.json
*_override.tf
*_override.tf.json
.DS_Store
.idea/
.vscode/
```

- [ ] **Step 3: Add contributor instructions**

Create `AGENTS.md` with these required rules:

```markdown
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
```

- [ ] **Step 4: Add top-level commands**

Create `Makefile`:

```makefile
.PHONY: terraform-fmt terraform-validate terraform-lint terraform-check yaml-lint helm-check kustomize-check yaml-check

TF_ROOTS := bootstrap/terraform-state environments/platform modules/platform_cluster modules/platform_cluster_bootstrap modules/ack_iam_role_selector

terraform-fmt:
	terraform fmt -check -recursive

terraform-validate:
	@for root in $(TF_ROOTS); do \
		if [ -f "$$root/versions.tf" ]; then \
			terraform -chdir=$$root init -backend=false -input=false >/dev/null; \
			terraform -chdir=$$root validate; \
		fi; \
	done

terraform-lint:
	tflint --init
	tflint --recursive --config "$$(pwd)/.tflint.hcl"

terraform-check: terraform-fmt terraform-validate terraform-lint
	checkov -d . --framework terraform --config-file .checkov.yml

yaml-lint:
	yamllint -c .yamllint.yml .

helm-check:
	@if [ -f gitops/platform/charts/namespace-config/Chart.yaml ]; then \
		helm lint gitops/platform/charts/namespace-config -f gitops/platform/charts/namespace-config/values-test.yaml; \
		helm template namespace-config gitops/platform/charts/namespace-config -f gitops/platform/charts/namespace-config/values-test.yaml > /tmp/namespace-config-rendered.yaml; \
		kubeconform -strict -summary -ignore-missing-schemas /tmp/namespace-config-rendered.yaml; \
	fi

kustomize-check:
	@find gitops -name kustomization.yaml -print0 | while IFS= read -r -d '' file; do \
		dir=$$(dirname "$$file"); \
		kubectl kustomize "$$dir" | kubeconform -strict -summary -ignore-missing-schemas; \
	done

yaml-check: yaml-lint helm-check kustomize-check
```

- [ ] **Step 5: Document the empty workload contract**

Create `gitops/workloads/README.md` stating that later service plans must use `apps-*` namespaces, Fargate-compatible security contexts, and ALB IP targets, and that this plan intentionally contains no workload manifests.

- [ ] **Step 6: Verify and commit**

Run:

```bash
git status --short
git diff --check
```

Expected: only Task 1 files are untracked or modified; `git diff --check` prints nothing.

Commit:

```bash
git add AGENTS.md .gitignore README.md Makefile gitops/workloads/README.md
git commit -m "chore: initialize eks infrastructure repository"
```

### Task 2: Add GitHub Quality Gates

**Files:**
- Create: `.github/workflows/terraform-ci.yaml`
- Create: `.github/workflows/yaml-ci.yaml`
- Create: `.tflint.hcl`
- Create: `.checkov.yml`
- Create: `.yamllint.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 1 paths and Make targets.
- Produces: required `terraform-ci` and `yaml-ci` checks for all later pull requests.

- [ ] **Step 1: Configure Terraform linting and scanning**

Create `.tflint.hcl`:

```hcl
config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.42.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
```

Create `.checkov.yml`:

```yaml
compact: true
download-external-modules: true
evaluate-variables: true
framework:
  - terraform
quiet: true
skip-check:
  - CKV_TF_1
```

- [ ] **Step 2: Configure YAML linting**

Create `.yamllint.yml`:

```yaml
extends: default

ignore: |
  gitops/platform/charts/namespace-config/templates/

rules:
  document-start: disable
  line-length:
    max: 120
    level: warning
  truthy:
    allowed-values: ["true", "false"]
    check-keys: false
```

- [ ] **Step 3: Add `terraform-ci.yaml`**

Create `.github/workflows/terraform-ci.yaml`:

```yaml
name: terraform-ci

on:
  pull_request:
    paths:
      - "**/*.tf"
      - "**/*.tfvars.example"
      - ".tflint.hcl"
      - ".checkov.yml"
      - "Makefile"
      - ".github/workflows/terraform-ci.yaml"
  push:
    branches: [main]
    paths:
      - "**/*.tf"
      - "**/*.tfvars.example"
      - ".tflint.hcl"
      - ".checkov.yml"
      - "Makefile"
      - ".github/workflows/terraform-ci.yaml"

permissions:
  contents: read

concurrency:
  group: terraform-ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  terraform-ci:
    name: terraform-ci
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4.2.2
      - uses: hashicorp/setup-terraform@v3.1.2
        with:
          terraform_version: 1.10.5
      - uses: terraform-linters/setup-tflint@v4.1.1
        with:
          tflint_version: v0.59.1
      - name: Install Checkov
        run: pip install --disable-pip-version-check checkov==3.2.471
      - name: Check formatting
        run: terraform fmt -check -recursive
      - name: Validate Terraform roots
        shell: bash
        run: |
          set -euo pipefail
          roots=(
            bootstrap/terraform-state
            environments/platform
            modules/platform_cluster
            modules/platform_cluster_bootstrap
            modules/ack_iam_role_selector
          )
          for root in "${roots[@]}"; do
            test -f "$root/versions.tf" || continue
            terraform -chdir="$root" init -backend=false -input=false
            terraform -chdir="$root" validate
          done
      - name: Run TFLint
        run: |
          tflint --init
          tflint --recursive --config "$GITHUB_WORKSPACE/.tflint.hcl"
      - name: Run Checkov
        run: checkov -d . --framework terraform --config-file .checkov.yml
```

- [ ] **Step 4: Add `yaml-ci.yaml`**

Create `.github/workflows/yaml-ci.yaml`:

```yaml
name: yaml-ci

on:
  pull_request:
    paths:
      - "**/*.yaml"
      - "**/*.yml"
      - "gitops/**"
      - ".yamllint.yml"
      - "Makefile"
      - ".github/workflows/yaml-ci.yaml"
  push:
    branches: [main]
    paths:
      - "**/*.yaml"
      - "**/*.yml"
      - "gitops/**"
      - ".yamllint.yml"
      - "Makefile"
      - ".github/workflows/yaml-ci.yaml"

permissions:
  contents: read

concurrency:
  group: yaml-ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  yaml-ci:
    name: yaml-ci
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4.2.2
      - uses: azure/setup-helm@v4.3.0
        with:
          version: v3.18.4
      - uses: azure/setup-kubectl@v4.0.1
        with:
          version: v1.35.0
      - name: Install YAML tools
        shell: bash
        run: |
          set -euo pipefail
          pip install --disable-pip-version-check yamllint==1.37.1
          curl --fail --location --silent --show-error \
            https://github.com/yannh/kubeconform/releases/download/v0.7.0/kubeconform-linux-amd64.tar.gz \
            --output /tmp/kubeconform.tar.gz
          tar -xzf /tmp/kubeconform.tar.gz -C /tmp kubeconform
          sudo install /tmp/kubeconform /usr/local/bin/kubeconform
      - name: Validate YAML and Kubernetes manifests
        run: make yaml-check
```

- [ ] **Step 5: Test workflow syntax locally**

Run:

```bash
yamllint -c .yamllint.yml .github/workflows .yamllint.yml .checkov.yml
git diff --check
```

Expected: zero errors. Warnings from the configured line-length rule are acceptable only when emitted as warnings.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/terraform-ci.yaml .github/workflows/yaml-ci.yaml .tflint.hcl .checkov.yml .yamllint.yml README.md
git commit -m "ci: add terraform and yaml quality gates"
```

After the workflows run successfully once, configure a GitHub ruleset for `main` that requires `terraform-ci` and `yaml-ci`, requires a pull request, and blocks force pushes. Record this one-time setting in `README.md`; do not add a GitHub Terraform provider.

### Task 3: Create and Migrate the Remote State Foundation

**Files:**
- Create: `bootstrap/terraform-state/versions.tf`
- Create: `bootstrap/terraform-state/providers.tf`
- Create: `bootstrap/terraform-state/variables.tf`
- Create: `bootstrap/terraform-state/main.tf`
- Create: `bootstrap/terraform-state/outputs.tf`
- Create: `bootstrap/terraform-state/backend.tf` after the first apply
- Create: `bootstrap/terraform-state/backend.hcl.example`
- Create: `bootstrap/terraform-state/terraform.tfvars.example`
- Create: `docs/operations/terraform-state.md`

**Interfaces:**
- Produces: `state_bucket_name`, `state_kms_key_arn`, and backend keys consumed by `environments/platform`.

- [ ] **Step 1: Define provider constraints and inputs**

Use Terraform `>= 1.10.0` and AWS Provider `~> 6.0`. Define `aws_region`, `aws_profile`, and `resource_prefix` variables; set `resource_prefix = "aws-eks-infra"`. Configure the AWS provider with default tags `ManagedBy = "Terraform"`, `Project = var.resource_prefix`, and `Environment = "platform"`.

- [ ] **Step 2: Implement protected state resources**

In `main.tf`, use `data.aws_caller_identity.current` and create:

```hcl
locals {
  bucket_name = "${var.resource_prefix}-${data.aws_caller_identity.current.account_id}-${var.aws_region}-tfstate"
}

resource "aws_kms_key" "terraform_state" {
  description             = "KMS key for ${var.resource_prefix} Terraform state"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "terraform_state" {
  name          = "alias/${var.resource_prefix}-terraform-state"
  target_key_id = aws_kms_key.terraform_state.key_id
}

resource "aws_s3_bucket" "terraform_state" {
  bucket        = local.bucket_name
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.terraform_state.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

Add an `aws_s3_bucket_policy` with explicit denies for `aws:SecureTransport = false`, missing `aws:kms` encryption, and a KMS key ID different from `aws_kms_key.terraform_state.arn`.

- [ ] **Step 3: Apply locally and verify protections**

Run:

```bash
terraform -chdir=bootstrap/terraform-state init
terraform -chdir=bootstrap/terraform-state fmt -check
terraform -chdir=bootstrap/terraform-state validate
terraform -chdir=bootstrap/terraform-state plan -out=tfplan
terraform -chdir=bootstrap/terraform-state apply tfplan
```

Expected: one KMS key/alias and one protected, versioned S3 bucket are created.

- [ ] **Step 4: Add the backend and migrate state**

Create `backend.tf`:

```hcl
terraform {
  backend "s3" {}
}
```

Run:

```bash
STATE_BUCKET=$(terraform -chdir=bootstrap/terraform-state output -raw state_bucket_name)
STATE_KMS_KEY=$(terraform -chdir=bootstrap/terraform-state output -raw state_kms_key_arn)
terraform -chdir=bootstrap/terraform-state init -migrate-state \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=bootstrap/terraform.tfstate" \
  -backend-config="region=$(aws configure get region)" \
  -backend-config="encrypt=true" \
  -backend-config="kms_key_id=$STATE_KMS_KEY" \
  -backend-config="use_lockfile=true"
```

Expected: Terraform asks to migrate local state, completes successfully, and `terraform state list` reads from S3.

- [ ] **Step 5: Verify and commit**

Run `make terraform-check` and `terraform -chdir=bootstrap/terraform-state plan -detailed-exitcode`; expect exit code `0`.

```bash
git add bootstrap/terraform-state docs/operations/terraform-state.md
git commit -m "feat: add terraform remote state bootstrap"
```

### Task 4: Add the Platform Root, Identity Center Group, and CodeConnections

**Files:**
- Create: `environments/platform/backend.tf`
- Create: `environments/platform/backend.hcl.example`
- Create: `environments/platform/versions.tf`
- Create: `environments/platform/providers.tf`
- Create: `environments/platform/variables.tf`
- Create: `environments/platform/main.tf`
- Create: `environments/platform/outputs.tf`
- Create: `environments/platform/terraform.tfvars.example`
- Create: `docs/operations/github-connection.md`

**Interfaces:**
- Produces: CodeConnections ARN/endpoint and Identity Center admin group ID for Task 8 and Task 9.

- [ ] **Step 1: Define the platform root contract**

Require Terraform `>= 1.10.0` and AWS Provider `~> 6.0`. Declare an empty S3 backend and configure AWS from `aws_profile` and `aws_region`. Do not configure the Kubernetes provider until Task 9, after the cluster and Argo CD CRDs exist.

Define typed variables for `aws_profile`, `aws_region`, `resource_prefix`, `vpc_cidr`, `kubernetes_version`, `public_access_cidrs`, `github_owner`, `github_repository`, and `argocd_admin_user_ids`. Defaults are `resource_prefix = "aws-eks-infra"`, `kubernetes_version = "1.35"`, `github_owner = "HuyNguyen260398"`, and `github_repository = "aws-eks-infra"`. Require at least one admin user ID and at least one non-`0.0.0.0/0` public CIDR.

- [ ] **Step 2: Manage the platform-specific Identity Center group**

Use `data.aws_ssoadmin_instances.current`, assert exactly one instance, then create:

```hcl
resource "aws_identitystore_group" "argocd_admins" {
  display_name      = "${var.resource_prefix}-argocd-admins"
  description       = "Administrators for the ${var.resource_prefix} managed Argo CD capability"
  identity_store_id = local.identity_store_id
}

resource "aws_identitystore_group_membership" "argocd_admins" {
  for_each          = toset(var.argocd_admin_user_ids)
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.argocd_admins.group_id
  member_id         = each.value
}
```

- [ ] **Step 3: Manage CodeConnections**

Create `aws_codeconnections_connection.github` with name `${var.resource_prefix}-github`, provider type `GitHub`, and platform tags. Derive the connection ID from its ARN and construct the documented endpoint:

```hcl
locals {
  connection_id = element(reverse(split("/", aws_codeconnections_connection.github.arn)), 0)
  gitops_repo_url = format(
    "https://codeconnections.%s.amazonaws.com/git-http/%s/%s/%s/%s/%s.git",
    var.aws_region,
    data.aws_caller_identity.current.account_id,
    var.aws_region,
    local.connection_id,
    var.github_owner,
    var.github_repository,
  )
}
```

- [ ] **Step 4: Initialize the platform backend and create the connection**

Initialize with the state-bootstrap outputs and key `platform/terraform.tfstate`. Apply the root while it contains only the Identity Center and CodeConnections resources. Complete GitHub authorization in AWS Developer Tools → Connections, restricting the installation to `HuyNguyen260398/aws-eks-infra`.

Verify:

```bash
aws codeconnections get-connection \
  --connection-arn "$(terraform -chdir=environments/platform output -raw github_connection_arn)" \
  --query 'Connection.ConnectionStatus' \
  --output text
```

Expected: `AVAILABLE`.

- [ ] **Step 5: Commit**

Run `make terraform-check` and a no-change platform plan, then:

```bash
git add environments/platform docs/operations/github-connection.md
git commit -m "feat: add platform foundation and github connection"
```

### Task 5: Add Three-AZ VPC Networking

**Files:**
- Create: `modules/platform_cluster/versions.tf`
- Create: `modules/platform_cluster/variables.tf`
- Create: `modules/platform_cluster/data.tf`
- Create: `modules/platform_cluster/locals.tf`
- Create: `modules/platform_cluster/vpc.tf`
- Create: `modules/platform_cluster/outputs.tf`
- Modify: `environments/platform/main.tf`
- Modify: `environments/platform/outputs.tf`

**Interfaces:**
- Produces: VPC ID, VPC ARN, three private subnet IDs, and three public subnet IDs for Fargate, logging, and future ALBs.

- [ ] **Step 1: Define the module boundary**

Require AWS Provider `~> 6.0`. Define variables for Region, prefix, environment, VPC CIDR, Kubernetes version, endpoint CIDRs, Identity Center values, GitHub connection values, and tags. Set `environment = "platform"` at the root.

- [ ] **Step 2: Implement the VPC**

Use `terraform-aws-modules/vpc/aws ~> 6.0`, select three available AZs, calculate non-overlapping public/private subnets from `var.vpc_cidr`, enable DNS support/hostnames, create one NAT gateway, and tag subnets:

```hcl
public_subnet_tags = {
  "kubernetes.io/role/elb" = "1"
}

private_subnet_tags = {
  "kubernetes.io/role/internal-elb" = "1"
}
```

Do not create VPC endpoints in this task.

- [ ] **Step 3: Compose and apply**

Add `module.platform_cluster` to `environments/platform/main.tf`, passing all root variables including `resource_prefix`; this explicitly fixes the source repository's missing prefix forwarding.

Run format, validate, TFLint, Checkov, saved plan, and apply. Verify six subnets across three AZs and one NAT gateway.

- [ ] **Step 4: Commit**

```bash
git add modules/platform_cluster environments/platform/main.tf environments/platform/outputs.tf
git commit -m "feat: add platform vpc networking"
```

### Task 6: Add the Serverless EKS Fargate Cluster

**Files:**
- Create: `modules/platform_cluster/iam_fargate.tf`
- Create: `modules/platform_cluster/eks.tf`
- Modify: `modules/platform_cluster/outputs.tf`
- Modify: `environments/platform/outputs.tf`
- Create: `docs/operations/cluster-access.md`

**Interfaces:**
- Consumes: Task 5 private subnets.
- Produces: cluster name/ARN/endpoint/CA, OIDC provider ARN/URL, and Fargate profile status inputs used by Tasks 7–10.

- [ ] **Step 1: Create the shared Fargate Pod execution role**

Create an IAM role trusted by `eks-fargate-pods.amazonaws.com`, attach `AmazonEKSFargatePodExecutionRolePolicy`, and add least-privilege CloudWatch Logs permissions for `/aws/eks/${local.cluster_name}/fargate/*`.

- [ ] **Step 2: Configure the EKS module**

Use `terraform-aws-modules/eks/aws ~> 21.0` with:

```hcl
name                          = local.cluster_name
kubernetes_version            = var.kubernetes_version
authentication_mode           = "API"
endpoint_private_access       = true
endpoint_public_access        = true
endpoint_public_access_cidrs  = var.public_access_cidrs
enable_irsa                   = true
enable_cluster_creator_admin_permissions = true
compute_config = { enabled = false }
```

Set VPC/private subnets and create no EKS managed node groups. Configure the CoreDNS add-on before compute with `computeType = "Fargate"`. Define three Fargate profiles using the shared execution role:

```hcl
fargate_profiles = {
  system = {
    name       = "${local.cluster_name}-system"
    subnet_ids = module.vpc.private_subnets
    iam_role_arn = aws_iam_role.fargate_pod_execution.arn
    selectors = [{ namespace = "kube-system" }]
  }
  platform_addons = {
    name       = "${local.cluster_name}-platform-addons"
    subnet_ids = module.vpc.private_subnets
    iam_role_arn = aws_iam_role.fargate_pod_execution.arn
    selectors = [
      { namespace = "argo-rollouts" },
      { namespace = "opentelemetry-operator-system" },
      { namespace = "amazon-cloudwatch" },
    ]
  }
  future_workloads = {
    name       = "${local.cluster_name}-future-workloads"
    subnet_ids = module.vpc.private_subnets
    iam_role_arn = aws_iam_role.fargate_pod_execution.arn
    selectors = [{ namespace = "apps-*" }]
  }
}
```

- [ ] **Step 3: Apply and verify serverless compute**

After apply, update kubeconfig and run:

```bash
aws eks list-nodegroups --cluster-name "$(terraform -chdir=environments/platform output -raw cluster_name)"
aws eks list-fargate-profiles --cluster-name "$(terraform -chdir=environments/platform output -raw cluster_name)"
kubectl get nodes -L eks.amazonaws.com/compute-type
kubectl -n kube-system get deployment coredns
```

Expected: no node groups; three Fargate profiles; CoreDNS available; nodes are labeled `fargate` only after Pods require capacity.

- [ ] **Step 4: Commit**

```bash
git add modules/platform_cluster environments/platform/outputs.tf docs/operations/cluster-access.md
git commit -m "feat: add serverless eks fargate cluster"
```

### Task 7: Add Terraform-Managed AWS Observability

**Files:**
- Create: `modules/platform_cluster/observability.tf`
- Create: `modules/platform_cluster/iam_adot.tf`
- Modify: `modules/platform_cluster/eks.tf`
- Modify: `modules/platform_cluster/outputs.tf`
- Create: `docs/operations/observability.md`

**Interfaces:**
- Produces: Fargate log group name and ADOT role ARN consumed by Task 9 and Task 11.

- [ ] **Step 1: Add the observability KMS key and log groups**

Create a rotating KMS key whose policy grants the account root administration and the Regional CloudWatch Logs service encryption/decryption when the encryption context matches `/aws/eks/${local.cluster_name}/*` and `/aws/vpc-flow-logs/${local.cluster_name}`. Create log groups for EKS control-plane logs, Fargate application logs, Container Insights, and VPC Flow Logs with 30-day retention and the KMS key.

- [ ] **Step 2: Enable control-plane and VPC logging**

Set EKS enabled log types to `api`, `audit`, `authenticator`, `controllerManager`, and `scheduler`. Create the VPC Flow Logs IAM role/policy and `aws_flow_log` targeting its CloudWatch log group with all traffic and a one-minute aggregation interval.

- [ ] **Step 3: Add ADOT support**

Create an IRSA role trusted only by `system:serviceaccount:amazon-cloudwatch:adot-collector`, attach `CloudWatchAgentServerPolicy` and `AWSXrayWriteOnlyAccess`, and create the `adot` EKS add-on through Terraform. Do not create the unsupported `amazon-cloudwatch-observability` or Network Flow Monitor agent add-ons.

- [ ] **Step 4: Apply and verify**

Verify all log groups use the expected KMS key, VPC Flow Logs are `ACTIVE`, EKS control-plane logging is enabled, and `aws eks describe-addon --addon-name adot` reports `ACTIVE`.

- [ ] **Step 5: Commit**

```bash
git add modules/platform_cluster docs/operations/observability.md
git commit -m "feat: add fargate observability foundation"
```

### Task 8: Add Managed Argo CD, ACK, and kro Capabilities

**Files:**
- Create: `modules/platform_cluster/iam_capabilities.tf`
- Create: `modules/platform_cluster/capabilities_argocd.tf`
- Create: `modules/platform_cluster/capabilities_ack.tf`
- Create: `modules/platform_cluster/capabilities_kro.tf`
- Modify: `modules/platform_cluster/variables.tf`
- Modify: `modules/platform_cluster/outputs.tf`
- Modify: `environments/platform/main.tf`
- Create: `docs/operations/capabilities.md`

**Interfaces:**
- Consumes: cluster, Identity Center group, CodeConnections ARN.
- Produces: active Argo CD CRDs, capability ARNs, and Argo CD role name for Task 9.

- [ ] **Step 1: Create capability trust roles**

Create one IAM role per capability trusted only by `capabilities.eks.amazonaws.com` for `sts:AssumeRole` and `sts:TagSession`. Attach an inline policy to Argo CD allowing `codeconnections:UseConnection` and `codeconnections:GetConnection` only on the Task 4 connection ARN. Do not attach AWS service permissions to ACK or kro.

- [ ] **Step 2: Create all three capabilities**

Use `aws_eks_capability` resources with `delete_propagation_policy = "RETAIN"`. Configure Argo CD with the discovered Identity Center instance/Region and one `SSO_GROUP` mapping from the Terraform-managed admin group to `ADMIN`. Create ACK type `ACK` and kro type `KRO` after IAM propagation.

- [ ] **Step 3: Grant Argo CD local-cluster deployment access**

Associate `AmazonEKSClusterAdminPolicy` to the Argo CD capability role at cluster scope because this single-cluster platform ApplicationSet must install cluster-scoped CRDs and controllers. Do not add redundant cluster-admin associations to ACK or kro; use their capability-created access policies.

- [ ] **Step 4: Apply and poll readiness**

Poll `aws eks describe-capability` for each name until status is `ACTIVE`, failing on `DEGRADED`, `DELETING`, or `CREATE_FAILED`. Verify `kubectl api-resources` contains Application, ApplicationSet, ResourceGraphDefinition, and IAMRoleSelector APIs.

- [ ] **Step 5: Commit**

```bash
git add modules/platform_cluster environments/platform/main.tf docs/operations/capabilities.md
git commit -m "feat: add managed eks capabilities"
```

### Task 9: Bootstrap GitHub GitOps with Managed Argo CD

**Files:**
- Create: `modules/platform_cluster_bootstrap/versions.tf`
- Create: `modules/platform_cluster_bootstrap/variables.tf`
- Create: `modules/platform_cluster_bootstrap/kubernetes.tf`
- Create: `modules/platform_cluster_bootstrap/outputs.tf`
- Modify: `environments/platform/main.tf`
- Create: `gitops/platform/bootstrap/config-addons.yaml`
- Create: `gitops/platform/bootstrap/config-observability.yaml`
- Create: `gitops/platform/bootstrap/config-kro-definitions.yaml`
- Create: `gitops/platform/bootstrap/config-workloads.yaml`

**Interfaces:**
- Consumes: cluster ARN/name, CodeConnections endpoint, Task 7 role/log outputs, and active Argo CD CRDs.
- Produces: one registered local cluster and one root ApplicationSet that discovers GitHub platform configuration.

- [ ] **Step 1: Define bootstrap inputs and ownership**

Add Kubernetes Provider `~> 3.0` to the platform root and configure it from `module.platform_cluster` endpoint/CA outputs with an `exec` token from `aws eks get-token`. Accept cluster name/ARN, environment, GitOps URL/path/revision, VPC ID, Region, AWS Load Balancer Controller role ARN, ADOT role ARN, and Fargate log group name. Default Git revision to `main` and platform path to `gitops/platform/`.

- [ ] **Step 2: Register the cluster**

Create a `kubernetes_secret_v1` in `argocd` labeled `argocd.argoproj.io/secret-type = cluster`, `platform_cluster = true`, and `workload_cluster = true`. Store non-secret operational values as annotations for ApplicationSet templates. Set secret data `name`, `server = cluster_arn`, and `project = default`.

- [ ] **Step 3: Create the root ApplicationSet**

Create `kubernetes_manifest.bootstrap` in `argocd`. Use the clusters generator matching `platform_cluster`, source `{{ .metadata.annotations.gitops_repo_url }}`, path `{{ .metadata.annotations.gitops_platform_path }}bootstrap`, recursive directory mode, destination `{{ .server }}`, and automated prune/allow-empty sync.

- [ ] **Step 4: Add child ApplicationSets**

Each committed YAML file creates one Application from the same annotated Git URL:

- `config-addons.yaml` → `gitops/platform/config/addons`
- `config-observability.yaml` → `gitops/platform/config/observability`
- `config-kro-definitions.yaml` → `gitops/platform/config/kro-definitions`
- `config-workloads.yaml` → `gitops/workloads`, with allow-empty enabled

Use server-side apply for CRD-heavy add-ons and automated prune only where removal is safe.

- [ ] **Step 5: Apply and verify**

Apply only after Argo CD is `ACTIVE`. Run `kubectl -n argocd get applicationsets` and verify the root plus four children exist. Empty source directories may show no child resources but must not fail sync.

- [ ] **Step 6: Commit**

```bash
git add modules/platform_cluster_bootstrap environments/platform/main.tf gitops/platform/bootstrap
git commit -m "feat: bootstrap github gitops with argocd"
```

### Task 10: Add Fargate-Compatible Platform Controllers

**Files:**
- Create: `modules/platform_cluster/policies/aws-load-balancer-controller.json`
- Create: `modules/platform_cluster/iam_load_balancer_controller.tf`
- Modify: `modules/platform_cluster/outputs.tf`
- Modify: `environments/platform/main.tf`
- Modify: `modules/platform_cluster_bootstrap/kubernetes.tf`
- Create: `gitops/platform/config/addons/aws-load-balancer-controller.yaml`
- Create: `gitops/platform/config/addons/argo-rollouts.yaml`

**Interfaces:**
- Produces: healthy AWS Load Balancer Controller and Argo Rollouts Deployments on Fargate.

- [ ] **Step 1: Vendor and manage the load-balancer IAM policy**

Vendor the official AWS Load Balancer Controller `v2.14.1` IAM policy JSON from the controller release into `modules/platform_cluster/policies/`. Create a Terraform IAM policy from `file(...)` and an IRSA role trusted only by `system:serviceaccount:kube-system:aws-load-balancer-controller`. Output its ARN and add it to the Argo cluster-secret annotations.

- [ ] **Step 2: Define the controller ApplicationSet**

Create an ApplicationSet using AWS Helm repository `https://aws.github.io/eks-charts`, chart `aws-load-balancer-controller`, chart version `1.14.0`, namespace `kube-system`, and values:

```yaml
clusterName: '{{ .metadata.labels.cluster_name }}'
region: '{{ .metadata.annotations.aws_region }}'
vpcId: '{{ .metadata.annotations.vpc_id }}'
serviceAccount:
  create: true
  name: aws-load-balancer-controller
  annotations:
    eks.amazonaws.com/role-arn: '{{ .metadata.annotations.aws_load_balancer_controller_role_arn }}'
```

Set two replicas and do not use Pod Identity.

- [ ] **Step 3: Define Argo Rollouts**

Port the source repository's Argo Rollouts ApplicationSet, retain chart version `2.40.5`, deploy to `argo-rollouts`, and disable the dashboard unless explicitly needed for controller health.

- [ ] **Step 4: Apply Terraform IAM changes and verify GitOps sync**

Verify both Applications are `Synced/Healthy`, controller Pods have Fargate nodes, the LBC service account has the Terraform role annotation, and no load balancer exists because no Ingress or LoadBalancer Service exists.

- [ ] **Step 5: Commit**

```bash
git add modules/platform_cluster modules/platform_cluster_bootstrap environments/platform/main.tf gitops/platform/config/addons
git commit -m "feat: add fargate platform controllers"
```

### Task 11: Add Fargate Telemetry Configuration

**Files:**
- Create: `gitops/platform/config/observability/namespace.yaml`
- Create: `gitops/platform/config/observability/fargate-logging.yaml`
- Create: `gitops/platform/config/observability/adot-service-account.yaml`
- Create: `gitops/platform/config/observability/kustomization.yaml`
- Modify: `modules/platform_cluster_bootstrap/kubernetes.tf`
- Create: `docs/operations/telemetry-validation.md`

**Interfaces:**
- Consumes: Task 7 CloudWatch log group and ADOT role outputs through cluster annotations.
- Produces: Fargate-native log routing and an IRSA-ready ADOT service account; service-specific collectors remain deferred.

- [ ] **Step 1: Configure the Fargate log router**

Create namespace `aws-observability` with label `aws-observability: enabled`. Create ConfigMap `aws-logging` in that namespace using the AWS-supported Fluent Bit output configuration. Send all Fargate container logs to the pre-created log group annotation value, use the cluster name as stream prefix, enable auto-create `false`, and set Region explicitly.

- [ ] **Step 2: Create the ADOT namespace and service account**

Create `amazon-cloudwatch` and ServiceAccount `adot-collector`. Use the observability ApplicationSet to render the Terraform-managed ADOT IRSA role ARN into `eks.amazonaws.com/role-arn`. Do not create an application-specific OpenTelemetryCollector in this plan.

- [ ] **Step 3: Render and validate**

Run:

```bash
kubectl kustomize gitops/platform/config/observability | kubeconform -strict -summary -ignore-missing-schemas
kubectl -n opentelemetry-operator-system get deployment
kubectl -n aws-observability get configmap aws-logging
kubectl -n amazon-cloudwatch get serviceaccount adot-collector -o yaml
```

Expected: manifests validate, the ADOT operator from the Terraform-managed EKS add-on is available, and the service account has the expected IRSA annotation.

- [ ] **Step 4: Commit**

```bash
git add gitops/platform/config/observability modules/platform_cluster_bootstrap/kubernetes.tf docs/operations/telemetry-validation.md
git commit -m "feat: add fargate telemetry configuration"
```

### Task 12: Add Reusable Platform Building Blocks

**Files:**
- Create: `modules/ack_iam_role_selector/*.tf`
- Create: `gitops/platform/charts/namespace-config/**`
- Create: `gitops/platform/config/kro-definitions/webapp-rgd.yaml`
- Create: `gitops/platform/config/kro-definitions/kustomization.yaml`
- Create: `gitops/platform/config/addons/kustomization.yaml`
- Create: `gitops/platform/config/observability/kustomization.yaml`

**Interfaces:**
- Produces: reusable but uninstantiated namespace, ACK permission, and kro workload abstractions.

- [ ] **Step 1: Port the ACK IAM selector module**

Port `modules/ack_iam_role_selector` from the source repository. Retain typed namespace/resource selectors and inline/managed policy support. Add variable validation requiring at least one inline statement or managed policy ARN. Do not call the module from `environments/platform`.

- [ ] **Step 2: Port and validate the namespace chart**

Port `repositories/platform/charts/namespace-config` to `gitops/platform/charts/namespace-config`. Preserve Namespace, ResourceQuota, LimitRange, NetworkPolicy, Role, and RoleBinding templates. Keep `values.yaml` non-deploying by default and `values-test.yaml` as a complete synthetic tenant used only by CI.

- [ ] **Step 3: Port and adapt the kro WebApp RGD**

Port the source `webapp-rgd.yaml`. Preserve Rollout, active/preview Services, and active/preview Ingress generation. Add these annotations to both generated Ingresses:

```yaml
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/scheme: internet-facing
```

Do not create a `WebApp` instance.

- [ ] **Step 4: Run all static quality gates**

Run:

```bash
make terraform-check
make yaml-check
```

Expected: Terraform, Helm, Kustomize, YAML, and Kubernetes schema checks pass.

- [ ] **Step 5: Verify zero workloads and commit**

Run `find gitops/workloads -type f`; expected output is only `gitops/workloads/README.md`. Run `kubectl get ingress -A`; expected output contains no application Ingress.

```bash
git add modules/ack_iam_role_selector gitops/platform/charts gitops/platform/config
git commit -m "feat: add gitops platform building blocks"
```

### Task 13: Add Operations, Acceptance, and Safe Destruction

**Files:**
- Create: `scripts/verify-prerequisites.sh`
- Create: `scripts/verify-platform.sh`
- Create: `scripts/check-drift.sh`
- Create: `scripts/destroy-platform.sh`
- Create: `docs/operations/deploy-platform.md`
- Create: `docs/operations/validate-platform.md`
- Create: `docs/operations/destroy-platform.md`
- Modify: `README.md`
- Modify: `Makefile`

**Interfaces:**
- Produces: the final operator-facing start-from-scratch sequence and executable acceptance gates.

- [ ] **Step 1: Implement non-mutating prerequisite checks**

`verify-prerequisites.sh` must use `set -euo pipefail`, check Terraform `>=1.10`, AWS CLI, kubectl, Helm, TFLint, Checkov, yamllint, kubeconform, Git, AWS caller identity, configured Region, one Identity Center instance, and access to `HuyNguyen260398/aws-eks-infra`. It must not install tools or change AWS/GitHub state.

- [ ] **Step 2: Implement platform readiness checks**

`verify-platform.sh` must assert:

- CodeConnections is `AVAILABLE`.
- EKS and all Fargate profiles are `ACTIVE`.
- `aws eks list-nodegroups` is empty.
- Argo CD, ACK, and kro capabilities are `ACTIVE`.
- CoreDNS, AWS Load Balancer Controller, Argo Rollouts, and ADOT operator Deployments are available.
- Argo CD Applications are Synced and Healthy.
- No namespaces matching the service convention contain workloads.
- No Ingress or LoadBalancer Service exists.

Print one PASS/FAIL line per assertion and return nonzero on any failure.

- [ ] **Step 3: Implement drift and destroy helpers**

`check-drift.sh` runs refreshed plans for both Terraform roots and exits successfully only for detailed exit code `0`. `destroy-platform.sh` requires the literal confirmation `destroy platform`, refuses to touch `bootstrap/terraform-state`, verifies no workload Applications exist, removes GitOps bootstrap resources first, and then runs a reviewed platform destroy plan. It must never use `-auto-approve`.

- [ ] **Step 4: Write the start-from-scratch runbook**

`deploy-platform.md` must list the exact order from prerequisites through backend migration, CodeConnections authorization, platform apply, capability readiness, GitOps sync, and acceptance. Include expected output at every gate and recovery commands for a pending connection, failed capability, missing CRD, unschedulable Fargate Pod, and unhealthy Argo CD Application.

- [ ] **Step 5: Run final acceptance**

Run:

```bash
make terraform-check
make yaml-check
./scripts/verify-prerequisites.sh
./scripts/verify-platform.sh
./scripts/check-drift.sh
git diff --check
git status --short
```

Expected: every command exits `0`; drift plans report no changes; Git contains no state, plan, backend, credential, sample workload, or generated artifact.

- [ ] **Step 6: Commit**

```bash
git add scripts docs/operations README.md Makefile
git commit -m "docs: add platform operations and validation guide"
```

## Final Handoff Checklist

- [ ] Confirm the thirteen task commits exist in order after the design and plan commits.
- [ ] Confirm `terraform-ci` and `yaml-ci` pass and are required by the `main` ruleset.
- [ ] Confirm the remote-state bucket remains protected and excluded from normal destruction.
- [ ] Confirm no service or sample workload was deployed.
- [ ] Record future service deployment and architectural improvement work as separate specifications and plans.
