# Generic Public Workload Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make any workload in the EKS cluster reachable from the internet by joining a single shared internet-facing ALB, with no DNS layer and no Terraform involvement.

**Architecture:** The aws-load-balancer-controller assembles one ALB named `aws-eks-infra-public` from an *IngressGroup* called `platform-public`. Each workload opts in by adding a fixed annotation block to its Ingress and serving under its own path prefix; requests reach `http://<alb-dns-name>/<prefix>`. The Jenkins-specific ACM certificate and Route 53 records are deleted outright, making exposure a pure-GitOps change.

**Tech Stack:** Terraform (AWS provider, `terraform-aws-modules/eks`, `terraform-aws-modules/vpc`), Argo CD ApplicationSets, Helm (upstream `jenkins/jenkins` 5.9.42), aws-load-balancer-controller 1.14.0, EKS on Fargate.

**Design spec:** `docs/superpowers/specs/2026-07-26-public-workload-access-design.md`

## Global Constraints

- **The ALB is HTTP only, on port 80, open to `0.0.0.0/0`.** No `inbound-cidrs` annotation, no ACM, no TLS. This is a deliberate trade-off recorded in the spec.
- **No DNS.** Route 53, CloudFront, ACM and external-dns are all out of scope. The only hostname is the AWS-assigned `*.elb.amazonaws.com` name.
- **Group-level annotations must be byte-identical on every member** of the `platform-public` group or the controller refuses to reconcile: `group.name`, `scheme`, `load-balancer-name`, `listen-ports`.
- **The shared ALB name is `aws-eks-infra-public`** and the group name is `platform-public`. Both are fixed strings living in YAML — permitted because neither is account-, region- or ARN-specific.
- **`target-type: ip` is mandatory** on every Ingress. It is the only target type EKS Fargate supports.
- **Terraform must not gain any new variable, output or cluster `Secret` annotation.** This task set only deletes from the Terraform side.
- **Ownership boundary holds:** Argo CD owns the Ingress; the controller owns the ALB; Terraform owns neither.
- **Conventional Commits, one per task.** Put the exact validation commands in the PR description.
- The platform is currently destroyed — `aws eks list-clusters` returns `[]` — so no task requires a live cluster and no state surgery is needed.

---

### Task 1: Move Jenkins onto the shared `platform-public` ALB

This is the task that delivers the capability. It changes only GitOps. It comes
first deliberately: after it, the Jenkins ApplicationSet no longer references the
`jenkins_certificate_arn`, `jenkins_public_hostname` or `jenkins_alb_name`
cluster-`Secret` annotations, so Task 2 can delete those annotations without ever
leaving the repository in a state where YAML references an annotation that
Terraform no longer supplies. (The ApplicationSet sets
`goTemplateOptions: [missingkey=error]`, so a missing annotation is a hard
failure, not a blank.)

**Files:**
- Modify: `gitops/workloads/config/charts/jenkins.yaml:31-66` (the `helm.values` block of the first source)
- Test: `/private/tmp/claude-501/-Users-huyng-ws-aws-eks-infra/5377ece7-a090-4bcf-84dd-af817b73b523/scratchpad/check-public-ingress.sh` (scratchpad only — do **not** commit it)

**Interfaces:**
- Consumes: the cluster `Secret` annotations `gitops_repo_url`, `gitops_revision`, `efs_file_system_id`, `jenkins_efs_access_point_id`. These all survive Task 2 and must keep working.
- Produces: an Ingress in `apps-jenkins` named `jenkins`, member of IngressGroup `platform-public`, serving `/jenkins` with no `host:`. Task 3's runbook documents this exact annotation block as the contract every future workload copies.

- [ ] **Step 1: Write the failing verification script**

The upstream Jenkins chart is rendered by Argo CD from a `helm.values` string
embedded in an ApplicationSet, so `make yaml-check` never renders it — it only
lints the YAML around it. This script extracts that block and asserts the six
properties the contract depends on.

Write to `/private/tmp/claude-501/-Users-huyng-ws-aws-eks-infra/5377ece7-a090-4bcf-84dd-af817b73b523/scratchpad/check-public-ingress.sh`:

