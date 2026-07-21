# Deploy the Platform

Run `./scripts/verify-prerequisites.sh`, apply and migrate the state bootstrap as documented in `terraform-state.md`, then initialize and apply `environments/platform`. Authorize the CodeConnections GitHub connection, wait for all three EKS capabilities to be `ACTIVE`, then wait for GitOps Applications to be healthy. Run `./scripts/verify-platform.sh` as acceptance.

For a pending connection, complete AWS Console authorization. For a failed capability, inspect `aws eks describe-capability`; for a missing CRD, wait for capability `ACTIVE`; for unschedulable Fargate Pods, correct the namespace selector; for an unhealthy Application, inspect its conditions and Git path.
