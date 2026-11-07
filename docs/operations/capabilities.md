# Managed EKS capabilities

The platform Terraform root creates AWS-managed Argo CD, ACK, and kro capabilities. They run outside the Fargate-only cluster; Terraform does not install capability controllers or duplicate their access policies in Kubernetes.

## Apply

Complete the GitHub CodeConnections authorization described in [GitHub CodeConnections](github-connection.md) before applying. Initialize and apply the platform root using its local, ignored backend and variable files.

Capabilities belong to `module.platform_cluster`, which is applied on its own before the Argo CD bootstrap. The untargeted root cannot be planned until the Argo CD capability is `ACTIVE` and its `ApplicationSet` CRD exists — [deploy the platform](deploy-platform.md#why-the-apply-is-staged) explains why, and is the authoritative sequence.

```bash
terraform -chdir=environments/platform init -backend-config=backend.hcl
terraform -chdir=environments/platform plan -target=module.platform_cluster -out=tfplan
terraform -chdir=environments/platform apply tfplan
```

Terraform retains capability resources if they are removed from configuration. Review retained capabilities explicitly in the EKS console before any manual deletion.

## Verify readiness

Poll every capability until it is active. `DEGRADED`, `DELETING`, and `CREATE_FAILED` are terminal failures; stop and inspect the capability health details. The AWS API can also return `UPDATE_FAILED`, which is treated as a failure by the command below.

```bash
cluster_name="$(terraform -chdir=environments/platform output -raw cluster_name)"
region="${AWS_REGION:?Set AWS_REGION to the platform Terraform region}"

for capability_name in "${cluster_name}-argocd" "${cluster_name}-ack" "${cluster_name}-kro"; do
  while :; do
    status="$(aws eks describe-capability --region "$region" --cluster-name "$cluster_name" --capability-name "$capability_name" --query 'capability.status' --output text)"
    case "$status" in
      ACTIVE) break ;;
      DEGRADED|DELETING|CREATE_FAILED|UPDATE_FAILED) echo "$capability_name is $status" >&2; exit 1 ;;
      *) echo "$capability_name is $status; waiting"; sleep 15 ;;
    esac
  done
done
```

Then configure `kubectl` for the cluster and verify that all capability APIs are available:

```bash
kubectl api-resources | grep -E 'Application|ApplicationSet|ResourceGraphDefinition|IAMRoleSelector'
```

Expected output includes the `Application` and `ApplicationSet` Argo CD APIs, `ResourceGraphDefinition` from kro, and `IAMRoleSelector` from ACK. The next GitOps bootstrap task must wait for this check.

## Access model and recovery

Only the Argo CD capability role receives `AmazonEKSClusterAdminPolicy` at cluster scope. It needs this access to install the platform's cluster-scoped CRDs and controllers; ACK and kro receive capability-created access policies and must not receive duplicate cluster-admin associations.

If a capability fails, inspect its health and trust role before retrying:

```bash
aws eks describe-capability --region "$region" --cluster-name "$cluster_name" --capability-name "${cluster_name}-argocd"
aws iam get-role --role-name "${cluster_name}-argocd-capability"
```

Confirm the role trusts only `capabilities.eks.amazonaws.com`, and that the Argo CD role's inline policy limits `codeconnections:GetConnection` and `codeconnections:UseConnection` to the Terraform-managed connection ARN. Do not run Kubernetes operations until all capabilities are `ACTIVE`.
