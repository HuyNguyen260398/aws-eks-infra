# Fargate Telemetry Validation

Apply the platform Terraform configuration only after all managed EKS capabilities report `ACTIVE`. Then wait for Argo CD to reconcile the `platform-observability` Application and run:

```bash
kubectl kustomize gitops/platform/config/observability | kubeconform -strict -summary -ignore-missing-schemas
kubectl -n opentelemetry-operator-system get deployment
kubectl -n aws-observability get configmap aws-logging
kubectl -n amazon-cloudwatch get serviceaccount adot-collector -o yaml
```

Confirm that the `aws-logging` ConfigMap has a CloudWatch Logs output for the Terraform-managed Fargate log group, with `auto_create_group false`. Confirm that `adot-collector` has the expected `eks.amazonaws.com/role-arn` annotation and that the ADOT operator Deployment is available.

No application-specific OpenTelemetryCollector is deployed by this platform plan.
