#!/usr/bin/env bash
# Platform acceptance. See docs/operations/validate-platform.md.
#
# Two groups of assertions:
#
#   Platform invariants  always checked. Fargate only, capabilities ACTIVE,
#                        controllers rolled out, Applications converged.
#   Greenfield non-goals only meaningful before any workload is deployed - no
#                        apps-* Pods, no Ingress, no LoadBalancer Service.
#
# The non-goals were unconditional, so the script reported FAIL the moment a
# workload it was supposed to host actually ran. Set EXPECT_WORKLOADS=true once
# the platform hosts workloads; the non-goal assertions are then replaced by
# checks that workloads stay inside the Fargate namespace contract.
set -euo pipefail

cluster="${CLUSTER_NAME:-$(terraform -chdir=environments/platform output -raw cluster_name)}"
region="${AWS_REGION:-$(aws configure get region)}"
EXPECT_WORKLOADS="${EXPECT_WORKLOADS:-false}"

fail=0
pass() { echo "PASS $1"; }
fail_line() {
  echo "FAIL $1"
  fail=1
}
assert_eq() { [ "$2" = "$3" ] && pass "$1" || fail_line "$1"; }

# ---------------------------------------------------------------- platform ---

connection="$(terraform -chdir=environments/platform output -raw github_connection_arn)"
assert_eq "CodeConnections AVAILABLE" "$(aws codeconnections get-connection --connection-arn "$connection" --query 'Connection.ConnectionStatus' --output text)" AVAILABLE
assert_eq "EKS ACTIVE" "$(aws eks describe-cluster --name "$cluster" --region "$region" --query 'cluster.status' --output text)" ACTIVE
if aws eks list-fargate-profiles --cluster-name "$cluster" --region "$region" --query 'fargateProfileNames[]' --output text | xargs -n1 -I{} aws eks describe-fargate-profile --cluster-name "$cluster" --fargate-profile-name {} --region "$region" --query 'fargateProfile.status' --output text | grep -qv '^ACTIVE$'; then fail_line "Fargate profiles ACTIVE"; else pass "Fargate profiles ACTIVE"; fi
assert_eq "No node groups" "$(aws eks list-nodegroups --cluster-name "$cluster" --region "$region" --query 'length(nodegroups)' --output text)" 0

# A node group is not the only way EC2 capacity can appear. Assert the compute
# type directly: every node that exists must be Fargate.
non_fargate="$(
  kubectl get nodes -o json |
    jq -r '.items[] | select(.metadata.labels["eks.amazonaws.com/compute-type"] != "fargate") | .metadata.name'
)"
[ -z "$non_fargate" ] && pass "All nodes Fargate" || fail_line "All nodes Fargate ($(echo "$non_fargate" | tr '\n' ' '))"

for capability in argocd ack kro; do assert_eq "${capability} capability ACTIVE" "$(aws eks describe-capability --cluster-name "$cluster" --capability-name "${cluster}-${capability}" --region "$region" --query 'capability.status' --output text)" ACTIVE; done
for deployment in 'kube-system coredns' 'kube-system aws-load-balancer-controller' 'argo-rollouts argo-rollouts' 'cert-manager cert-manager' 'cert-manager cert-manager-webhook' 'opentelemetry-operator-system opentelemetry-operator'; do read -r ns name <<<"$deployment"; kubectl -n "$ns" rollout status deployment/"$name" --timeout=5m >/dev/null && pass "Deployment $ns/$name" || fail_line "Deployment $ns/$name"; done

# `all` on an empty array is vacuously true, so an empty argocd namespace used to
# pass this. Require at least one Application as well.
apps_json="$(kubectl -n argocd get applications -o json)"
app_count="$(printf '%s' "$apps_json" | jq '.items | length')"
if [ "$app_count" = 0 ]; then
  fail_line "Argo Applications Synced Healthy (none exist)"
elif printf '%s' "$apps_json" | jq -e '.items | all(.status.sync.status == "Synced" and .status.health.status == "Healthy")' >/dev/null; then
  pass "Argo Applications Synced Healthy ($app_count)"
else
  fail_line "Argo Applications Synced Healthy"
  printf '%s' "$apps_json" | jq -r '
    .items[]
    | select((.status.sync.status != "Synced") or (.status.health.status != "Healthy"))
    | "    \(.metadata.name): \(.status.sync.status // "?")/\(.status.health.status // "?")"
  '
fi

# --------------------------------------------------------------- workloads ---

# Namespaces a Fargate profile selects, per modules/platform_cluster/eks.tf.
platform_namespaces='^(kube-system|argo-rollouts|cert-manager|opentelemetry-operator-system|amazon-cloudwatch|argocd|kube-public|kube-node-lease|default)$'

if [ "$EXPECT_WORKLOADS" = true ]; then
  # Workloads are allowed. Assert they respect the namespace contract and are
  # actually running, rather than asserting they do not exist.
  stray="$(
    kubectl get pods -A -o json |
      jq -r --arg re "$platform_namespaces" '
        .items[]
        | select((.metadata.namespace | test($re)) | not)
        | select((.metadata.namespace | startswith("apps-")) | not)
        | "\(.metadata.namespace)/\(.metadata.name)"
      '
  )"
  [ -z "$stray" ] && pass "Workload Pods confined to apps-*" || fail_line "Workload Pods confined to apps-* ($(echo "$stray" | tr '\n' ' '))"

  unhealthy="$(
    kubectl get pods -A -o json |
      jq -r '
        .items[]
        | select(.metadata.namespace | startswith("apps-"))
        | select(.status.phase != "Running" and .status.phase != "Succeeded")
        | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"
      '
  )"
  [ -z "$unhealthy" ] && pass "Workload Pods Running" || fail_line "Workload Pods Running ($(echo "$unhealthy" | tr '\n' ' '))"

  # Every Ingress must have been reconciled into a load balancer address.
  pending="$(
    kubectl get ingress -A -o json |
      jq -r '.items[] | select((.status.loadBalancer.ingress // []) | length == 0) | "\(.metadata.namespace)/\(.metadata.name)"'
  )"
  [ -z "$pending" ] && pass "Ingresses have load balancer addresses" || fail_line "Ingresses have load balancer addresses ($(echo "$pending" | tr '\n' ' '))"
else
  # Greenfield non-goals: nothing is hosted yet.
  assert_eq "No service workloads" "$(kubectl get pods -A -o json | jq '[.items[] | select(.metadata.namespace | startswith("apps-"))] | length')" 0
  assert_eq "No Ingress" "$(kubectl get ingress -A -o json | jq '.items | length')" 0
  assert_eq "No LoadBalancer Service" "$(kubectl get svc -A -o json | jq '[.items[] | select(.spec.type == "LoadBalancer")] | length')" 0
fi

exit "$fail"
