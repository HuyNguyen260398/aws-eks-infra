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
pathType: Prefix         # NOT ImplementationSpecific - see below
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

### `pathType` must be `Prefix`

Many charts default `pathType` to `ImplementationSpecific`, which the load
balancer controller passes through verbatim — the ALB then gets a single
**exact-match** rule for `/<prefix>`, and every subpath (`/<prefix>/login`,
`/<prefix>/static/...`) returns a `404` from the load balancer before it ever
reaches your Pod. The workload looks deployed and healthy while being almost
entirely unreachable.

`Prefix` makes the controller emit both `/<prefix>` and `/<prefix>/*`. Confirm
the resulting rules rather than trusting the Ingress:

```bash
lb=$(aws elbv2 describe-load-balancers --names aws-eks-infra-public \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
li=$(aws elbv2 describe-listeners --load-balancer-arn "$lb" \
  --query 'Listeners[0].ListenerArn' --output text)
aws elbv2 describe-rules --listener-arn "$li" \
  --query 'Rules[].[Priority,Conditions[0].PathPatternConfig.Values]' --output text
```

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
