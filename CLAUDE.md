# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Terraform + GitOps for the single Amazon EKS cluster that hosts **Cashight** (`environments/platform`). It started as a general-purpose reference platform and has been cut down to what Cashight needs, at the lowest cost that still runs it:

- **One Spot Graviton node** (`<cluster>-general`; `t4g.medium`, `m7g.medium` or `m6g.medium`, 4 GiB) in a **public subnet**, so there is no NAT gateway. No Fargate, no Auto Mode, no Karpenter.
- EKS add-ons: VPC CNI (NetworkPolicy enforcement and prefix delegation on), kube-proxy, CoreDNS, EKS Pod Identity Agent.
- **Managed Argo CD is opt-in** (`enable_argocd`, default `false`). It bills per capability-hour and per Application-hour, so it stays off until there is something to deploy. Everything under `gitops/` only takes effect once it is on.
- GitOps add-ons (installed by Argo CD): AWS Load Balancer Controller, cert-manager (issues that controller's webhook certificate), Argo Rollouts, KEDA, and the guarded `cashight` namespace.
- Telemetry is not decided yet; the observability plan adds it.

## Commands

```bash
make terraform-check      # fmt -check + validate every root + tflint + checkov  (run for any .tf change)
make yaml-check           # yamllint + helm lint/template + kubeconform + kustomize build  (run for any gitops/ change)
make shell-check          # shellcheck at default severity  (run for any scripts/ change)
```

Sub-targets when you need a narrower loop: `terraform-fmt`, `terraform-validate`, `terraform-lint`, `yaml-lint`, `helm-check`, `kustomize-check`.

`make terraform-validate` does not stop on a failing root: read its output and expect one `Success! The configuration is valid.` per root (four).

Validating a single Terraform root (the equivalent of running one test):

```bash
terraform -chdir=modules/platform_cluster init -backend=false -input=false
terraform -chdir=modules/platform_cluster validate
terraform fmt -recursive          # writes; the check targets use -check
```

Validating a single chart / kustomization:

```bash
helm template namespaces gitops/platform/charts/namespace-config -f gitops/platform/config/namespaces/values.yaml
kubectl kustomize gitops/platform/config/addons | kubeconform -strict -summary -ignore-missing-schemas
```

Operational scripts (require AWS creds + kubeconfig; not part of CI):

```bash
./scripts/verify-prerequisites.sh   # tool + AWS account preflight
./scripts/verify-platform.sh        # acceptance: node, add-ons, published identifiers; GitOps checks when enable_argocd is on
./scripts/check-repo-access.sh <owner> <repo> <revision> <path>   # prove Argo CD can read a repository (needs Argo CD)
./scripts/check-drift.sh            # plan -refresh-only -detailed-exitcode on both stateful roots
./scripts/destroy-platform.sh "destroy platform"   # refuses without the literal argument
```

CI (`.github/workflows/`) runs the same gates with pinned tool versions and **never receives AWS credentials** — no workflow plans or applies infrastructure.

## Architecture

### Ownership boundary (the central invariant)

Terraform owns customer-controlled AWS resources plus the *minimum* Argo CD bootstrap objects. Argo CD owns everything under `gitops/`. **No resource may be managed by both.** When adding platform functionality, decide which side owns it before writing code — an IAM role goes in Terraform, the ServiceAccount that assumes it goes in GitOps.

### Terraform layering

```
bootstrap/terraform-state/   S3 + KMS remote state (prevent_destroy; native S3 lockfiles, no DynamoDB)
environments/platform/       the only deployable root — budget, Identity Center group, CodeConnections, published SSM identifiers, wires the two modules
modules/platform_cluster/            VPC, EKS, node group, add-ons, IAM (IRSA + Pod Identity), optional Argo CD capability
modules/platform_cluster_bootstrap/  the Terraform→Argo CD handoff (kubernetes provider only; count = enable_argocd)
```

State bootstrap is chicken-and-egg: `bootstrap/terraform-state` is first applied with local state, then migrated into its own bucket via `init -migrate-state` (see `docs/operations/terraform-state.md`).

### Capacity

One managed node group, fixed size (`node_count`, default 1), Spot by default (`node_capacity_type`). `node_instance_types` lists several Graviton types of the same size so Spot can draw from more pools; a variable validation rejects x86 types because the AMI is arm64. A Spot interruption replaces the node and briefly takes everything down — acceptable for a single-user app. Raise `node_count` or pick larger types when Pods stop fitting.

The node sits in a public subnet with a public IPv4 address and reaches AWS APIs and the internet directly. Private subnets remain only for the EKS control-plane ENIs. The node security group admits the control plane on 10250 (kubelet) and the webhook ports 4443, 6443, 8443, 9443 — **an admission webhook or APIService on any other port times out**. Keep chart defaults that use those ports.

Prefix delegation plus `maxPods: 110` (node group `cloudinit_pre_nodeadm`) lifts the 17-Pod limit of a 4 GiB instance; memory is the real limit.

### The Terraform → Argo CD handoff (only with `enable_argocd = true`)

`platform_cluster_bootstrap` writes exactly two things into the cluster:

1. An Argo CD cluster `Secret` labeled `platform_cluster: "true"` / `workload_cluster: "true"`. Every piece of per-cluster wiring (repo URL, revision, path, VPC ID, region, IRSA role ARNs) is carried as **annotations** on that Secret.
2. A `platform-bootstrap` ApplicationSet whose cluster generator matches those labels and interpolates `{{ .metadata.annotations.* }}`.

That ApplicationSet points at `gitops/platform/bootstrap/`, which contains further ApplicationSets (`config-addons`, `config-namespaces`, `config-workloads`) that fan out to `gitops/platform/config/*` and `gitops/workloads/manifests/`. So: **to pass a new value from Terraform into GitOps, add a variable to `platform_cluster_bootstrap`, surface it as a Secret annotation, and reference it as `{{ .metadata.annotations.<name> }}` in an ApplicationSet template.** Do not hardcode account-specific values in YAML.

Turning Argo CD on is a staged apply, because `kubernetes_manifest` needs the Argo CD CRDs at plan time — see `docs/operations/deploy-platform.md`.

The GitOps repo URL is not a plain GitHub URL — it is a CodeConnections Git-HTTP endpoint assembled in `environments/platform/main.tf` from the connection ID. The GitHub App installation behind the connection decides which repositories Argo CD can read (`aws-eks-infra` and `cashight`).

### EKS Capabilities

`aws_eks_capability.argocd` uses `delete_propagation_policy = "RETAIN"` — setting `enable_argocd = false` after it exists leaves it running in AWS; delete it deliberately. Its role is trusted by `capabilities.eks.amazonaws.com` and gets `AmazonEKSClusterAdminPolicy`.

### Public access contract

Reaching a workload from the internet is a **pure-GitOps change**. The workload's Ingress joins the `platform-public` IngressGroup, which the load balancer controller assembles into one shared internet-facing ALB named `platform-public`, routing by path prefix over HTTP on port 80 (HTTPS arrives with Cashight's certificate).