```bash
#!/usr/bin/env bash
# Renders the Jenkins values embedded in the ApplicationSet and asserts the
# platform-public IngressGroup contract. Scratchpad only; not part of CI.
set -euo pipefail

repo="/Users/huyng/ws/aws-eks-infra"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'PASS %s\n' "$label"
  else
    printf 'FAIL %s (want %q, got %q)\n' "$label" "$expected" "$actual"
    fail=1
  fi
}

# Helm does not template values files, so any Argo CD Go-template placeholders
# still present in the block pass through as literal strings - which is exactly
# what makes the "before" run fail legibly.
yq '.spec.template.spec.sources[0].helm.values' \
  "$repo/gitops/workloads/config/charts/jenkins.yaml" > "$work/values.yaml"

helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
helm repo update jenkins >/dev/null 2>&1
helm template jenkins jenkins/jenkins --version 5.9.42 -f "$work/values.yaml" \
  > "$work/rendered.yaml"

ing="$(yq 'select(.kind == "Ingress")' "$work/rendered.yaml")"

check "no host on the rule" \
  "null" "$(printf '%s' "$ing" | yq '.spec.rules[0].host')"
check "path is /jenkins" \
  "/jenkins" "$(printf '%s' "$ing" | yq '.spec.rules[0].http.paths[0].path')"
check "joins the platform-public group" \
  "platform-public" "$(printf '%s' "$ing" | yq '.metadata.annotations."alb.ingress.kubernetes.io/group.name"')"
check "load balancer name pinned" \
  "aws-eks-infra-public" "$(printf '%s' "$ing" | yq '.metadata.annotations."alb.ingress.kubernetes.io/load-balancer-name"')"
check "HTTP only" \
  '[{"HTTP": 80}]' "$(printf '%s' "$ing" | yq '.metadata.annotations."alb.ingress.kubernetes.io/listen-ports"')"
check "target-type ip for Fargate" \
  "ip" "$(printf '%s' "$ing" | yq '.metadata.annotations."alb.ingress.kubernetes.io/target-type"')"

for gone in certificate-arn ssl-policy ssl-redirect; do
  check "no $gone annotation" \
    "null" "$(printf '%s' "$ing" | yq ".metadata.annotations.\"alb.ingress.kubernetes.io/$gone\"")"
done

# The probes must follow the URI prefix or the Pod never becomes Ready.
check "probe path follows the prefix" \
  "/jenkins/login" \
  "$(yq 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].readinessProbe.httpGet.path' "$work/rendered.yaml")"

exit "$fail"
```

Make it executable:

```bash
chmod +x /private/tmp/claude-501/-Users-huyng-ws-aws-eks-infra/5377ece7-a090-4bcf-84dd-af817b73b523/scratchpad/check-public-ingress.sh
```

- [ ] **Step 2: Run it to confirm it fails against the current config**

Run: `/private/tmp/claude-501/-Users-huyng-ws-aws-eks-infra/5377ece7-a090-4bcf-84dd-af817b73b523/scratchpad/check-public-ingress.sh`

Expected: exit 1, with `helm template` aborting before any PASS/FAIL line:

```
Error: template: jenkins/templates/jenkins-controller-ingress.yaml:20:3: executing
"jenkins/templates/jenkins-controller-ingress.yaml" at <tpl (toYaml
.Values.controller.ingress.annotations) .>: error calling tpl: ...
executing "gotpl" at <.metadata.annotations.jenkins_certificate_arn>:
nil pointer evaluating interface {}.annotations
```

That error *is* the failing test, and it is worth understanding before you fix
it. The Jenkins chart runs `tpl` over `controller.ingress.annotations`, so the
Argo CD placeholders currently sitting in them (`{{ .metadata.annotations.jenkins_certificate_arn }}`
and friends) get evaluated by **Helm**, which has no such context, and it dies.
This only works in the real pipeline because Argo CD's ApplicationSet substitutes
those placeholders into the values string *before* Helm ever sees it.

The consequence for this task: after Step 3 the ingress annotations contain no
`{{ }}` at all, `tpl` becomes a no-op, and the chart renders standalone. That is
the point at which the script can actually assert anything.

