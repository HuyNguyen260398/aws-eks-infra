# First end-to-end deployment: defects found and fixed

Record of every defect found while deploying this repository from scratch for the
first time — empty AWS account state through a healthy Jenkins workload — on
2026-07-25 in `ap-southeast-1`, account `010382427026`.

Ten code defects were fixed across eight pull requests. **Every one was
invisible to static review and CI.** `make terraform-check` and `make yaml-check`
passed on the unfixed code, and both CI workflows were green. Each defect
surfaced only when a real cluster tried to reconcile real manifests, and each one
blocked discovery of the next — they could only be found and fixed in sequence.

## Summary

| # | Defect | Phase | Symptom | PR |
|---|---|---|---|---|
| 1 | `for_each` over apply-time-unknown subnet IDs | Terraform | `terraform plan` failed outright | [#2](https://github.com/HuyNguyen260398/aws-eks-infra/pull/2) |
| 2 | `goTemplate` unset on 5 bootstrap ApplicationSets | Argo CD | literal `{{ .server }}` destination; no Application created | [#3](https://github.com/HuyNguyen260398/aws-eks-infra/pull/3) |
| 3 | `directory.recurse` on 2 Kustomize dirs | Argo CD | `kustomization.yaml` applied as a cluster resource | [#4](https://github.com/HuyNguyen260398/aws-eks-infra/pull/4) |
| 4 | `goTemplate` unset on 4 addon ApplicationSets | Argo CD | no addon Application created; nothing installed | [#5](https://github.com/HuyNguyen260398/aws-eks-infra/pull/5) |
| 5 | `argo-rollouts` missing `CreateNamespace=true` | Argo CD | `namespaces "argo-rollouts" not found` | [#6](https://github.com/HuyNguyen260398/aws-eks-infra/pull/6) |
| 6 | cert-manager webhook on the kubelet's port | Fargate | webhook served the node's certificate; otel operator never started | [#7](https://github.com/HuyNguyen260398/aws-eks-infra/pull/7) |
| 7 | argo-rollouts CRDs vs API-server normalization | Argo CD | 5 CRDs `OutOfSync` forever | [#7](https://github.com/HuyNguyen260398/aws-eks-infra/pull/7) |
| 8 | `goTemplate` unset on the `jenkins` ApplicationSet | Jenkins | Application never rendered; literal EFS volume handle | [#2](https://github.com/HuyNguyen260398/aws-eks-infra/pull/2) |
| 9 | `directory.recurse` on `config-workload-charts` | Jenkins | `jenkins` ApplicationSet never created | [#8](https://github.com/HuyNguyen260398/aws-eks-infra/pull/8) |
| 10 | `persistence` nested under `controller` | Jenkins | unbindable PVC; Pod unschedulable on Fargate | [#9](https://github.com/HuyNguyen260398/aws-eks-infra/pull/9) |

Three of these are the same root cause recurring (2, 4, 8), and two more are
another (3, 9). See [Recurring patterns](#recurring-patterns).

---

## 1. `for_each` over apply-time-unknown subnet IDs

**Phase** Terraform, Stage 4 · **PR** #2

`modules/platform_cluster/efs.tf` keyed EFS mount targets by subnet ID:

```hcl
for_each = toset(module.vpc.private_subnets)
```

Subnet IDs do not exist until the VPC applies, so `for_each` had no keys known at
plan time and the Stage 4 plan **failed before creating anything**:

```
Invalid for_each argument: the "for_each" set includes values derived from
resource attributes that cannot be determined until apply, and so Terraform
cannot determine the full set of keys that will identify the instances.
```

**Fix** — key by availability zone, which resolves from a data source at plan
time:

```hcl
for_each = {
  for index, az in local.availability_zones : az => module.vpc.private_subnets[index]
}
```

Addresses became `aws_efs_mount_target.apps["ap-southeast-1a"]`. One mount target
per AZ is also the correct EFS semantics, and addresses no longer churn when
subnet IDs change.

**Why CI missed it** `terraform validate` does not evaluate `for_each` against
real values, and the file had only ever been planned against a VPC that already
existed. It works with a populated state and fails on a clean deploy.

---

## 2, 4, 8. `spec.goTemplate` never set

**Phase** Argo CD and Jenkins · **PRs** #3, #5, #2

Every ApplicationSet in the repository used Go-template syntax — `{{ .name }}`,
`{{ .server }}`, `{{ .metadata.annotations.* }}` — but none set
`spec.goTemplate`. Argo CD therefore fell back to the legacy **fasttemplate**
engine, which only understands `{{name}}` / `{{server}}` (no leading dot) and
**cannot traverse nested fields such as annotations at all**.

The failure mode is unusually deceptive. The generator reported success:

```
ParametersGenerated=True  Successfully generated parameters for all Applications
```

…while every rendered Application carried a *literal* destination and failed
validation:

```
application destination spec is invalid: error getting cluster by server
"{{ .server }}": rpc error: code = NotFound desc = cluster "{{ .server }}" not found
```

No Application was ever created. The entire GitOps fan-out described in
`CLAUDE.md` was inert, and the cluster looked healthy because nothing had been
attempted.

Fixed in three waves as each layer became reachable:

| PR | Files |
|---|---|
| #3 | root ApplicationSet in `modules/platform_cluster_bootstrap/kubernetes.tf` + 4 children in `gitops/platform/bootstrap/` |
| #5 | 4 addon ApplicationSets in `gitops/platform/config/addons/` |
| #2 | `gitops/workloads/config/charts/jenkins.yaml` |

**Fix**

```yaml
spec:
  goTemplate: true
  goTemplateOptions:
    - missingkey=error
```

`missingkey=error` is deliberate: without it a missing annotation renders
`<no value>` into a `repoURL`, `path`, or EFS volume handle and fails somewhere
far away from the cause.

The third wave mattered most in the Jenkins case — `jenkins.yaml` interpolates
`efs_file_system_id` and `jenkins_efs_access_point_id`, so the PV would have been
created with the literal template string as its volume handle.

### Invariant

**Every ApplicationSet in this repository must set `goTemplate: true`.** Audit:

```bash
for f in $(grep -rl "kind: ApplicationSet" gitops --include='*.yaml'); do
  grep -q "goTemplate: true" "$f" || echo "MISSING: $f"
done
# plus the Terraform-managed root:
grep -q goTemplate modules/platform_cluster_bootstrap/kubernetes.tf || echo "MISSING: root"
```

---

## 3, 9. `directory.recurse` on Kustomize directories

**Phase** Argo CD and Jenkins · **PRs** #4, #8

`directory:` and `kustomization.yaml` are **mutually exclusive**. Setting
`directory.recurse: true` puts the source into plain-manifest mode, which
overrides Argo CD's automatic Kustomize detection. Argo CD then read
`kustomization.yaml` as a literal manifest and tried to apply it as a cluster
resource:

```
The Kubernetes API could not find kustomize.config.k8s.io/Kustomization for
requested resource argocd/. Make sure the "Kustomization" CRD is installed on
the destination cluster.
```

Affected Applications sat `OutOfSync` with `SyncError` after 5 retries.

The repository already contained the correct pattern, which is what identified
the fix: `config-observability` points at a Kustomize directory, omits the
`directory` block, and was the **only** Kustomize child that synced.

Current correct state for all five paths:

| Path | `kustomization.yaml` | `directory` block |
|---|---|---|
| `platform/config/addons` | yes | no |
| `platform/config/kro-definitions` | yes | no |
| `platform/config/observability` | yes | no |
| `workloads/config/charts` | yes | no |
| `workloads/manifests` | no | **retained** |

`workloads/manifests` legitimately keeps its block — it holds plain manifests.

`config-workload-charts.yaml` needed the same fix separately (#8) because it only
reached `main` with the Jenkins merge, after #4 had already landed.

---

## 5. `argo-rollouts` missing `CreateNamespace=true`

**Phase** Argo CD · **PR** #6

```
one or more objects failed to apply, reason: namespaces "argo-rollouts" not found,
error running rbacReconcile: error running kubectl auth reconcile:
error getting namespace argo-rollouts: namespaces "argo-rollouts" not found
```

A one-line inconsistency — it was the only addon targeting a dedicated namespace
without the option:

| Addon | Target namespace | `CreateNamespace=true` |
|---|---|---|
| `cert-manager` | `cert-manager` | yes |
| `opentelemetry-operator` | `opentelemetry-operator-system` | yes |
| `aws-load-balancer-controller` | `kube-system` (pre-existing) | n/a |
| `argo-rollouts` | `argo-rollouts` | **no** |

This also surfaced as a *second* symptom: `platform-kro-definitions` reported
`Degraded` because the `webapp` ResourceGraphDefinition needs the `Rollout` CRD
shipped by this chart:

```
failed to build resource "rollout": cannot resolve group version kind
"argoproj.io/v1alpha1, Kind=Rollout": schema not found
```

One root cause, two unrelated-looking symptoms.

---

## 6. cert-manager webhook collides with the kubelet on Fargate

**Phase** Fargate · **PR** #7 · *the most Fargate-specific defect found*

The OpenTelemetry operator Pod sat in `ContainerCreating` for **88 minutes**:

```
MountVolume.SetUp failed for volume "cert": secret
"opentelemetry-operator-controller-manager-service-cert" not found
```

The secret was missing because the operator's `Certificate` and `Issuer` never
applied, and that failed on cert-manager's webhook:

```
Internal error occurred: failed calling webhook "webhook.cert-manager.io":
tls: failed to verify certificate: x509: certificate is valid for
fargate-ip-10-0-4-117.ap-southeast-1.compute.internal,
not cert-manager-webhook.cert-manager.svc
```

**Root cause.** On Fargate every Pod gets its own node **and carries that node's
IP**:

```
cert-manager-webhook-...  10.0.4.117  fargate-ip-10-0-4-117.ap-southeast-1.compute.internal
```

The kubelet listens on `10250` on that node, and cert-manager's webhook defaults
to `--secure-port=10250`. The API server's call to `10.0.4.117:10250` therefore
reached **the kubelet**, which answered with its own node serving certificate —
hence the SAN mismatch.

**Fix** — move the webhook off the kubelet's port:

```yaml
webhook:
  securePort: 10260
```

Nothing else binds that port, and the Service targets the port by name, so no
Service change is needed.

**Generalisation.** On EKS Fargate, **no Pod may listen on 10250.** Any chart
defaulting to that port needs overriding. This is not specific to cert-manager.

---

## 7. argo-rollouts CRDs versus API-server normalization

**Phase** Argo CD · **PR** #7

Five CRDs reported `OutOfSync` permanently even though the sync succeeded and the
Application was `Healthy`. Diffing the rendered chart against the live objects
showed the only differences are fields the API server normalizes:

| Field | Chart | Live | Reason |
|---|---|---|---|
| `spec.preserveUnknownFields` | `false` | *absent* | removed in `apiextensions.k8s.io/v1`; API server strips it |
| `spec.conversion` | *absent* | `{strategy: None}` | API server defaults it |

The rendered manifest can therefore **never** equal the live object, so the
Application could never reach `Synced` — which blocks the
`Argo Applications Synced Healthy` assertion in `scripts/verify-platform.sh`.

**Fix** — ignore exactly those two paths, leaving real schema drift visible:

```yaml
ignoreDifferences:
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
    jsonPointers:
      - /spec/conversion
      - /spec/preserveUnknownFields
```

---

## 10. Jenkins `persistence` nested under `controller`

**Phase** Jenkins · **PR** #9

The Jenkins controller Pod could not be scheduled at all:

```
Pod not supported on Fargate: volumes not supported:
jenkins-home not supported because: PVC jenkins not bound
```

`persistence` is a **top-level** key in the `jenkins/jenkins` chart. There is no
`controller.persistence`:

```console
$ helm show values jenkins/jenkins --version 5.9.42
persistence at TOP level?      True
persistence under controller?  False
```

Nested under `controller:`, the whole block was **silently ignored** — Helm does
not warn about unknown values. The chart fell back to its defaults
(`existingClaim: null`, `storageClass: null`) and created its own PVC named
`jenkins`. With no default StorageClass in the cluster that PVC stayed `Pending`
forever, and **Fargate refuses to schedule a Pod whose PVC is unbound.**

Two PVCs existed, only one usable:

```
NAME           STATUS    VOLUME
jenkins        Pending                     <- chart's own, unbindable
jenkins-home   Bound     jenkins-home-pv   <- ours, on the EFS access point
```

The `jenkins-storage` chart had been correct the entire time. Nothing referenced
its PVC.

**Fix** — move `persistence` to the top level of the values block. Verified by
rendering before merging: 0 chart PVCs, no `volumeClaimTemplates`, and

```yaml
{name: jenkins-home, persistentVolumeClaim: {claimName: jenkins-home}}
```

`controller.ingress` *is* a real chart key and was already correct — only
`persistence` was misplaced.

### Follow-up: StatefulSet rolling-update deadlock

After the fix merged, the StatefulSet template updated but `jenkins-0` stayed
`Pending` — a rolling update will not replace a Pod that never became `Ready`.
The old Pod still referenced the now-deleted `jenkins` PVC.

Manual remediation (safe: the Pod had never run):

```bash
kubectl -n apps-jenkins delete pod jenkins-0
```

The StatefulSet recreated it with the correct claim and it reached `2/2 Running`.

---

## Recurring patterns

**A misplaced or ignored key fails silently.** Defects 2/4/8 (`goTemplate`) and
10 (`persistence`) share a shape: a configuration key that is absent or at the
wrong nesting level produces no error from the tool that consumes it. Helm
ignores unknown values; Argo CD's fasttemplate treats an unresolvable
`{{ .server }}` as a literal string. Both then fail much later, somewhere that
does not name the real cause.

**Fixing one layer reveals the next.** The GitOps chain is
`root → bootstrap children → addon ApplicationSets → Applications`. Because the
root never rendered, layers 2–4 were unreachable and untested. Each fix exposed
a fresh layer with its own defect. A repository-wide audit at the first sighting
of a class of bug — rather than fixing only the observed instance — would have
collapsed three PRs into one. This is why the audit command in
[the goTemplate invariant](#invariant) exists.

**A file absent from `main` escapes any audit run against `main`.** Defects 8 and
9 both existed on the feature branch while the corresponding fixes were being
merged to `main`, so the earlier audits could not see them. Audit the branch you
intend to deploy.

**Argo CD abandons a failed sync.** After 5 retries, automated sync stops and
will not resume when the underlying cause is fixed — `reconciledAt` keeps
advancing while `operationState.finishedAt` stays frozen. Merging the fix is not
enough; the Application needs an explicit nudge:

```bash
# refresh manifests from Git
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite

# force a new sync operation when the retry budget is exhausted
kubectl -n argocd patch application <app> --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
```

Propagate top-down: root → child → leaf. A child cannot see a fix its parent has
not synced yet.

---

## Tooling and runbook inaccuracies

These are not code defects in the platform, but they made the tooling unusable as
a gate. All but the last are now fixed; each entry records the original symptom
and what changed.

### `scripts/destroy-platform.sh` guard missed multi-source workloads — FIXED

The guard refused only when an Application had
`.spec.source.path == "gitops/workloads"`. Jenkins is a **multi-source**
Application, so `.spec.source` is null and its paths live in `.spec.sources[]`.
The guard reported **0 workloads** with Jenkins fully live, and would have let the
destroy run straight into an orphaned ALB blocking the VPC destroy.

It now checks `.spec.source.path` *and* every `.spec.sources[].path`, matches on
the `gitops/workloads` prefix rather than an exact string, and additionally
refuses while any Ingress or LoadBalancer Service exists — those are backed by
load balancers Terraform has no record of. The guards are skipped only when the
cluster is absent from state, and a cluster in state that `kubectl` cannot reach
is now a refusal rather than a silent pass.

### `scripts/destroy-platform.sh` destroyed more than the cluster — FIXED

Its final step was an untargeted `plan -destroy`, which also removed the
CodeConnections connection and the Identity Center group, forcing a manual GitHub
App reauthorization on the next deploy.

It now destroys `module.platform_cluster_bootstrap` and `module.platform_cluster`
by target and preserves those account-level resources. `DESTROY_ROOT=true` opts
into the full root destroy. It also forces
`-var jenkins_dns_record_enabled=false`, because the Route 53 alias reads the ALB
through a data source that fails the plan once the load balancer is gone.

### `scripts/check-drift.sh` reported a false failure — FIXED

It prints `FAIL drift in bootstrap/terraform-state` while Terraform reports the
opposite:

```
No changes. Your infrastructure still matches the configuration.
Terraform has checked that the real remote objects still match the result of
your most recent changes, and found no differences.
```

`plan -refresh-only -detailed-exitcode` returns **2 on a completely empty plan**
— no resource diffs, no output changes, no "Objects have changed" note — and the
script gates on `[ "$code" = 0 ]`. Reproducible on **both** roots, including
`bootstrap/terraform-state`, which this deployment never modified.

It no longer gates on the exit code. It inspects the JSON plan for
`resource_drift` (changed outside Terraform) and `resource_changes` with actions
other than `no-op`/`read` (state diverged from configuration), prints the
offending addresses, and checks both roots so one drifting root cannot mask the
other.

### `scripts/verify-platform.sh` was a pre-workload-only gate — FIXED

Two assertions encoded the platform's pre-workload non-goals and began failing
**by design** as soon as Jenkins ran:

- `No service workloads` — asserts zero Pods in `apps-*` namespaces
- `No Ingress` — Jenkins creates an ALB Ingress

(`No LoadBalancer Service` kept passing: the controller Service is `ClusterIP`
behind an ALB Ingress.)

Assertions are now split. Platform invariants always run; the non-goals run only
when `EXPECT_WORKLOADS=false`, the default. With `EXPECT_WORKLOADS=true` they are
replaced by positive checks — Pods confined to `apps-*` or platform namespaces,
`apps-*` Pods `Running`, every Ingress carrying a load balancer address. Two
weaknesses found while splitting it were also fixed: the Application health check
passed vacuously against an empty `argocd` namespace (`all` on an empty array is
true), and `list-nodegroups` alone cannot detect self-managed EC2 capacity, so
every node is now asserted to be `eks.amazonaws.com/compute-type=fargate`.

### `docs/operations/deploy-platform.md`: the CoreDNS restart was not required — STILL OPEN

The runbook states the manual CoreDNS restart "is required on every new cluster,
and the apply blocks until you do it." On this deployment it was **not** needed —
the add-on was created after the Fargate profiles existed, so the Pods scheduled
on the first attempt and the add-on reached `ACTIVE` in 55 seconds without
intervention. The runbook should present it as conditional recovery, not a
mandatory step.

---

## Final verified state

```
Applications   11/11 Synced/Healthy
Nodes          11/11 fargate
Node groups    0
Capabilities   argocd / ack / kro  all ACTIVE
Jenkins        jenkins-0 2/2 Running, JENKINS_HOME on EFS (writable)
PVC            jenkins-home Bound -> jenkins-home-pv
Terraform      "No changes. Your infrastructure matches the configuration."
```

Gates:

```bash
make terraform-check   # exit 0 — checkov 236 passed, 0 failed, 16 skipped
make yaml-check        # exit 0
```
