# Exposing a workload publicly over HTTPS

How to give an `apps-*` workload a public DNS name with TLS terminated on an
internet-facing ALB. Jenkins is the worked example; the same four pieces apply to
any future workload.

Nothing is served in the clear — HTTP is accepted only to redirect to HTTPS.

## Ownership split

The repository invariant holds: no resource is managed by both sides.

| Piece | Owner | Where |
|---|---|---|
| ACM certificate + DNS validation record | Terraform | `modules/platform_cluster/jenkins_public.tf` |
| Route 53 alias record → ALB | Terraform | same file |
| Certificate ARN and hostname handoff | Terraform | cluster `Secret` annotations |
| Ingress, ALB annotations, redirect | Argo CD | `gitops/workloads/config/charts/jenkins.yaml` |
| The ALB itself | aws-load-balancer-controller | created from the Ingress |

The ALB is created by the controller, not Terraform. Terraform therefore cannot
plan the alias record until the Ingress has reconciled at least once, which is
why exposure is a **two-phase apply**.

## Prerequisites

- A public Route 53 hosted zone you control, in the same account.
- The public subnets tagged `kubernetes.io/role/elb=1`. `modules/platform_cluster/vpc.tf`
  already sets this, so no change is needed.
- aws-load-balancer-controller `Synced`/`Healthy` and an `alb` IngressClass:

  ```bash
  kubectl get ingressclass alb
  kubectl -n kube-system get deploy aws-load-balancer-controller
  ```

## Phase 1 — certificate

Set in `environments/platform/terraform.tfvars`:

```hcl
jenkins_public_hostname  = "jenkins.example.com"
route53_hosted_zone_name = "example.com"
```

```bash
terraform -chdir=environments/platform apply
```

This issues a DNS-validated ACM certificate, writes the `_acme`-style validation
`CNAME` into the hosted zone, waits for `ISSUED`, and publishes two new
annotations on the Argo CD cluster `Secret`: `jenkins_certificate_arn` and
`jenkins_public_hostname`.

`jenkins_dns_record_enabled` stays `false` here. Leaving it `true` on a cluster
whose ALB does not exist yet makes the `data "aws_lb"` lookup fail the plan.

Gate:

```bash
terraform -chdir=environments/platform output -raw jenkins_certificate_arn
kubectl -n argocd get secret platform-cluster \
  -o jsonpath='{.metadata.annotations.jenkins_certificate_arn}'
```

Both must be a non-empty ACM ARN. The Ingress consumes the ARN through
`{{ .metadata.annotations.jenkins_certificate_arn }}`, and with
`goTemplateOptions: [missingkey=error]` an unset annotation fails the
ApplicationSet loudly rather than producing an ALB with no certificate.

## Phase 2 — Ingress

Merge the GitOps change to the tracked revision (`main`) and let Argo CD
reconcile, or nudge it:

```bash
kubectl -n argocd annotate application <cluster>-jenkins \
  argocd.argoproj.io/refresh=hard --overwrite
```

The Ingress annotations that matter:

```yaml
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/load-balancer-name: aws-eks-infra-jenkins
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
alb.ingress.kubernetes.io/certificate-arn: '{{ .metadata.annotations.jenkins_certificate_arn }}'
alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
alb.ingress.kubernetes.io/ssl-redirect: '443'
```

`load-balancer-name` is pinned so the Terraform lookup in phase 3 is
deterministic. It must be 1–32 characters of alphanumerics and hyphens, and must
match `var.jenkins_alb_name`.

> **`scheme` is immutable.** Changing `internal` → `internet-facing` **replaces**
> the load balancer. The old DNS name stops working and a new one is allocated.
> Expect a short outage and never assume the hostname is stable across this
> change.

Gate:

```bash
kubectl -n apps-jenkins get ingress jenkins
aws elbv2 describe-load-balancers --names aws-eks-infra-jenkins \
  --query 'LoadBalancers[0].[Scheme,State.Code]' --output text
```

Expect `internet-facing` and `active`.

## Phase 3 — DNS

Now that the ALB exists, enable the alias record:

```hcl
jenkins_dns_record_enabled = true
```

```bash
terraform -chdir=environments/platform apply
```

Gate:

```bash
dig +short jenkins.example.com
curl -sI https://jenkins.example.com/login | head -1
curl -sI http://jenkins.example.com/login | head -1   # expect 301 to https
```

## Adding another workload

Repeat the same four pieces, renaming per workload:

1. Add `<workload>_public_hostname` plus the certificate, validation record and
   alias record in a new `modules/platform_cluster/<workload>_public.tf`. Copy the
   `count`-based shape — **do not** `for_each` over
   `domain_validation_options`, which is unknown at plan time for a new
   certificate and reproduces the failure in
   [first deployment defects](first-deployment-defects.md).
2. Surface `<workload>_certificate_arn` and `<workload>_public_hostname` as
   cluster `Secret` annotations in `modules/platform_cluster_bootstrap`.
3. Reference them from the workload's ApplicationSet as
   `{{ .metadata.annotations.<name> }}`. The ApplicationSet must set
   `goTemplate: true`.
4. Confirm the namespace matches an `apps-*` Fargate profile selector.

## Recommended improvement: external-dns

Phases 2 and 3 are split only because Terraform cannot read the ALB hostname that
the controller assigns. [external-dns](https://github.com/kubernetes-sigs/external-dns)
removes that split by watching Ingress objects and writing Route 53 records
itself, reducing exposure to a single annotation:

```yaml
external-dns.alpha.kubernetes.io/hostname: jenkins.example.com
```

It would need an IRSA role scoped to `route53:ChangeResourceRecordSets` on the
zone, and can run in `kube-system`, which is already a Fargate profile selector —
so no Fargate profile change. This is deliberately **not** installed today; it is
the right next step if more than one or two workloads need public names.

## Security notes

- TLS 1.2 minimum via `ELBSecurityPolicy-TLS13-1-2-2021-06`, TLS 1.3 preferred.
- HTTP is accepted only to issue a 301. No credential ever crosses the network in
  cleartext.
- The ALB is open to `0.0.0.0/0`. To restrict it, add
  `alb.ingress.kubernetes.io/inbound-cidrs` — note this is the ALB's own source
  filter and is independent of `public_access_cidrs`, which restricts the **EKS
  API server**, not workload traffic.
- Jenkins executes arbitrary pipeline code. A publicly reachable Jenkins is a
  high-value target: keep the admin password rotated, and prefer SSO over the
  local `admin` account for anything beyond bootstrap.
- `scripts/verify-platform.sh` asserts `No Ingress` and `No service workloads`.
  Both fail by design once any workload is exposed; see
  [first deployment defects](first-deployment-defects.md).