If the script instead fails with `command not found`, install the missing tool —
it needs `helm` and the Go `yq` (`brew install yq`).

- [ ] **Step 3: Rewrite the Jenkins values block**

In `gitops/workloads/config/charts/jenkins.yaml`, replace the `controller:` block
(from `controller:` on line 32 through the `ssl-redirect` annotation on line 66)
with exactly this. Indentation is 14 spaces for `controller:` — it sits inside a
`values: |` literal block. Everything from `persistence:` onward is unchanged.

```yaml
              controller:
                serviceType: ClusterIP
                jenkinsUrlProtocol: http
                # Serve the war under /jenkins so one shared ALB can host many
                # workloads by path. Jenkins generates prefixed links and the
                # chart prefixes its own probes, so the ALB needs no rewrite.
                jenkinsUriPrefix: /jenkins
                # controller.jenkinsUrl is deliberately unset: the ALB hostname
                # is assigned by AWS and is not knowable at render time. JCasC
                # falls back to http://jenkins:8080/jenkins, which is the
                # correct URL for the agent JNLP handshake because agents run
                # in-cluster. The cost is a cosmetic "Jenkins URL is not set"
                # admin monitor.
                resources:
                  requests:
                    cpu: "1000m"
                    memory: "2Gi"
                  limits:
                    cpu: "2000m"
                    memory: "4Gi"
                podSecurityContextOverride:
                  runAsUser: 1000
                  runAsGroup: 1000
                  fsGroup: 1000
                  runAsNonRoot: true
                ingress:
                  enabled: true
                  ingressClassName: alb
                  # No hostName: a host-less rule matches any Host header, so
                  # the ALB answers on its own AWS-assigned DNS name.
                  path: /jenkins
                  annotations:
                    # --- Group-level. Every member of platform-public must
                    # carry these four byte-identical or the controller refuses
                    # to reconcile the group. See
                    # docs/operations/public-workload-access.md.
                    alb.ingress.kubernetes.io/group.name: platform-public
                    alb.ingress.kubernetes.io/scheme: internet-facing
                    alb.ingress.kubernetes.io/load-balancer-name: aws-eks-infra-public
                    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
                    # --- Per workload.
                    # target-type ip is the only mode EKS Fargate supports.
                    alb.ingress.kubernetes.io/target-type: ip
                    alb.ingress.kubernetes.io/group.order: '10'
                    alb.ingress.kubernetes.io/healthcheck-path: /jenkins/login
```

Note what disappears: `jenkinsUrl`, `hostName`, `certificate-arn`, `ssl-policy`,
`ssl-redirect`, and the `HTTPS: 443` listener. The comment about
`internet-facing` requiring `kubernetes.io/role/elb=1` is dropped only because it
is restated in the runbook in Task 3; `vpc.tf` still sets the tag.

- [ ] **Step 4: Run the verification script and the YAML gate**

Run:

```bash
/private/tmp/claude-501/-Users-huyng-ws-aws-eks-infra/5377ece7-a090-4bcf-84dd-af817b73b523/scratchpad/check-public-ingress.sh
make yaml-check
```

Expected: every line of the first command prints `PASS` and it exits 0;
`make yaml-check` exits 0.

- [ ] **Step 5: Commit**

