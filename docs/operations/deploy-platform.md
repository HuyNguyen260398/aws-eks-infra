# Deploy the platform

Start-from-scratch procedure for the Fargate-only `platform` environment. Follow the stages in order; each stage has a gate that must pass before the next one begins.

Read [why the apply is staged](#why-the-apply-is-staged) before your first deployment. A single `terraform apply` of `environments/platform` cannot succeed.

## Conventions

Every command runs from the repository root. Export the environment once per shell:

```bash
export AWS_PROFILE=default
export AWS_REGION=ap-southeast-1
```

`terraform.tfvars`, `backend.hcl`, and `tfplan` are ignored by Git and never committed.

## Why the apply is staged

`modules/platform_cluster_bootstrap` writes Argo CD objects with the `kubernetes` provider, whose `host` comes from `module.platform_cluster.cluster_endpoint`. Two things follow:

- Before the cluster exists, the provider has no reachable endpoint, so `kubernetes_manifest.bootstrap` fails at **plan** time with `Failed to construct REST client: no client config`.
- `kubernetes_manifest` also validates its resource against the live API server during plan, so the Argo CD `ApplicationSet` CRD must already be installed. That CRD arrives with the Argo CD capability, which itself is created by `module.platform_cluster`.

So `module.platform_cluster` must be applied and its Argo CD capability must reach `ACTIVE` before the root can be planned as a whole. Stage 4 uses `-target` for exactly this reason, which is the narrow, Terraform-sanctioned use of targeting. Stage 6 then applies the untargeted root and must report no changes to `module.platform_cluster`.

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

Only for a brand-new account. If `aws s3 ls | grep tfstate` already lists `<prefix>-<account>-<region>-tfstate`, skip to Stage 3.

Follow [Terraform state](terraform-state.md): apply `bootstrap/terraform-state` with local state, then re-run `init -migrate-state` against the bucket it just created.

Gate:

```bash
terraform -chdir=bootstrap/terraform-state plan -detailed-exitcode
```

Exit code `0` means the state foundation is applied and drift-free. The bucket and KMS key carry `prevent_destroy`.

## Stage 3 — Platform root and GitHub authorization

Create `environments/platform/backend.hcl` and `environments/platform/terraform.tfvars` from their `.example` files. `public_access_cidrs` must be your egress address as a `/32`; `0.0.0.0/0` is rejected by variable validation.

```bash
terraform -chdir=environments/platform init -backend-config=backend.hcl
```

Apply only the Identity Center group and the CodeConnections connection first, because the connection must be authorized by a human in the AWS Console before Argo CD can read the repository:

```bash
terraform -chdir=environments/platform apply \
  -target=aws_identitystore_group.argocd_admins \
  -target=aws_identitystore_group_membership.argocd_admins \
  -target=aws_codeconnections_connection.github
```

A new connection is created in `PENDING`. Complete the handshake in **AWS Developer Tools → Settings → Connections**, restricting the GitHub App installation to the single GitOps repository. See [GitHub CodeConnections](github-connection.md).

Gate:

```bash
aws codeconnections get-connection \
  --connection-arn "$(terraform -chdir=environments/platform output -raw github_connection_arn)" \
  --query 'Connection.ConnectionStatus' --output text
```

Expected: `AVAILABLE`. Do not continue while this reads `PENDING` — the capability will be created with a connection it cannot use.

## Stage 4 — Cluster, observability, and capabilities

```bash
terraform -chdir=environments/platform plan -target=module.platform_cluster -out=tfplan
terraform -chdir=environments/platform apply tfplan
```

Review the saved plan before applying. On a first deployment it creates roughly 80 resources: one VPC with six subnets across three AZs and one NAT gateway, the EKS cluster, three Fargate profiles, two KMS keys, four CloudWatch log groups, VPC Flow Logs, the CoreDNS add-on, IRSA roles, and the three EKS capabilities. Terraform prints a `Resource targeting is in effect` warning; that is expected here.

Expect 20–30 minutes, most of it the EKS control plane and the capabilities.

### CoreDNS may need one manual restart

**Conditional — check before acting.** This is recovery for one specific stall, not a step every deployment performs. On a clean deployment of this repository the add-on reached `ACTIVE` in 55 seconds with no intervention, because Terraform created it after the Fargate profiles already existed and the Pods scheduled on the first attempt.

The stall happens when the CoreDNS Deployment exists *before* any Fargate profile does. Those first Pods match no profile, so they stay `Pending` forever with **no scheduling events**, and Fargate never re-evaluates an already-pending Pod. The add-on then reports `DEGRADED` and `aws_eks_addon` blocks waiting for `ACTIVE`.

While the apply is still running, check whether you are in that state:

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
```

- Pods `Running` on `fargate-ip-*` nodes, or no Pods yet — nothing to do; let the apply continue.
- Pods `Pending` with no events in `kubectl describe` — apply the restart below.

Once the `system` Fargate profile is `ACTIVE`, in a second shell run:

```bash
aws eks update-kubeconfig --name "$cluster" --region "$AWS_REGION"
kubectl -n kube-system rollout restart deployment coredns
kubectl -n kube-system rollout status deployment/coredns --timeout=5m
```

Expected: two new Pods `1/1 Running` on `fargate-ip-*` nodes, and the add-on reaching `ACTIVE` within a couple of minutes — add-on health lags the Pods, so `DEGRADED` immediately after a successful rollout is normal.

The add-on's create timeout is set to 40m in `modules/platform_cluster/eks.tf` to leave room for this. If the apply still times out, the add-on usually goes `ACTIVE` shortly after; verify with `aws eks describe-addon`, clear the failed-create marker, and re-plan to confirm convergence rather than replacing healthy DNS:

```bash
terraform -chdir=environments/platform untaint 'module.platform_cluster.module.eks.aws_eks_addon.this["coredns"]'
terraform -chdir=environments/platform plan -target=module.platform_cluster -detailed-exitcode   # expect 0
```

Gate — no EC2 compute anywhere:

```bash
cluster="$(terraform -chdir=environments/platform output -raw cluster_name)"
aws eks list-nodegroups --cluster-name "$cluster" --query 'length(nodegroups)' --output text   # expect 0
aws eks list-fargate-profiles --cluster-name "$cluster" --output text                          # expect 3
```

## Stage 5 — Capability readiness

Poll all three capabilities to `ACTIVE` using the loop in [managed EKS capabilities](capabilities.md#verify-readiness). `DEGRADED`, `CREATE_FAILED`, `UPDATE_FAILED`, and `DELETING` are terminal.

Configure `kubectl` (see [cluster access](cluster-access.md)):

```bash
aws eks update-kubeconfig --name "$cluster" --region "$AWS_REGION"
```

Gate — the CRDs that Stage 6 plans against must exist:

```bash
kubectl api-resources | grep -E 'applications|applicationsets|resourcegraphdefinitions|iamroleselectors'
```

Expected: `applications` and `applicationsets` (`argoproj.io`), `resourcegraphdefinitions` (`kro.run`), `iamroleselectors` (`services.k8s.aws`). If `applicationsets` is missing, Stage 6 will fail at plan time.

## Stage 6 — GitOps bootstrap

The GitOps branch must be pushed to GitHub first — Argo CD reads `main` from the repository, not your working tree.

Now plan the **untargeted** root:

```bash
terraform -chdir=environments/platform plan -out=tfplan
terraform -chdir=environments/platform apply tfplan
```

Gate: the plan adds only `module.platform_cluster_bootstrap` resources (the Argo CD cluster `Secret` and the `platform-bootstrap` ApplicationSet) and shows **no changes** to `module.platform_cluster`. Changes to already-applied cluster resources here mean Stage 4 was applied from different inputs; stop and reconcile before applying.

## Stage 7 — GitOps sync

The root ApplicationSet discovers `gitops/platform/bootstrap/`, which fans out to the `config-addons`, `config-observability`, `config-kro-definitions`, and `config-workloads` children.

```bash
kubectl -n argocd get applicationsets
kubectl -n argocd get applications -o wide
```

Expected: the root plus four child ApplicationSets, and every Application eventually `Synced` / `Healthy`. `config-workloads` targets an intentionally empty directory and stays healthy through `allowEmpty`.

Controllers land on Fargate only when their namespace matches a profile selector:

```bash
kubectl get nodes -L eks.amazonaws.com/compute-type
kubectl get pods -A -o wide
```

Expected: every node reports `fargate`, and Pods run in `kube-system`, `argo-rollouts`, `opentelemetry-operator-system`, and `amazon-cloudwatch`.

## Stage 8 — Acceptance

```bash
./scripts/verify-platform.sh
./scripts/check-drift.sh
```

Gate: `verify-platform.sh` prints `PASS` on every assertion and exits `0`; `check-drift.sh` reports detailed exit code `0` for both stateful roots. See [validate the platform](validate-platform.md).

Confirm the plan's non-goals still hold: no Ingress, no LoadBalancer Service, no `apps-*` workload, and no EC2 node group.

## Recovery

### Connection stuck in `PENDING`

Authorization is a human step and cannot be automated. Re-open the connection in the console and complete the GitHub App install. If the app was installed against the wrong account, delete the connection in the console and re-apply the `aws_codeconnections_connection.github` target.

### Capability `CREATE_FAILED` or `DEGRADED`

```bash
aws eks describe-capability --cluster-name "$cluster" --capability-name "${cluster}-argocd"
aws iam get-role --role-name "${cluster}-argocd-capability"
```

Most failures are IAM propagation or trust policy. Confirm the role trusts only `capabilities.eks.amazonaws.com` for `sts:AssumeRole` and `sts:TagSession`, and that the Argo CD role's inline policy scopes `codeconnections:UseConnection` to the Terraform-managed connection ARN. Capabilities use `delete_propagation_policy = "RETAIN"`, so removing one from configuration leaves it running in AWS — delete it deliberately in the console, never by dropping the resource block.

### `Failed to construct REST client` during plan

The cluster is unreachable or absent. You are running Stage 6 before Stage 4 completed, or your kubeconfig/credentials expired. Re-run the Stage 5 gate, then retry.

### `Invalid count argument` during plan

A data source inside a child module resolved to unknown. This is what a module-level `depends_on` causes: it defers every data source in that module to apply time. Do not add `depends_on` to `module.eks`; express ordering through real value references instead.

### Fargate Pod stuck `Pending`

```bash
kubectl -n <namespace> describe pod <pod>
aws eks describe-fargate-profile --cluster-name "$cluster" --fargate-profile-name "${cluster}-platform-addons"
```

A Pod in a namespace that no Fargate profile selects gets no capacity and stays `Pending` forever with no scheduling event. Adding a platform component means adding its namespace to a profile selector in `modules/platform_cluster/eks.tf` **and** to the GitOps config in the same change. Changing selectors replaces the Fargate profile, which is a slow operation.

### Application not `Synced` / `Healthy`

```bash
kubectl -n argocd get application <name> -o jsonpath='{.status.conditions}'
kubectl -n argocd describe applicationset platform-bootstrap
```

Check in order: the Git revision and path resolve in the repository; the change is pushed to `main`; the Argo CD capability role can still reach the connection; and the target namespace matches a Fargate selector. Values interpolated from `{{ .metadata.annotations.* }}` come from the cluster `Secret` written by Terraform — if one is empty, add it to `modules/platform_cluster_bootstrap` rather than hardcoding it in YAML.

### Rolling back

There is no partial rollback for a half-applied cluster. Re-run the failing stage after fixing its input; Terraform is idempotent for every resource here. For full teardown use [destroy the platform](destroy-platform.md), which never touches `bootstrap/terraform-state`.
