# Deploy the platform

Start-from-scratch procedure for the `platform` environment: one EKS cluster with a single Spot Graviton node, and managed Argo CD when `enable_argocd = true`. Follow the stages in order; each stage has a gate that must pass before the next one begins.

The cluster bills from the moment it exists (about USD 96/month without Argo CD). Stages 1–3 cost almost nothing; create the cluster (Stage 4) only when something is ready to run on it.

## Conventions

Every command runs from the repository root. Export the environment once per shell:

```bash
export AWS_PROFILE=default
export AWS_REGION=ap-southeast-1
```

If you sign in with `aws login`, Terraform cannot read that session directly; export it first with `eval "$(aws configure export-credentials --format env)"`.

`terraform.tfvars`, `backend.hcl`, and `tfplan` are ignored by Git and never committed.

## Stage 1 — Prerequisites

```bash
./scripts/verify-prerequisites.sh
```

Gate: exits `0`. It checks Terraform >= 1.10, AWS CLI, kubectl, Helm, TFLint, Checkov, yamllint, kubeconform, Git, AWS caller identity, a configured Region, exactly one IAM Identity Center instance, and access to the GitOps repository. It installs nothing and changes no AWS or GitHub state.

Collect the IAM Identity Center user IDs that will administer Argo CD:

```bash
aws identitystore list-users \
  --identity-store-id "$(aws sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text)" \
  --query 'Users[].{id:UserId,name:UserName}' --output table
```

## Stage 2 — State foundation

Only when the state bucket does not exist. If `aws s3 ls | grep tfstate` already lists `<prefix>-<account>-<region>-tfstate`, skip to Stage 3.

Follow [Terraform state](terraform-state.md): apply `bootstrap/terraform-state` with local state, then re-run `init -migrate-state` against the bucket it just created. A `backend_override.tf` containing `terraform { backend "local" {} }` (gitignored) lets the first apply run with local state; delete it before migrating.

Gate:

```bash
terraform -chdir=bootstrap/terraform-state plan -detailed-exitcode
```

Exit code `0` means the state foundation is applied and drift-free. The bucket and KMS key carry `prevent_destroy`.

## Stage 3 — Budget, Identity Center group, GitHub authorization

Create `environments/platform/backend.hcl` and `environments/platform/terraform.tfvars` from their `.example` files. `public_access_cidrs` must be your egress address as a `/32`; `0.0.0.0/0` is rejected by variable validation.

```bash
terraform -chdir=environments/platform init -backend-config=backend.hcl
terraform -chdir=environments/platform apply \
  -target=aws_budgets_budget.account_monthly \
  -target=aws_identitystore_group.argocd_admins \
  -target=aws_identitystore_group_membership.argocd_admins \
  -target=aws_codeconnections_connection.github
```

The budget is account-wide and alerts by email at 50/80/100% of actual and 100% of forecast spend. Applying it first means the alarm exists before the cluster costs anything.

A new connection is created in `PENDING`. Complete the handshake in the console — **CodePipeline → Settings → Connections** (also reachable as Developer Tools → Settings → Connections), Region Singapore — granting the GitHub App installation access to this repository **and** `cashight`. See [GitHub CodeConnections](github-connection.md).

Gate:

```bash
aws codeconnections get-connection \
  --connection-arn "$(terraform -chdir=environments/platform output -raw github_connection_arn)" \
  --query 'Connection.ConnectionStatus' --output text
```

Expected: `AVAILABLE`.

## Stage 4 — Cluster and node

With `enable_argocd = false` (the default) the root has no Kubernetes resources, so it applies in one step:

```bash
terraform -chdir=environments/platform plan -out=tfplan
terraform -chdir=environments/platform apply tfplan
aws eks update-kubeconfig --name "$(terraform -chdir=environments/platform output -raw cluster_name)" --region "$AWS_REGION"
```

Review the saved plan before applying. On a first deployment it creates about 70 resources: the VPC (three public and three private subnets, an internet gateway, no NAT gateway), the EKS cluster, one managed node group, the VPC CNI, kube-proxy, Pod Identity Agent and CoreDNS add-ons, the load balancer controller (IRSA) and KEDA (Pod Identity) roles, two KMS keys, the control-plane log group, and four SSM parameters. It must show **no changes** to the Stage 3 resources. Expect 15–20 minutes, most of it the EKS control plane.

Gate:

```bash
cluster="$(terraform -chdir=environments/platform output -raw cluster_name)"
aws eks describe-nodegroup --cluster-name "$cluster" --nodegroup-name "${cluster}-general" --query 'nodegroup.status' --output text   # ACTIVE
kubectl get nodes -L kubernetes.io/arch,eks.amazonaws.com/capacityType,node.kubernetes.io/instance-type                             # 1 arm64 SPOT node
kubectl get nodes -o jsonpath='{.items[*].status.capacity.pods}'; echo                                                               # 110
./scripts/verify-platform.sh
```

`verify-platform.sh` prints `SKIP GitOps and workload checks (enable_argocd = false)` and must otherwise print only `PASS`.

## Stage 5 — Turn on Argo CD (when there is something to deploy)

Managed Argo CD costs about USD 27/month plus about USD 1.32 per Argo CD Application/month, so turn it on when Cashight is ready to deploy.