```bash
git add gitops/workloads/config/charts/jenkins.yaml
git commit -m "feat: move Jenkins onto the shared platform-public ALB

Join the platform-public IngressGroup on a host-less /jenkins path served
over HTTP, replacing the host-pinned HTTPS Ingress. jenkinsUriPrefix makes
Jenkins generate prefixed links so the ALB needs no path rewrite.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Delete the ACM and Route 53 layer from Terraform

Pure deletion. Nothing here adds a resource. The whole two-phase-apply mechanism
and its `jenkins_dns_record_enabled` escape hatch go away, which is also why the
destroy script's forced `-var` must go in the same commit: once the variable is
undeclared, passing `-var jenkins_dns_record_enabled=false` fails the plan with
`Value for undeclared variable`.

**Files:**
- Delete: `modules/platform_cluster/jenkins_public.tf`
- Modify: `modules/platform_cluster/variables.tf:66-93`
- Modify: `modules/platform_cluster/outputs.tf:103-111`
- Modify: `modules/platform_cluster_bootstrap/variables.tf:66-82`
- Modify: `modules/platform_cluster_bootstrap/kubernetes.tf:23-25`
- Modify: `environments/platform/variables.tf:102-118`
- Modify: `environments/platform/main.tf:77-79,99-100`
- Modify: `environments/platform/outputs.tf:71-79`
- Modify: `environments/platform/terraform.tfvars.example:11-15`
- Modify: `environments/platform/terraform.tfvars` (untracked, local only)
- Modify: `scripts/destroy-platform.sh:86-90,95,99,103`

**Interfaces:**
- Consumes: nothing from Task 1 at the Terraform level. Task 1 already stopped referencing the annotations this task removes.
- Produces: a `platform_cluster` module with no `jenkins_*` public-access inputs or outputs, and a cluster `Secret` carrying exactly ten annotations: `gitops_repo_url`, `gitops_platform_path`, `gitops_revision`, `vpc_id`, `aws_region`, `aws_load_balancer_controller_role_arn`, `adot_role_arn`, `fargate_log_group_name`, `efs_file_system_id`, `jenkins_efs_access_point_id`.

- [ ] **Step 1: Verify the current tree still validates, so a later failure is attributable**

Run: `make terraform-check`
Expected: exit 0. If it already fails, stop and fix that first — you cannot tell
your deletions apart from a pre-existing break otherwise.

- [ ] **Step 2: Delete the public-access Terraform file**

```bash
git rm modules/platform_cluster/jenkins_public.tf
```

This removes the hosted-zone data source, the ACM certificate, the DNS validation
record, `aws_acm_certificate_validation`, the `data "aws_lb"` lookup, the alias
record, and the `jenkins_public_access_inputs` check block.

- [ ] **Step 3: Remove the module's variables and outputs**

In `modules/platform_cluster/variables.tf`, delete all four blocks from
`variable "jenkins_public_hostname"` through the end of
`variable "jenkins_dns_record_enabled"` (lines 66-93). The file should end after
`variable "tags"`.

In `modules/platform_cluster/outputs.tf`, delete both blocks from
`output "jenkins_certificate_arn"` through the end of
`output "jenkins_public_hostname"` (lines 103-111). The file should end after
`output "jenkins_efs_access_point_id"`.

- [ ] **Step 4: Remove the bootstrap module's variables and annotations**

In `modules/platform_cluster_bootstrap/variables.tf`, delete all three blocks
from `variable "jenkins_certificate_arn"` through the end of
`variable "jenkins_alb_name"` (lines 66-82). The file should end after
`variable "jenkins_efs_access_point_id"`.

In `modules/platform_cluster_bootstrap/kubernetes.tf`, delete these three lines
(23-25) from the `annotations` map:

```hcl
      jenkins_certificate_arn               = var.jenkins_certificate_arn
      jenkins_public_hostname               = var.jenkins_public_hostname
      jenkins_alb_name                      = var.jenkins_alb_name
```

leaving `jenkins_efs_access_point_id` as the last entry.

- [ ] **Step 5: Remove the root variables, wiring and outputs**

In `environments/platform/variables.tf`, delete all three blocks from
`variable "jenkins_public_hostname"` through the end of
`variable "jenkins_dns_record_enabled"` (lines 102-118).

In `environments/platform/main.tf`, delete these three lines from the
`module "platform_cluster"` block:

```hcl
  jenkins_public_hostname      = var.jenkins_public_hostname
  route53_hosted_zone_name     = var.route53_hosted_zone_name
  jenkins_dns_record_enabled   = var.jenkins_dns_record_enabled
```

and these two from the `module "platform_cluster_bootstrap"` block:

```hcl
  jenkins_certificate_arn               = module.platform_cluster.jenkins_certificate_arn
  jenkins_public_hostname               = module.platform_cluster.jenkins_public_hostname
