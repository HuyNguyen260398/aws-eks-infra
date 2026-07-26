# Generic public workload access — design

Date: 2026-07-26

## Problem

Workloads deployed to the platform cluster are not reachable from the internet.

The repository already contains a Jenkins-specific public-HTTPS path (added in PR
#11): an ACM certificate, a Route 53 validation record and an alias record in
`modules/platform_cluster/jenkins_public.tf`, handed to Argo CD through cluster
`Secret` annotations and consumed by the Jenkins Ingress. Three things are wrong
with it for this platform:

1. **It never completed.** Exposure is a three-phase apply — issue the
   certificate, let Argo CD create the ALB, then flip `jenkins_dns_record_enabled`
   and apply again. The flag is `false` in `environments/platform/terraform.tfvars`,
   so no alias record was ever created and the name never resolved. Because the
   Ingress rule pins `hostName`, the ALB's own DNS name returns 404, leaving no
   way in at all.
2. **It does not survive a rebuild.** `scripts/destroy-platform.sh` forces
   `-var jenkins_dns_record_enabled=false` on every destroy, so the three-phase
   dance repeats after each teardown.
3. **It is not generic.** Every new workload would need its own
   `<workload>_public.tf`, its own certificate, its own alias record and its own
   pair of cluster `Secret` annotations — a Terraform change per workload.

A DNS layer is not wanted. The requirement is only that services deployed to the
cluster be reachable from the internet, and that the mechanism apply uniformly to
any workload added later.

## Current state

The platform is destroyed. `aws eks list-clusters` in `ap-southeast-1` returns
`[]`, no load balancers exist, no `jenkins.nghuy.link` certificate exists, and
`terraform state list` for `environments/platform` holds only the CodeConnections
connection and the Identity Center group. No state surgery is therefore required
— the ACM and Route 53 resources can be deleted from configuration cleanly.

Everything else needed for public access already works and is unchanged by this
design:

| Piece | Where |
|---|---|
| Public subnets, IGW, `kubernetes.io/role/elb=1` | `modules/platform_cluster/vpc.tf` |
| aws-load-balancer-controller + IRSA (official 16-statement policy) | `gitops/platform/config/addons/aws-load-balancer-controller.yaml`, `modules/platform_cluster/iam_load_balancer_controller.tf` |
| `apps-*` Fargate profile selector | `modules/platform_cluster/eks.tf` |

NetworkPolicy is a non-issue: the `namespace-config` chart has no release, and
Fargate does not enforce Kubernetes NetworkPolicy.

## Decision

**One shared internet-facing ALB, HTTP only, owned entirely by Argo CD.**

A single ALB named `aws-eks-infra-public` is assembled by the load balancer
controller from an *IngressGroup*. Each workload that wants public access joins
the group by adding a fixed annotation block to its Ingress and serving under its
own path prefix. Requests reach `http://<alb-dns-name>/<prefix>`.

Exposing a workload becomes a pure-GitOps change. Terraform is not involved at
all — no variables, no outputs, no cluster `Secret` annotations.

### Routing

```
http://aws-eks-infra-public-<id>.ap-southeast-1.elb.amazonaws.com
  /jenkins  -> apps-jenkins/jenkins:8080
  /         -> 503 (no default rule; expected)
```

`/` returning 503 is correct behaviour for a group with no catch-all member, not
a fault.

### The opt-in contract

Every member of the group carries these annotations. The first four are
**group-level**: the controller merges them across members and they must be
byte-identical on every member or reconciliation fails.

```yaml
alb.ingress.kubernetes.io/scheme: internet-facing          # group-level
alb.ingress.kubernetes.io/load-balancer-name: aws-eks-infra-public   # group-level
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'   # group-level
alb.ingress.kubernetes.io/group.name: platform-public      # group-level
alb.ingress.kubernetes.io/target-type: ip                  # per workload; required on Fargate
alb.ingress.kubernetes.io/group.order: '10'                # per workload; unique, -1000..1000, lower evaluated first
alb.ingress.kubernetes.io/healthcheck-path: /jenkins/login # per workload
```

Plus, on the Ingress rule itself: **no `host:`**, and a `path` equal to the
workload's prefix.

Two constraints follow, and both are documented rather than engineered around:

- **The app must serve under its own prefix.** ALB path rewriting is awkward, so
  the workload is expected to know its prefix. Jenkins supports this natively
  (`controller.jenkinsUriPrefix` passes `--prefix=/jenkins` to the war, and
  Jenkins then generates prefixed links). An app that cannot do this uses the
  escape hatch below.
- **Escape hatch:** a workload that needs to serve at `/` omits `group.name` and
  pins its own `load-balancer-name`. It gets a dedicated ALB and its own AWS
  hostname, at the cost of another load balancer.

### Access control

The ALB is open to `0.0.0.0/0`, as requested for this sample platform. No
`inbound-cidrs` annotation is set.

This is a deliberate, stated trade-off: traffic is HTTP, so Jenkins admin
credentials cross the internet in cleartext, and Jenkins executes arbitrary
pipeline code. The mitigation, if wanted later, is one annotation
(`alb.ingress.kubernetes.io/inbound-cidrs`) and requires no other change. This is
recorded in the runbook's security section.

## Rejected alternatives

**Keep the domain, automate DNS with external-dns.** Removes the manual phase 3
and yields real HTTPS, but reintroduces a Route 53 dependency and a new IRSA
role. Explicitly not wanted: "we do not need to have a dns". Retained in the
runbook as the documented upgrade path for when a real domain is wanted.

**Flip `jenkins_dns_record_enabled` and change nothing else.** Restores Jenkins
access but leaves the mechanism Jenkins-specific, three-phase, and destroyed by
every rebuild.

**One ALB per workload.** Simplest per-app configuration and no prefix
constraint, but cost and hostname count grow linearly. Kept as the documented
escape hatch rather than the default.

## Changes

### Terraform — deletions only

- Delete `modules/platform_cluster/jenkins_public.tf` entirely: hosted-zone data
  source, ACM certificate, DNS validation record, `aws_acm_certificate_validation`,
  `data "aws_lb"`, the alias record, and the three-assertion `check` block.
- `modules/platform_cluster/variables.tf` — remove `jenkins_public_hostname`,
  `route53_hosted_zone_name`, `jenkins_dns_record_enabled`, `jenkins_alb_name`.
- `modules/platform_cluster/outputs.tf` — remove `jenkins_certificate_arn`,
  `jenkins_public_hostname`.
- `modules/platform_cluster_bootstrap/variables.tf` and `kubernetes.tf` — remove
  the `jenkins_certificate_arn`, `jenkins_public_hostname` and `jenkins_alb_name`
  variables and their cluster `Secret` annotations.
- `environments/platform/variables.tf` — remove the three variables.
- `environments/platform/main.tf` — remove the module wiring (the three inputs to
  `platform_cluster`, the two inputs to `platform_cluster_bootstrap`).
- `environments/platform/outputs.tf` — remove `jenkins_certificate_arn` and
  `jenkins_public_hostname`.
- `environments/platform/terraform.tfvars.example` and the untracked local
  `terraform.tfvars` — remove the three settings.

The ALB name `aws-eks-infra-public` moves into YAML. This does not violate the
"no account-specific values in YAML" rule: it is a fixed name, not an account,
region or ARN.

### GitOps — `gitops/workloads/config/charts/jenkins.yaml`

```yaml
controller:
  jenkinsUrlProtocol: http        # was https
  jenkinsUriPrefix: /jenkins      # new; serves the war under the prefix
  # jenkinsUrl removed - no name to point at
  ingress:
    path: /jenkins                # new
    # hostName removed -> host-less rule
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing              # unchanged
      alb.ingress.kubernetes.io/target-type: ip                      # unchanged
      alb.ingress.kubernetes.io/group.name: platform-public          # new
      alb.ingress.kubernetes.io/group.order: '10'                    # new
      alb.ingress.kubernetes.io/load-balancer-name: aws-eks-infra-public  # was the jenkins_alb_name annotation
      alb.ingress.kubernetes.io/healthcheck-path: /jenkins/login     # was /login
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'       # was HTTP + HTTPS
      # certificate-arn, ssl-policy, ssl-redirect removed
```

`controller.jenkinsUrl` is removed because no name is knowable at render time.
JCasC then falls back to `location.url: http://jenkins:8080/jenkins`. This is
cosmetically imperfect — the admin UI shows a "Jenkins URL is not set" monitor —
but functionally correct: agents run in `apps-jenkins`, so the in-cluster URL is
the right one for the JNLP handshake. Documented, not worked around.

### Scripts

- `scripts/destroy-platform.sh` — remove the forced
  `-var jenkins_dns_record_enabled=false`.

`scripts/verify-platform.sh` needs no change: it already asserts that every
Ingress has been reconciled into a load balancer address, which is the right
acceptance signal.

### Docs

- `docs/operations/public-workload-access.md` — rewrite as the generic
  capability runbook: how the shared group works, the opt-in annotation block,
  which annotations are group-level, how to find the ALB hostname, the `/` → 503
  behaviour, the prefix constraint and dedicated-ALB escape hatch, security
  notes, and the retained external-dns/HTTPS upgrade path.
- `docs/operations/destroy-platform.md` — remove the `jenkins_dns_record_enabled`
  section.
- `docs/operations/first-deployment-defects.md` — update the reference at line
  422.
- `docs/operations/deploy-jenkins.md` — update "TLS termination on the ALB via
  ACM" and the Jenkins URL, now path-prefixed.
- `README.md` — update the public-access line.
- `CLAUDE.md` — add a short note that exposing a workload is a pure-GitOps change
  via the `platform-public` IngressGroup, alongside the Fargate namespace
  contract.

## Verification

Static gates, all of which must pass:

```bash
make terraform-check
make yaml-check
make shell-check
```

Plus a targeted render asserting the contract holds. Extract the `helm.values`
block from the edited ApplicationSet, render the upstream chart with it, and
confirm the Ingress has no `host:`, a `/jenkins` path, the four group-level
annotations, and none of `certificate-arn`, `ssl-policy`, `ssl-redirect`:

```bash
helm template jenkins jenkins/jenkins --version 5.9.42 -f values-from-appset.yaml \
  | yq 'select(.kind == "Ingress")'
```

Post-deploy acceptance, once the platform is applied again:

```bash
kubectl -n apps-jenkins get ingress jenkins        # ADDRESS populated
aws elbv2 describe-load-balancers --names aws-eks-infra-public \
  --query 'LoadBalancers[0].[Scheme,State.Code,DNSName]' --output text
curl -sI http://<alb-dns-name>/jenkins/login | head -1
```

Expect `internet-facing`, `active`, and a `200`.

## Out of scope

- HTTPS, custom domains, ACM, Route 53, CloudFront, external-dns.
- Restricting the ALB source CIDR.
- Exposing Argo CD itself.
- Any second workload; Jenkins is the only member of the group today, and the
  runbook describes how to add the next one.
