# AWS Observability

The `platform` root provisions a customer-managed KMS key and four CloudWatch Logs groups for EKS control-plane logs, Fargate application logs, Container Insights, and VPC Flow Logs. Each group retains logs for 30 days. The KMS policy permits only the account root and the regional CloudWatch Logs service, constrained to this platform's EKS and VPC Flow Log encryption contexts.

Terraform also enables EKS API, audit, authenticator, controller-manager, and scheduler logging, and publishes all VPC traffic to CloudWatch Logs at a one-minute aggregation interval. The ADOT collector service account must be named `adot-collector` in the `amazon-cloudwatch` namespace so that it can assume the Terraform-managed IRSA role.

Terraform does **not** install the `adot` EKS add-on. That add-on hard-requires cert-manager, which is a Kubernetes controller and therefore belongs to Argo CD under the ownership boundary. Wiring Terraform to wait for a GitOps-installed dependency would make the apply order circular. Argo CD installs cert-manager and then the OpenTelemetry operator from `gitops/platform/config/addons/`; Terraform owns only the ADOT IRSA role that the collector service account assumes.

## Prerequisites

- The platform Terraform root has been applied with valid AWS credentials and remote state configuration.
- AWS CLI v2 and Terraform are installed.
- The AWS CLI principal can describe EKS, CloudWatch Logs, and VPC Flow Logs resources.

## Verify after apply

Set the cluster name, VPC ID, and expected KMS key ARN from the applied platform configuration:

```bash
OBSERVABILITY_KMS_KEY_ARN="<observability-kms-key-arn>"
CLUSTER_NAME="<cluster-name>"
VPC_ID="<vpc-id>"
```

Confirm that every log group uses the expected KMS key:

```bash
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/eks/${CLUSTER_NAME}" \
  --query "logGroups[].{name:logGroupName,kmsKeyId:kmsKeyId,retention:retentionInDays}"
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/vpc-flow-logs/${CLUSTER_NAME}" \
  --query "logGroups[].{name:logGroupName,kmsKeyId:kmsKeyId,retention:retentionInDays}"
```

Each result must report the configured KMS key ARN and `30` days of retention. Verify Flow Logs and EKS control-plane logging:

```bash
aws ec2 describe-flow-logs \
  --filter "Name=resource-id,Values=${VPC_ID}" \
  --query "FlowLogs[].{id:FlowLogId,status:FlowLogStatus,traffic:TrafficType,interval:MaxAggregationInterval}"
aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --query "cluster.logging.clusterLogging[?enabled].types[]"
```

The Flow Log status must be `ACTIVE`, traffic type must be `ALL`, and aggregation interval must be `60`. The enabled EKS types must include `api`, `audit`, `authenticator`, `controllerManager`, and `scheduler`.

The OpenTelemetry operator is verified in the cluster rather than through the add-on API:

```bash
kubectl -n cert-manager rollout status deployment/cert-manager-webhook
kubectl -n opentelemetry-operator-system rollout status deployment/opentelemetry-operator
```

Do not install `amazon-cloudwatch-observability` or Network Flow Monitor agent add-ons. They are not supported on this Fargate-only platform. Configure the in-cluster ADOT collector and Fargate log-routing ConfigMap through GitOps; Terraform owns only the AWS resources in this document.
