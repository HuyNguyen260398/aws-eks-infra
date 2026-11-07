# Validate the platform

Static gates run with no AWS credentials. Live gates require credentials and a current kubeconfig.

## Static gates

```bash
make terraform-check   # fmt -check + validate every root + tflint + checkov
make yaml-check        # yamllint + helm lint/template + kubeconform + kustomize build
make shell-check       # shellcheck on scripts/*.sh
```

All three must exit `0`. `shell-check` runs shellcheck at its **default**
severity, so style and info findings fail too — the operational scripts are small
enough to keep at zero findings, and the four defects recorded in
[first deployment defects](first-deployment-defects.md) all lived in scripts that
no CI job ever looked at. CI runs the same checks with pinned tool versions and never receives AWS credentials.

A Terraform root is only validated if it contains `versions.tf` — the Makefile and the workflow both skip roots without it. A new root must be added to `TF_ROOTS` in the `Makefile` **and** the `roots=(...)` array in `.github/workflows/terraform-ci.yaml`, or CI silently stops validating it.

## Live gates

```bash
./scripts/verify-prerequisites.sh   # tooling and AWS account preflight; mutates nothing
./scripts/verify-platform.sh        # acceptance, greenfield by default
EXPECT_WORKLOADS=true ./scripts/verify-platform.sh   # once the platform hosts workloads
./scripts/check-drift.sh            # drift on both stateful roots
```

### `verify-platform.sh`

Prints one `PASS`/`FAIL` line per assertion and exits nonzero if any fail.

**Platform invariants — always checked:**

- CodeConnections `AVAILABLE`, EKS `ACTIVE`, no Fargate profiles
- Node group `<cluster>-general` `ACTIVE`, `EXPECTED_NODES` (default 1) Ready
  arm64 nodes, all from that node group, each allowing 110 Pods
- Add-ons `vpc-cni`, `kube-proxy`, `eks-pod-identity-agent`, `coredns`
  `ACTIVE`; the VPC CNI with `enableNetworkPolicy` and prefix delegation on;
  CoreDNS rolled out
- The four SSM parameters under `PARAMETER_PREFIX` exist, and `cluster-name`
  matches the cluster

With `enable_argocd = false` the script stops here and prints
`SKIP GitOps and workload checks`.

**GitOps — only with `enable_argocd = true`:**

- The Argo CD capability `ACTIVE`
- AWS Load Balancer Controller, Argo Rollouts, cert-manager (controller and
  webhook) and KEDA (operator, metrics API server, admission webhooks) rolled
  out; KEDA's external metrics APIService `Available`
- At least one Argo CD Application exists, and every one is `Synced` and
  `Healthy`. Failing Applications are named with their status
- Each `WORKLOAD_NAMESPACES` namespace (default `cashight`) enforces Pod
  Security `restricted` and has the three default NetworkPolicies and a quota

**Workload assertions — with GitOps on, depending on `EXPECT_WORKLOADS`:**

| `EXPECT_WORKLOADS` | Asserts |
|---|---|
| `false` (default) | the greenfield non-goals: no workload Pod (in `apps-*` or a tenant namespace), no Ingress, no LoadBalancer Service |
| `true` | Pods live only in platform, `apps-*` or tenant namespaces, workload Pods are `Running`/`Succeeded`, and every Ingress has a load balancer address |

**Set `EXPECT_WORKLOADS=true` after deploying Cashight**, or the run reports
failures by design rather than by fault.

### `check-drift.sh`

Reports `PASS`/`FAIL` per root and always checks both, so one drifting root does
not mask the other.

It does **not** gate on the plan's exit code. `plan -refresh-only
-detailed-exitcode` returns `2` whenever the refresh would write anything back to
state — including on a completely empty plan with no resource diffs, no output
changes and no "Objects have changed" note — so the exit code is not a drift
signal. The script inspects the JSON plan instead:

| Field | Meaning |
|---|---|
| `resource_drift` | the real object changed outside Terraform |
| `resource_changes` with actions other than `no-op`/`read` | state no longer matches configuration |

Drifting addresses are printed with the attributes that actually differ.
Inspect the refresh plan before reconciling, since capabilities use `RETAIN` and
are not recreated by a plain apply.

### Ignored read-only counters

Some attributes are read-only values AWS updates as the workload runs. They
would appear in `resource_drift` on every refresh forever, making this gate
permanently red and therefore ignored. `IGNORED_DRIFT_ATTRS` at the top of the
script lists them per resource type:

The list is empty today. A drift entry is suppressed only when **every**
differing attribute is on its type's list, so real drift alongside a counter
still fails. Keep the lists
minimal and justify each entry; anything settable in configuration belongs in a
`lifecycle` block, not here.

Failures map to the recovery procedures in [deploy the platform](deploy-platform.md#recovery).
