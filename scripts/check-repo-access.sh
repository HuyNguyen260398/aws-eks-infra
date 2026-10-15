#!/usr/bin/env bash
# Prove managed Argo CD can read a repository through the platform's
# CodeConnections connection, without deploying anything from it.
#
# Usage: scripts/check-repo-access.sh <owner> <repo> <revision> <path>
#
# Creates a throwaway Application with no sync policy, waits for Argo CD to
# compare it, and prints PASS or FAIL. Nothing is ever synced from the
# repository; the Application is deleted on exit. Pick a <path> that holds no
# Kubernetes manifests (a docs directory) so the comparison has nothing to
# render. Exits 0 on PASS, 1 on FAIL, 2 on usage errors.
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <owner> <repo> <revision> <path>" >&2
  exit 2
fi
owner="$1"
repo="$2"
revision="$3"
path="$4"

region="${AWS_REGION:-$(aws configure get region)}"
prefix="$(terraform -chdir=environments/platform output -raw platform_parameter_prefix)"
base="$(aws ssm get-parameter --name "${prefix}/codeconnections-git-http-base" --region "$region" --query 'Parameter.Value' --output text)"
cluster_arn="$(terraform -chdir=environments/platform output -raw cluster_arn)"
name="repo-access-check-$(date +%s)"

trap 'kubectl -n argocd delete application "$name" --ignore-not-found --wait=false >/dev/null' EXIT

kubectl apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${name}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${base}/${owner}/${repo}.git
    targetRevision: ${revision}
    path: ${path}
  destination:
    server: ${cluster_arn}
    namespace: default
EOF

for _ in $(seq 1 30); do
  app="$(kubectl -n argocd get application "$name" -o json)"
  errors="$(jq -r '[.status.conditions[]? | select(.type | endswith("Error")) | .message] | join("; ")' <<<"$app")"
  resolved="$(jq -r '.status.sync.revision // empty' <<<"$app")"
  if [ -n "$errors" ]; then
    echo "FAIL ${owner}/${repo}@${revision}: ${errors}"
    exit 1
  fi
  if [ -n "$resolved" ]; then
    echo "PASS ${owner}/${repo}@${revision} resolved to ${resolved}"
    exit 0
  fi
  sleep 10
done

echo "FAIL ${owner}/${repo}@${revision}: Argo CD did not compare the Application within 5 minutes"
exit 1