```

leaving `jenkins_efs_access_point_id` as the last input before `depends_on`.

In `environments/platform/outputs.tf`, delete both blocks from
`output "jenkins_certificate_arn"` through the end of
`output "jenkins_public_hostname"` (lines 71-79).

- [ ] **Step 6: Remove the settings from both tfvars files**

In `environments/platform/terraform.tfvars.example`, delete lines 11-15 — the
comment header and all three commented settings:

```hcl
# Public HTTPS exposure for Jenkins. Leave empty to keep the ALB internal.
# See docs/operations/public-workload-access.md for the two-phase apply.
# jenkins_public_hostname  = "jenkins.example.com"
# route53_hosted_zone_name = "example.com"
# jenkins_dns_record_enabled = false
```

In the untracked local `environments/platform/terraform.tfvars`, delete the same
three settings (lines 3-5), leaving:

```hcl
argocd_admin_user_ids      = ["695a554c-e021-70d4-0d26-bed0bd1fd266"]
public_access_cidrs        = ["42.114.206.119/32"]
```

This file is gitignored — do not stage it.

- [ ] **Step 7: Drop the forced variable from the destroy script**

In `scripts/destroy-platform.sh`, delete the comment and assignment at lines
86-90:

```bash
# Forced off for the destroy regardless of terraform.tfvars. The Route 53 alias
# reads the ALB through a data source, and that read fails the plan once the
# Ingress guard above has removed the load balancer. Setting it false drops the
# data source and destroys the alias record in the same pass.
destroy_vars=(-var jenkins_dns_record_enabled=false)
```

Then remove the three `"${destroy_vars[@]}"` expansions that referenced it, so
the three commands read:

```bash
terraform -chdir="$ROOT" destroy \
  -target=module.platform_cluster_bootstrap -input=false
```

```bash
  terraform -chdir="$ROOT" plan -destroy -out="$plan" -input=false
```

```bash
  terraform -chdir="$ROOT" plan -destroy \
    -target=module.platform_cluster -out="$plan" -input=false
```

- [ ] **Step 8: Verify no reference survives**

Run:

```bash
grep -rn "jenkins_public_hostname\|jenkins_certificate_arn\|jenkins_dns_record_enabled\|route53_hosted_zone_name\|jenkins_alb_name\|destroy_vars" \
  --include='*.tf' --include='*.tfvars*' --include='*.sh' --include='*.yaml' . | grep -v '^./.git/'
```

Expected: no output at all. Any hit is a missed deletion.

- [ ] **Step 9: Run the Terraform and shell gates**

Run:

```bash
make terraform-check
make shell-check
```

Expected: both exit 0. `terraform validate` is what catches a dangling
`var.jenkins_*` reference or an output pointing at a deleted resource.

- [ ] **Step 10: Commit**

```bash
git add modules/platform_cluster modules/platform_cluster_bootstrap environments/platform scripts/destroy-platform.sh
git commit -m "refactor: delete the Jenkins ACM and Route 53 exposure layer

Public access no longer needs a DNS name, so the certificate, validation
record, alias record and their four variables, two outputs and three cluster
Secret annotations all go. Exposing a workload is now a pure-GitOps change.
Drops the destroy script's forced jenkins_dns_record_enabled=false, which
would fail the plan against an undeclared variable.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Rewrite the runbook as the generic capability doc

The point of this task is that a future engineer exposing workload #2 has one
place to look and a block to copy. Four other docs currently describe the deleted
mechanism or predate it and must stop contradicting reality.

**Files:**
- Rewrite: `docs/operations/public-workload-access.md`
- Modify: `docs/operations/destroy-platform.md:72-79`
- Modify: `docs/operations/first-deployment-defects.md:420-423`
- Modify: `docs/operations/deploy-jenkins.md:34-35,48-53,76`
- Modify: `README.md:90`
- Modify: `CLAUDE.md` (Architecture section, after "Fargate namespace contract")

**Interfaces:**
- Consumes: the exact annotation block committed in Task 1. The runbook's opt-in block must match it verbatim, including which four annotations are group-level.
- Produces: no code. This task closes the plan.

- [ ] **Step 1: Replace `docs/operations/public-workload-access.md` entirely**

Write the file with this content:

````markdown
# Exposing a workload to the internet

Any workload in an `apps-*` namespace can be reached from the internet by
joining the **`platform-public` IngressGroup**. The aws-load-balancer-controller
assembles one shared internet-facing ALB named `aws-eks-infra-public` from every
Ingress in the group and routes to each workload by path prefix.

