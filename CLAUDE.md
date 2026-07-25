# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Terraform + GitOps blueprint for a single Amazon EKS platform (`environments/platform`) that runs **exclusively on AWS Fargate** — no EC2 node groups, no Auto Mode, no Karpenter. Platform controllers come from AWS-managed *EKS Capabilities* (Argo CD, ACK, kro) rather than Helm installs.

## Commands

```bash
make terraform-check      # fmt -check + validate every root + tflint + checkov  (run for any .tf change)
make yaml-check           # yamllint + helm lint/template + kubeconform + kustomize build  (run for any gitops/ change)
make shell-check          # shellcheck at default severity  (run for any scripts/ change)
```

Sub-targets when you need a narrower loop: `terraform-fmt`, `terraform-validate`, `terraform-lint`, `yaml-lint`, `helm-check`, `kustomize-check`.

Validating a single Terraform root (the equivalent of running one test):

```bash
terraform -chdir=modules/platform_cluster init -backend=false -input=false
terraform -chdir=modules/platform_cluster validate
terraform fmt -recursive          # writes; the check targets use -check
```

Validating a single chart / kustomization:

```bash
helm lint gitops/platform/charts/namespace-config -f gitops/platform/charts/namespace-config/values-test.yaml
kubectl kustomize gitops/platform/config/addons | kubeconform -strict -summary -ignore-missing-schemas
```

Operational scripts (require AWS creds + kubeconfig; not part of CI):

```bash
./scripts/verify-prerequisites.sh   # tool + AWS account preflight
./scripts/verify-platform.sh        # acceptance: capabilities ACTIVE, zero node groups, Apps Synced/Healthy
./scripts/check-drift.sh            # plan -refresh-only -detailed-exitcode on both stateful roots
./scripts/destroy-platform.sh "destroy platform"   # refuses without the literal argument
```

CI (`.github/workflows/`) runs the same gates with pinned tool versions and **never receives AWS credentials** — no workflow plans or applies infrastructure.

## Architecture

### Ownership boundary (the central invariant)

Terraform owns customer-controlled AWS resources plus the *minimum* Argo CD bootstrap objects. Argo CD owns everything under `gitops/platform/` and future `gitops/workloads/`. **No resource may be managed by both.** When adding platform functionality, decide which side owns it before writing code — an IRSA role goes in Terraform, the ServiceAccount that assumes it goes in GitOps.

### Terraform layering

```
bootstrap/terraform-state/   S3 + KMS remote state (prevent_destroy; native S3 lockfiles, no DynamoDB)
environments/platform/       the only deployable root — Identity Center group, CodeConnections, wires the two modules
modules/platform_cluster/            VPC, EKS, Fargate profiles, EKS Capabilities, IAM/IRSA, observability
modules/platform_cluster_bootstrap/  the Terraform→Argo CD handoff (kubernetes provider only)
modules/ack_iam_role_selector/       standalone helper for scoping ACK IAM per namespace (not wired into platform yet)
```

State bootstrap is chicken-and-egg: `bootstrap/terraform-state` is first applied with local state, then migrated into its own bucket via `init -migrate-state` (see `docs/operations/terraform-state.md`).

### The Terraform → Argo CD handoff

`platform_cluster_bootstrap` writes exactly two things into the cluster:

1. An Argo CD cluster `Secret` labeled `platform_cluster: "true"` / `workload_cluster: "true"`. Every piece of per-cluster wiring (repo URL, revision, path, VPC ID, region, IRSA role ARNs, log group name) is carried as **annotations** on that Secret.
2. A `platform-bootstrap` ApplicationSet whose cluster generator matches those labels and interpolates `{{ .metadata.annotations.* }}`.

That ApplicationSet points at `gitops/platform/bootstrap/`, which contains further ApplicationSets (`config-addons`, `config-observability`, `config-kro-definitions`, `config-workloads`) that fan out to `gitops/platform/config/*` and `gitops/workloads/`. So: **to pass a new value from Terraform into GitOps, add a variable to `platform_cluster_bootstrap`, surface it as a Secret annotation, and reference it as `{{ .metadata.annotations.<name> }}` in an ApplicationSet template.** Do not hardcode account-specific values in YAML.

The GitOps repo URL is not a plain GitHub URL — it is a CodeConnections Git-HTTP endpoint assembled in `environments/platform/main.tf` from the connection ID.

### EKS Capabilities

`aws_eks_capability` resources (`capabilities_argocd.tf`, `capabilities_ack.tf`, `capabilities_kro.tf`) use `delete_propagation_policy = "RETAIN"` — removing them from config leaves them running in AWS. Each assumes a role trusted by `capabilities.eks.amazonaws.com`. Only the Argo CD capability role gets `AmazonEKSClusterAdminPolicy`; ACK and kro rely on capability-created access and must not receive duplicate cluster-admin associations.

### Fargate namespace contract

Fargate profiles in `modules/platform_cluster/eks.tf` select only: `kube-system`, `argo-rollouts`, `opentelemetry-operator-system`, `amazon-cloudwatch`, and `apps-*`. A Pod in any other namespace gets no capacity and stays Pending. Adding a platform component means adding its namespace to a Fargate profile selector *and* to the GitOps config in the same change.

## Conventions

- `snake_case` names, typed variables with descriptions, provider version constraints, deterministic tags from `local.tags`.
- Root and module inputs are cross-validated with `check` blocks (`locals.tf`, `environments/platform/main.tf`) rather than only per-variable `validation`.
- Checkov suppressions are inline `#checkov:skip=CKV_...: <justification>` comments at the resource. Global skips live in `.checkov.yml` (only `CKV_TF_1` today) — prefer the inline form.
- One Conventional Commit per completed plan task; put the exact validation commands in the PR description.
- Never commit `*.tfstate`, `tfplan`, `backend.hcl`, or `terraform.tfvars` — only the `.example` variants are tracked.

## Gotcha: the Terraform root list is duplicated

Adding a new Terraform root means updating **both** `TF_ROOTS` in the `Makefile` and the hardcoded `roots=(...)` array in `.github/workflows/terraform-ci.yaml`. Miss the second and CI silently stops validating it.

## Reference docs

`docs/operations/` holds the runbooks (deploy, cluster access, capabilities, GitHub connection, observability, telemetry validation, drift/validate, destroy). `docs/superpowers/specs/` and `docs/superpowers/plans/` hold the approved architecture design and the task-by-task implementation plan this repo was built from.