The apply is staged. `modules/platform_cluster_bootstrap` writes Argo CD objects with the `kubernetes` provider, and `kubernetes_manifest` validates against the live API server during **plan**, so the Argo CD `ApplicationSet` CRD must already exist — and it only arrives with the capability. Create the capability first, then the bootstrap.

Set `enable_argocd = true` in `terraform.tfvars`. Argo CD reads GitHub, not your working tree, so push the GitOps branch first; while it is unmerged, set `gitops_revision` to it.

```bash
terraform -chdir=environments/platform plan -target=module.platform_cluster -out=tfplan
terraform -chdir=environments/platform apply tfplan
```

The targeted plan adds only the Argo CD capability, its IAM role and policy, and its access policy association. Terraform prints a `Resource targeting is in effect` warning; that is expected here. Poll the capability to `ACTIVE` using the loop in [managed EKS capabilities](capabilities.md#verify-readiness); `DEGRADED`, `CREATE_FAILED`, `UPDATE_FAILED` and `DELETING` are terminal. Then:

```bash
kubectl api-resources | grep -E 'applications|applicationsets'   # both present
terraform -chdir=environments/platform plan -out=tfplan
terraform -chdir=environments/platform apply tfplan
```

Gate: the second plan adds only `module.platform_cluster_bootstrap` resources (the Argo CD cluster `Secret` and the `platform-bootstrap` ApplicationSet) and shows no changes to `module.platform_cluster`.

## Stage 6 — GitOps sync and acceptance

```bash
kubectl -n argocd get applicationsets
kubectl -n argocd get applications -o wide
./scripts/verify-platform.sh
./scripts/check-repo-access.sh <owner> cashight <revision> docs
./scripts/check-drift.sh
```

Expected: the root plus three child ApplicationSets (`platform-addons`, `platform-namespaces`, `platform-workloads`), every Application `Synced` / `Healthy`, `verify-platform.sh` printing `PASS` on every assertion, the repository probe printing `PASS`, and drift exit code `0` for both stateful roots. Once Cashight is deployed, run `EXPECT_WORKLOADS=true ./scripts/verify-platform.sh`.

## Recovery

### Connection stuck in `PENDING`

Authorization is a human step and cannot be automated. Re-open the connection in the console and complete the GitHub App install. If the app was installed against the wrong account, delete the connection in the console and re-apply the `aws_codeconnections_connection.github` target.

### Node never becomes Ready

```bash
aws eks describe-nodegroup --cluster-name "$cluster" --nodegroup-name "${cluster}-general" --query 'nodegroup.health'
aws eks describe-addon --cluster-name "$cluster" --addon-name vpc-cni --query 'addon.[status,health]'
```

The VPC CNI, kube-proxy and Pod Identity Agent are created before the node group (`before_compute`); a node without a working VPC CNI stays `NotReady`. A Spot capacity shortage shows as `nodegroup.health.issues` — add another Graviton type of the same size to `node_instance_types`, or set `node_capacity_type = "ON_DEMAND"`.

### Webhook calls time out

The node security group admits the control plane only on 10250, 4443, 6443, 8443 and 9443. An admission webhook or aggregated APIService served on any other port fails with `context deadline exceeded`. Keep the chart's default port, or move it to one of those.

### Capability `CREATE_FAILED` or `DEGRADED`

```bash
aws eks describe-capability --cluster-name "$cluster" --capability-name "${cluster}-argocd"
aws iam get-role --role-name "${cluster}-argocd-capability"
```

Most failures are IAM propagation or trust policy. Confirm the role trusts only `capabilities.eks.amazonaws.com` for `sts:AssumeRole` and `sts:TagSession`, and that its inline policy scopes `codeconnections:UseConnection` to the Terraform-managed connection ARN. The capability uses `delete_propagation_policy = "RETAIN"`, so setting `enable_argocd = false` leaves it running in AWS — delete it deliberately in the console.

### `Failed to construct REST client` during plan

The cluster is unreachable or absent, or the Argo CD CRDs are not installed yet. You are planning the bootstrap before Stage 5's targeted apply completed, or your kubeconfig/credentials expired.

### `Invalid count argument` during plan

A data source inside a child module resolved to unknown. This is what a module-level `depends_on` causes: it defers every data source in that module to apply time. Do not add `depends_on` to `module.eks`; express ordering through real value references instead.

### Application not `Synced` / `Healthy`

```bash
kubectl -n argocd get application <name> -o jsonpath='{.status.conditions}'
kubectl -n argocd describe applicationset platform-bootstrap
```

Check in order: the Git revision and path resolve in the repository; the change is pushed; the GitHub App installation includes the repository; and the Pods fit on the node (`kubectl describe pod` shows `Insufficient memory`). Values interpolated from `{{ .metadata.annotations.* }}` come from the cluster `Secret` written by Terraform — if one is empty, add it to `modules/platform_cluster_bootstrap` rather than hardcoding it in YAML.

### Rolling back

There is no partial rollback for a half-applied cluster. Re-run the failing stage after fixing its input; Terraform is idempotent for every resource here. For full teardown use [destroy the platform](destroy-platform.md), which never touches `bootstrap/terraform-state`.