There is no DNS layer. You reach workloads at the ALB's AWS-assigned name:

```
http://aws-eks-infra-public-<id>.<region>.elb.amazonaws.com
  /jenkins  -> apps-jenkins/jenkins:8080
  /         -> 503
```

`/` returning 503 is correct: the group has no catch-all member. It is not a
fault.

Traffic is **HTTP only and open to the world**. See [Security](#security) before
putting anything sensitive behind it.

## Ownership

Exposing a workload touches **no Terraform**. Argo CD owns the Ingress; the
controller owns the ALB; Terraform owns neither. The repository invariant holds —
no resource is managed by both sides.

| Piece | Owner |
|---|---|
| The Ingress and its annotations | Argo CD (`gitops/workloads/config/charts/*.yaml`) |
| The shared ALB, listener, rules, target groups | aws-load-balancer-controller |
| Public subnets tagged `kubernetes.io/role/elb=1` | Terraform (`modules/platform_cluster/vpc.tf`) |
| The controller's IRSA role | Terraform (`modules/platform_cluster/iam_load_balancer_controller.tf`) |

## Prerequisites

The controller must be running and the `alb` IngressClass present:

```bash
kubectl get ingressclass alb
kubectl -n kube-system get deploy aws-load-balancer-controller
```

The workload's namespace must match an `apps-*` Fargate profile selector, or its
Pods stay Pending with no capacity.

## The opt-in contract

Add this to the workload's Ingress. The first four annotations are **group-level**:
the controller merges them across all members, and if any two members disagree it
refuses to reconcile the group — which takes down every workload on the ALB, not
just the new one. Copy them exactly.

```yaml
ingressClassName: alb
path: /<prefix>          # and NO hostName, so the rule matches any Host header
annotations:
  # --- Group-level: byte-identical on every member.
  alb.ingress.kubernetes.io/group.name: platform-public
  alb.ingress.kubernetes.io/scheme: internet-facing
  alb.ingress.kubernetes.io/load-balancer-name: aws-eks-infra-public
  alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
  # --- Per workload.
  alb.ingress.kubernetes.io/target-type: ip          # the only mode Fargate supports
  alb.ingress.kubernetes.io/group.order: '20'        # unique, -1000..1000, lower evaluated first
  alb.ingress.kubernetes.io/healthcheck-path: /<prefix>/<health-endpoint>
```

`group.order` values in use: Jenkins `10`. Pick an unused number.

### Keep Argo CD placeholders out of the annotations

Charts commonly run Helm's `tpl` over `ingress.annotations` — the Jenkins chart
does. A `{{ .metadata.annotations.foo }}` placeholder left in an annotation is
therefore evaluated twice: once by Argo CD's ApplicationSet, which substitutes
it, and then again by Helm, which has no such context. It works in the cluster
only because Argo CD wins the race, and it makes the chart impossible to render
standalone for testing. Every value in the block above is a literal for this
reason. Values that genuinely vary per cluster belong on the cluster `Secret`
and outside the annotations.

### The app must serve under its own prefix

ALB path rewriting is awkward, so the workload is expected to know its prefix and
generate links that include it. Most platform tools support this with one
setting — Jenkins uses `controller.jenkinsUriPrefix: /jenkins`, which passes
`--prefix=/jenkins` to the war and also prefixes the chart's own liveness,
readiness and startup probes.

If an app cannot do this, use the escape hatch: **omit `group.name` and pin a
different `load-balancer-name`.** That workload gets its own dedicated ALB and
its own AWS hostname, serving at `/`, at the cost of another load balancer.

## Verify

```bash
kubectl -n <namespace> get ingress                     # ADDRESS populated
aws elbv2 describe-load-balancers --names aws-eks-infra-public \
  --query 'LoadBalancers[0].[Scheme,State.Code,DNSName]' --output text
```

Expect `internet-facing` and `active`. Then, using the `DNSName` from above:

```bash
curl -sI http://<dns-name>/<prefix>/ | head -1
```

`scripts/verify-platform.sh` asserts that every Ingress has been reconciled into
a load balancer address, so a workload stuck without one fails acceptance.

If the ADDRESS never appears, read the controller's reasoning:

```bash
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50
```

A group-level annotation mismatch shows up there as an explicit conflict naming
the two disagreeing Ingresses.

## Security

The ALB is open to `0.0.0.0/0` over plain HTTP. This is a deliberate choice for a
sample platform, and it has real consequences:

- **Credentials cross the internet in cleartext.** Anything you type into a
  login form on this ALB is readable in transit.
- **Jenkins executes arbitrary pipeline code.** A publicly reachable Jenkins is a
  high-value target. Keep the admin password rotated and prefer SSO for anything
  beyond bootstrap.

To restrict the source range without introducing DNS, add one annotation — it is
per-Ingress and needs no other change:

```yaml
alb.ingress.kubernetes.io/inbound-cidrs: 203.0.113.10/32
```

This is the ALB's own source filter and is independent of `public_access_cidrs`,
which restricts the **EKS API server**, not workload traffic.

## Upgrade path: real hostnames with TLS

When a workload needs a real name and HTTPS, the missing pieces are a public
Route 53 hosted zone, an ACM certificate, and something to write the alias
record. Terraform cannot plan the alias itself, because the ALB hostname is
assigned by the controller and is unknown until the Ingress has reconciled —
that ordering problem is what made the previous Jenkins-specific implementation a
three-phase apply.

[external-dns](https://github.com/kubernetes-sigs/external-dns) removes the split
by watching Ingress objects and writing Route 53 records itself, reducing
exposure to a single annotation:

```yaml
external-dns.alpha.kubernetes.io/hostname: jenkins.example.com
```

It needs an IRSA role scoped to `route53:ChangeResourceRecordSets` on the zone,
and runs in `kube-system`, which already matches a Fargate profile selector — so
no Fargate change. It is deliberately not installed today.
````

- [ ] **Step 2: Remove the stale section from `destroy-platform.md`**

Delete the entire `## jenkins_dns_record_enabled` section (lines 72-79), from the
heading through `See [public workload access](public-workload-access.md).`, so
the `## Afterwards` heading follows step 3 directly.

- [ ] **Step 3: Correct the defect log in `first-deployment-defects.md`**

Replace the trailing sentence at lines 420-423:

```markdown
It now destroys `module.platform_cluster_bootstrap` and `module.platform_cluster`
by target and preserves those account-level resources. `DESTROY_ROOT=true` opts
into the full root destroy. It also forces
`-var jenkins_dns_record_enabled=false`, because the Route 53 alias reads the ALB
through a data source that fails the plan once the load balancer is gone.
```

with:

```markdown
It now destroys `module.platform_cluster_bootstrap` and `module.platform_cluster`
by target and preserves those account-level resources. `DESTROY_ROOT=true` opts
into the full root destroy. It also once forced
`-var jenkins_dns_record_enabled=false`, because the Route 53 alias read the ALB
through a data source that failed the plan after the load balancer was gone; that
variable and the alias record no longer exist, so the flag was removed with them.
```

- [ ] **Step 4: Update `deploy-jenkins.md` to describe the public path**

Replace lines 34-35, which currently end the acceptance sentence with
`and the jenkins Ingress has an internal ALB address.`, so it reads
`and the jenkins Ingress has a public ALB address.`

Replace the access section at lines 48-53:

```markdown
The ALB is internal. From a host inside the VPC (VPN or bastion), browse to the
ingress address. Otherwise port-forward:

```bash
kubectl -n apps-jenkins port-forward svc/jenkins 8080:8080
# open http://localhost:8080
```
```

with:

```markdown
Jenkins is served on the shared public ALB under `/jenkins`:

```bash
aws elbv2 describe-load-balancers --names aws-eks-infra-public \
  --query 'LoadBalancers[0].DNSName' --output text
# open http://<dns-name>/jenkins
```

See [public workload access](public-workload-access.md). The admin UI shows a
"Jenkins URL is not set" monitor: the ALB hostname is assigned by AWS and cannot
be templated in, so JCasC falls back to the in-cluster URL. That URL is the
correct one for the agent JNLP handshake, so the warning is cosmetic. To clear
it, paste the ALB name into Manage Jenkins → System → Jenkins URL.

If you would rather not go over the internet, port-forward instead:

```bash
kubectl -n apps-jenkins port-forward svc/jenkins 8080:8080
# open http://localhost:8080/jenkins
```
```

Line 76 already lists `TLS termination on the ALB via ACM.` as a follow-up that
is out of scope. That is once again accurate — leave it.

- [ ] **Step 5: Update the `README.md` pointer**

Replace line 90:

```markdown
To give a workload a public DNS name with TLS, follow [public workload access](docs/operations/public-workload-access.md).
```

with:

```markdown
To reach a workload from the internet, join the shared `platform-public` ALB — see [public workload access](docs/operations/public-workload-access.md). It is HTTP only and open to the world by design.
```

- [ ] **Step 6: Record the convention in `CLAUDE.md`**

In the `## Architecture` section, immediately after the
`### Fargate namespace contract` block, add:

```markdown
### Public access contract

Reaching a workload from the internet is a **pure-GitOps change** — Terraform has
no public-access variables, outputs or annotations. The workload's Ingress joins
the `platform-public` IngressGroup, which the load balancer controller assembles
into one shared internet-facing ALB named `aws-eks-infra-public`, routing by path
prefix (`/jenkins`, …) over HTTP on port 80.

Four annotations are group-level and must be byte-identical on every member —
`group.name`, `scheme`, `load-balancer-name`, `listen-ports` — because a mismatch
stops the controller reconciling the whole group, not just the new workload. The
app must serve under its own path prefix; ALB path rewriting is not used. See
`docs/operations/public-workload-access.md` for the block to copy.
```

- [ ] **Step 7: Verify the docs are internally consistent**

Run:

```bash
grep -rn "jenkins_dns_record_enabled\|jenkins_certificate_arn\|two-phase apply\|ALB is internal\|public DNS name with TLS" \
  --include='*.md' . | grep -v '^./docs/superpowers/'
```

Expected: no output. `docs/superpowers/` is excluded because the spec and this
plan describe the deleted mechanism on purpose.

Then confirm the runbook's opt-in block matches what Task 1 actually shipped:

```bash
grep -c "alb.ingress.kubernetes.io/group.name: platform-public" \
  docs/operations/public-workload-access.md gitops/workloads/config/charts/jenkins.yaml
```

Expected: `1` for each file.

- [ ] **Step 8: Run every gate one final time**

Run:

```bash
make terraform-check
make yaml-check
make shell-check
```

Expected: all three exit 0.

- [ ] **Step 9: Commit**

```bash
git add docs/operations README.md CLAUDE.md
git commit -m "docs: document public access as a generic workload capability

Rewrite the runbook around the platform-public IngressGroup with the exact
opt-in block, the group-level annotation constraint and the dedicated-ALB
escape hatch. Correct four docs that described the deleted ACM/Route 53
mechanism or predated it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Done when

- `make terraform-check`, `make yaml-check` and `make shell-check` all pass.
- No `.tf`, `.tfvars`, `.sh` or `.yaml` file mentions `jenkins_public_hostname`, `jenkins_certificate_arn`, `jenkins_dns_record_enabled`, `route53_hosted_zone_name` or `jenkins_alb_name`.
- The rendered Jenkins Ingress has no `host:`, serves `/jenkins`, belongs to group `platform-public`, targets `aws-eks-infra-public`, listens on HTTP 80 only, and carries no TLS annotation.
- Adding the next public workload requires editing exactly one file under `gitops/workloads/config/charts/`.

## Not verifiable until the platform is redeployed

The cluster is destroyed, so no task in this plan can prove the ALB actually
serves traffic. After the next `terraform apply` and Argo CD sync, confirm:

```bash
kubectl -n apps-jenkins get ingress jenkins
aws elbv2 describe-load-balancers --names aws-eks-infra-public \
  --query 'LoadBalancers[0].[Scheme,State.Code,DNSName]' --output text
curl -sI http://<dns-name>/jenkins/login | head -1
```

Expect `internet-facing`, `active`, and `HTTP/1.1 200 OK`.
