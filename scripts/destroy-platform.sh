#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "destroy platform" ] || { echo 'Refusing: pass the literal argument "destroy platform".' >&2; exit 2; }
kubectl -n argocd get applications -o json | jq -e '[.items[] | select(.spec.source.path == "gitops/workloads")] | length == 0' >/dev/null || { echo "Refusing: workload Applications exist." >&2; exit 1; }
terraform -chdir=environments/platform destroy -target=module.platform_cluster_bootstrap -input=false
terraform -chdir=environments/platform plan -destroy -out=/tmp/platform-destroy.tfplan -input=false
terraform -chdir=environments/platform apply /tmp/platform-destroy.tfplan
