# Managed Argo CD capability

With `enable_argocd = true`, the platform root creates the AWS-managed Argo CD EKS capability. It runs outside the cluster; Terraform does not install Argo CD controllers or duplicate their access policies in Kubernetes. The ACK and kro capabilities from the original reference platform have been removed — Cashight uses neither.

The capability costs about USD 27/month plus about USD 1.32 per Argo CD Application/month, which is why it is off by default.

## Apply

Complete the GitHub CodeConnections authorization described in [GitHub CodeConnections](github-connection.md) first. Turning the capability on is a staged apply — [deploy the platform, Stage 5](deploy-platform.md#stage-5--turn-on-argo-cd-when-there-is-something-to-deploy) is the authoritative sequence:

```bash
terraform -chdir=environments/platform plan -target=module.platform_cluster -out=tfplan
terraform -chdir=environments/platform apply tfplan
```

The capability uses `delete_propagation_policy = "RETAIN"`: setting `enable_argocd = false` after it exists removes it from Terraform but leaves it running (and billing) in AWS. Delete it explicitly in the EKS console when you turn Argo CD off.

## Verify readiness

Poll the capability until it is active. `DEGRADED`, `DELETING`, `CREATE_FAILED` and `UPDATE_FAILED` are terminal failures; stop and inspect the capability health details.

```bash
cluster_name="$(terraform -chdir=environments/platform output -raw cluster_name)"
region="${AWS_REGION:?Set AWS_REGION to the platform Terraform region}"
capability_name="${cluster_name}-argocd"

while :; do
  status="$(aws eks describe-capability --region "$region" --cluster-name "$cluster_name" --capability-name "$capability_name" --query 'capability.status' --output text)"
  case "$status" in
    ACTIVE) break ;;
    DEGRADED|DELETING|CREATE_FAILED|UPDATE_FAILED) echo "$capability_name is $status" >&2; exit 1 ;;
    *) echo "$capability_name is $status; waiting"; sleep 15 ;;
  esac
done
```

Then confirm the Argo CD APIs are available before planning the bootstrap:

```bash
kubectl api-resources | grep -E 'Application|ApplicationSet'
```

## Access model and recovery

The Argo CD capability role receives `AmazonEKSClusterAdminPolicy` at cluster scope. It needs this access to install the platform's cluster-scoped CRDs and controllers.

If the capability fails, inspect its health and trust role before retrying:

```bash
aws eks describe-capability --region "$region" --cluster-name "$cluster_name" --capability-name "${cluster_name}-argocd"
aws iam get-role --role-name "${cluster_name}-argocd-capability"
```

Confirm the role trusts only `capabilities.eks.amazonaws.com`, and that its inline policy limits `codeconnections:GetConnection` and `codeconnections:UseConnection` to the Terraform-managed connection ARN. Do not run GitOps operations until the capability is `ACTIVE`.
