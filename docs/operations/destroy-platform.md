# Destroy the Platform

```bash
./scripts/destroy-platform.sh "destroy platform"
```

The literal argument is required. The script never uses `-auto-approve`, so you
still review each plan, and it never touches `bootstrap/terraform-state`.

## What is destroyed, and what is kept

By default the script destroys `module.platform_cluster_bootstrap` and
`module.platform_cluster` and **preserves** the account-level resources in the
root:

| Kept by default | Why |
|---|---|
| `aws_codeconnections_connection.github` | Reauthorizing the GitHub App is a manual console step that cannot be automated. Destroying the connection adds it back to the next deploy. |
| `aws_identitystore_group.argocd_admins` and its membership | Cheap to keep, and the group ID is referenced by the Argo CD capability's RBAC mapping. |

To remove them too:

```bash
DESTROY_ROOT=true ./scripts/destroy-platform.sh "destroy platform"
```

Expect to re-authorize the GitHub connection by hand on the next deploy — see
[GitHub CodeConnections](github-connection.md).

## Pre-flight guards

The guards only run while the EKS cluster is still in Terraform state. A
partially destroyed platform stays destroyable, but if the cluster *is* in state
and `kubectl` cannot reach it, the script refuses rather than treat a stale
kubeconfig as "nothing deployed".

The script refuses if any of these exist:

1. **Workload Applications** — any Argo CD Application with a source path under
   `gitops/workloads`. This checks both `.spec.source.path` and every entry of
   `.spec.sources[].path`; a multi-source Application leaves `.spec.source` null,
   so checking only the singular field silently misses workloads like Jenkins.
2. **Ingress objects.**
3. **LoadBalancer Services.**

Guards 2 and 3 matter more than they look. Those objects are backed by load
balancers that `aws-load-balancer-controller` creates, and **Terraform has no
record of them**. Destroy the cluster first and the load balancer is orphaned;
its ENIs and security groups then fail the VPC destroy. The finalizer that
releases the AWS resources (`ingress.k8s.aws/resources`) only works while the
controller is still running.

## Recommended order

1. Delete the workload's Argo CD ApplicationSet. Deletion cascades to the
   Application, whose `resources-finalizer.argocd.argoproj.io` prunes the
   Ingress, whose own finalizer blocks until the ALB is actually gone. The
   sequencing is automatic — just wait for it.

   ```bash
   kubectl -n argocd delete applicationset <name>
   ```

2. Confirm no load balancer survives:

   ```bash
   aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text   # 0
   ```

3. Run the script.

## `jenkins_dns_record_enabled`

The script forces `-var jenkins_dns_record_enabled=false` on every destroy plan,
regardless of `terraform.tfvars`. The Route 53 alias reads the ALB through a
`data "aws_lb"` lookup, and once the Ingress guard has removed the load balancer
that read fails the plan with `reading ELBv2 Load Balancers: couldn't find
resource`. Forcing the flag off drops the data source and destroys the alias
record in the same pass. See [public workload access](public-workload-access.md).

## Afterwards

Verify nothing was left behind:

```bash
aws eks list-clusters
aws efs describe-file-systems --query 'length(FileSystems)'
aws elbv2 describe-load-balancers --query 'length(LoadBalancers)'
aws ec2 describe-nat-gateways --query 'NatGateways[?State!=`deleted`]'
terraform -chdir=environments/platform state list
```

Two things are expected to remain:

- **KMS keys in `PendingDeletion`.** Both cluster keys, the observability key and
  the EFS key carry a 30-day window. They delete themselves; each teardown cycle
  adds another set that lingers for a month.
- **Stale entries in the Resource Groups Tagging API.** Querying
  `Key=Project,Values=aws-eks-infra` keeps returning recently deleted NAT
  gateways, security groups and flow logs for a while. Confirm against the
  service's own API before treating anything as a leftover.
