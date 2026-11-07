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

- CodeConnections `AVAILABLE`, EKS and all Fargate profiles `ACTIVE`
- `aws eks list-nodegroups` empty, **and** every node labelled
  `eks.amazonaws.com/compute-type=fargate`. The node-group check alone does not
  catch self-managed EC2 capacity
- Argo CD, ACK, and kro capabilities `ACTIVE`
- CoreDNS, AWS Load Balancer Controller, Argo Rollouts, cert-manager, and the
  OpenTelemetry operator available
- at least one Argo CD Application exists, and every one is `Synced` and
  `Healthy`. Failing Applications are named with their status

**Workload assertions — depend on `EXPECT_WORKLOADS`:**

| `EXPECT_WORKLOADS` | Asserts |
|---|---|
| `false` (default) | the greenfield non-goals: no `apps-*` Pod, no Ingress, no LoadBalancer Service |
| `true` | Pods live only in `apps-*` or platform namespaces, `apps-*` Pods are `Running`/`Succeeded`, and every Ingress has a load balancer address |

The non-goals are only meaningful before anything is hosted. They used to be
unconditional, so the script reported `FAIL` the moment a workload it was
designed to host actually ran. **Set `EXPECT_WORKLOADS=true` after deploying a
workload**, or the run reports failures by design rather than by fault.

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

| Resource type | Attribute | Why |
|---|---|---|
| `aws_efs_file_system` | `size_in_bytes` | Metered capacity. Jenkins writing to `/jenkins-home` moves it on every refresh, and it is not settable in configuration. |

A drift entry is suppressed only when **every** differing attribute is on its
type's list. Real drift alongside a counter still fails — an EFS filesystem that
both grew and had encryption disabled reports `[encrypted]`. Keep the lists
minimal and justify each entry; anything settable in configuration belongs in a
`lifecycle` block, not here.

Failures map to the recovery procedures in [deploy the platform](deploy-platform.md#recovery).