Four annotations are group-level and must be byte-identical on every member — `group.name`, `scheme`, `load-balancer-name`, `listen-ports` — because a mismatch stops the controller reconciling the whole group, not just the new workload. See `docs/operations/public-workload-access.md` for the block to copy.

### Tenant namespaces

Declared in `gitops/platform/config/namespaces/values.yaml` and rendered by the `namespace-config` chart: Pod Security `restricted`, default-deny ingress and egress plus allow-DNS NetworkPolicies, a LimitRange and a ResourceQuota. Workloads bring their own allow policies.

### Published identifiers

`environments/platform/published.tf` writes non-secret identifiers to SSM under `/<resource_prefix>/platform/`: `cluster-name`, `alb-group-name`, `keda-operator-role-arn` and `codeconnections-git-http-base`. Workload repositories read these instead of hardcoding them. `alb-group-name` restates the GitOps IngressGroup name; Terraform does not configure the ALB.

### Cost guardrail

`environments/platform/budget.tf` is an account-wide monthly budget with email alerts. Apply it before anything else in a fresh deployment.

## Conventions

- `snake_case` names, typed variables with descriptions, provider version constraints, deterministic tags from `local.tags`.
- Root and module inputs are cross-validated with `check` blocks (`locals.tf`, `environments/platform/main.tf`) rather than only per-variable `validation`.
- Checkov suppressions are inline `#checkov:skip=CKV_...: <justification>` comments at the resource. Global skips live in `.checkov.yml` (only `CKV_TF_1` today) — prefer the inline form.
- One Conventional Commit per completed plan task; put the exact validation commands in the PR description.
- Never commit `*.tfstate`, `tfplan`, `backend.hcl`, or `terraform.tfvars` — only the `.example` variants are tracked.
- `environments/platform/.terraform.lock.hcl` is tracked. CI resolves `terraform-aws-modules` fresh under `~> 21.0`; when a newer module needs a newer provider, re-resolve only that provider's lock entry (with linux and darwin hashes).

## Gotcha: the Terraform root list is duplicated

Adding a new Terraform root means updating **both** `TF_ROOTS` in the `Makefile` and the hardcoded `roots=(...)` array in `.github/workflows/terraform-ci.yaml`. Miss the second and CI silently stops validating it.

## Reference docs

`docs/operations/` holds the runbooks (deploy, cluster access, capabilities, GitHub connection, public workload access, validate, destroy, Terraform state). `first-deployment-defects.md` records defects from the original Fargate deployment; most Fargate-specific ones no longer apply, but the Argo CD lessons do. `docs/architecture/` holds diagrams of the original reference design; they predate the cut-down and are not current.

`docs/superpowers/specs/` and `docs/superpowers/plans/` hold design and plan documents. They are **gitignored** — present in a local working copy but not tracked, so never link to them from tracked files such as `README.md`.
