#!/usr/bin/env bash
# Platform acceptance. See docs/operations/validate-platform.md.
#
# Two groups of assertions:
#
#   Platform invariants  always checked. Capacity (Fargate profiles and the
#                        general EC2 node group), add-ons, capabilities ACTIVE,
#                        controllers rolled out, Applications converged, tenant
#                        namespaces guarded, identifiers published.
#   Greenfield non-goals only meaningful before any workload is deployed - no
#                        workload Pods, no Ingress, no LoadBalancer Service.
#
# Set EXPECT_WORKLOADS=true once the platform hosts workloads; the non-goal
# assertions are then replaced by checks that workloads stay inside their
# namespace contract. EXPECTED_NODES is the node group size (default 3), and
# WORKLOAD_NAMESPACES lists the tenant namespaces declared in
# gitops/platform/config/namespaces/values.yaml (default "cashight").
set -euo pipefail

cluster="${CLUSTER_NAME:-$(terraform -chdir=environments/platform output -raw cluster_name)}"
region="${AWS_REGION:-$(aws configure get region)}"
parameter_prefix="${PARAMETER_PREFIX:-$(terraform -chdir=environments/platform output -raw platform_parameter_prefix)}"
EXPECT_WORKLOADS="${EXPECT_WORKLOADS:-false}"
EXPECTED_NODES="${EXPECTED_NODES:-3}"
read -r -a workload_namespaces <<<"${WORKLOAD_NAMESPACES:-cashight}"
nodegroup="${cluster}-general"

fail=0
pass() { echo "PASS $1"; }
fail_line() {
  echo "FAIL $1"
  fail=1
}
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail_line "$1 (got '$2', want '$3')"; fi
}
# $2 is a newline-separated list that must be empty; offenders are named.
assert_empty() {
  if [ -z "$2" ]; then pass "$1"; else fail_line "$1 ($(echo "$2" | tr '\n' ' '))"; fi
}

# ---------------------------------------------------------------- platform ---

connection="$(terraform -chdir=environments/platform output -raw github_connection_arn)"
assert_eq "CodeConnections AVAILABLE" "$(aws codeconnections get-connection --connection-arn "$connection" --query 'Connection.ConnectionStatus' --output text)" AVAILABLE
assert_eq "EKS ACTIVE" "$(aws eks describe-cluster --name "$cluster" --region "$region" --query 'cluster.status' --output text)" ACTIVE
if aws eks list-fargate-profiles --cluster-name "$cluster" --region "$region" --query 'fargateProfileNames[]' --output text | xargs -n1 -I{} aws eks describe-fargate-profile --cluster-name "$cluster" --fargate-profile-name {} --region "$region" --query 'fargateProfile.status' --output text | grep -qv '^ACTIVE$'; then fail_line "Fargate profiles ACTIVE"; else pass "Fargate profiles ACTIVE"; fi

# --- EC2 capacity. Fargate nodes come and go with their Pods; EC2 nodes are
# exactly the general node group, Graviton, one per AZ.
assert_eq "Node group ${nodegroup} ACTIVE" "$(aws eks describe-nodegroup --cluster-name "$cluster" --nodegroup-name "$nodegroup" --region "$region" --query 'nodegroup.status' --output text)" ACTIVE
ec2_nodes="$(kubectl get nodes -o json | jq '[.items[] | select(.metadata.labels["eks.amazonaws.com/compute-type"] != "fargate")]')"
assert_eq "EC2 nodes Ready" "$(jq '[.[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' <<<"$ec2_nodes")" "$EXPECTED_NODES"
expected_zones=$((EXPECTED_NODES < 3 ? EXPECTED_NODES : 3))
assert_eq "EC2 nodes span ${expected_zones} AZs" "$(jq '[.[].metadata.labels["topology.kubernetes.io/zone"]] | unique | length' <<<"$ec2_nodes")" "$expected_zones"
assert_empty "EC2 nodes are arm64 members of ${nodegroup}" "$(jq -r --arg ng "$nodegroup" '.[] | select(.metadata.labels["kubernetes.io/arch"] != "arm64" or .metadata.labels["eks.amazonaws.com/nodegroup"] != $ng) | .metadata.name' <<<"$ec2_nodes")"

# --- Add-ons. Without enableNetworkPolicy the VPC CNI accepts NetworkPolicy
# objects and silently enforces none of them.
for addon in vpc-cni kube-proxy eks-pod-identity-agent coredns aws-ebs-csi-driver; do
  assert_eq "Add-on ${addon} ACTIVE" "$(aws eks describe-addon --cluster-name "$cluster" --addon-name "$addon" --region "$region" --query 'addon.status' --output text)" ACTIVE
done
assert_eq "VPC CNI enforces NetworkPolicy" "$(aws eks describe-addon --cluster-name "$cluster" --addon-name vpc-cni --region "$region" --query 'addon.configurationValues' --output text | jq -r '.enableNetworkPolicy // "unset"')" true

for capability in argocd ack kro; do assert_eq "${capability} capability ACTIVE" "$(aws eks describe-capability --cluster-name "$cluster" --capability-name "${cluster}-${capability}" --region "$region" --query 'capability.status' --output text)" ACTIVE; done
for deployment in 'kube-system coredns' 'kube-system aws-load-balancer-controller' 'kube-system ebs-csi-controller' 'argo-rollouts argo-rollouts' 'cert-manager cert-manager' 'cert-manager cert-manager-webhook' 'opentelemetry-operator-system opentelemetry-operator' 'keda keda-operator' 'keda keda-operator-metrics-apiserver' 'keda keda-admission-webhooks'; do
  read -r ns name <<<"$deployment"
  if kubectl -n "$ns" rollout status deployment/"$name" --timeout=5m >/dev/null; then
    pass "Deployment $ns/$name"
  else
    fail_line "Deployment $ns/$name"
  fi
done

# Pod Identity does not work on Fargate. These Pods must be on EC2 nodes, or
# they start without AWS credentials.
misplaced="$(
  kubectl get pods -A -o json |
    jq -r '
      .items[]
      | select(.metadata.namespace == "keda" or (.metadata.namespace == "kube-system" and (.metadata.labels.app // "") == "ebs-csi-controller"))
      | select((.spec.nodeName // "") | startswith("fargate-"))
      | "\(.metadata.namespace)/\(.metadata.name)"
    '
)"
assert_empty "Pod Identity consumers run on EC2" "$misplaced"

assert_eq "KEDA external metrics APIService Available" "$(kubectl get apiservice v1beta1.external.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" True
assert_eq "Default StorageClass is gp3" "$(kubectl get storageclass -o json | jq -r '[.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name] | join(",")')" gp3

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

# --- Tenant namespaces: restricted Pod Security, default-deny, a quota.
for ns in "${workload_namespaces[@]}"; do
  assert_eq "Namespace ${ns} enforces restricted Pod Security" "$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || true)" restricted
  policies=" $(kubectl -n "$ns" get networkpolicy -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true) "
  for policy in tenant-ingress-deny-all tenant-egress-deny-all tenant-egress-allow-dns; do
    if [[ "$policies" == *" ${policy} "* ]]; then pass "NetworkPolicy ${ns}/${policy}"; else fail_line "NetworkPolicy ${ns}/${policy}"; fi
  done
  assert_eq "ResourceQuota in ${ns}" "$(kubectl -n "$ns" get resourcequota -o json 2>/dev/null | jq '.items | length')" 1
done

# --- Identifiers published for workload repositories.
for parameter in cluster-name alb-group-name keda-operator-role-arn codeconnections-git-http-base; do
  value="$(aws ssm get-parameter --name "${parameter_prefix}/${parameter}" --region "$region" --query 'Parameter.Value' --output text 2>/dev/null || true)"
  if [ -n "$value" ] && [ "$value" != None ]; then pass "SSM ${parameter_prefix}/${parameter}"; else fail_line "SSM ${parameter_prefix}/${parameter}"; fi
done
assert_eq "Published cluster-name matches" "$(aws ssm get-parameter --name "${parameter_prefix}/cluster-name" --region "$region" --query 'Parameter.Value' --output text 2>/dev/null || true)" "$cluster"

# --------------------------------------------------------------- workloads ---

# Namespaces the platform itself runs in.
platform_namespaces='^(kube-system|argo-rollouts|cert-manager|opentelemetry-operator-system|amazon-cloudwatch|keda|argocd|kube-public|kube-node-lease|default)$'
tenants_json="$(printf '%s\n' "${workload_namespaces[@]}" | jq -R . | jq -s .)"
# A workload Pod lives in an apps-* namespace (Fargate) or a tenant namespace (EC2).
workload_filter="(.metadata.namespace | startswith(\"apps-\")) or (.metadata.namespace as \$ns | \$tenants | index(\$ns) != null)"

if [ "$EXPECT_WORKLOADS" = true ]; then
  # Workloads are allowed. Assert they respect the namespace contract and are
  # actually running, rather than asserting they do not exist.
  stray="$(
    kubectl get pods -A -o json |
      jq -r --arg re "$platform_namespaces" --argjson tenants "$tenants_json" "
        .items[]
        | select((.metadata.namespace | test(\$re)) | not)
        | select(($workload_filter) | not)
        | \"\(.metadata.namespace)/\(.metadata.name)\"
      "
  )"
  assert_empty "Workload Pods confined to apps-* and tenant namespaces" "$stray"

  unhealthy="$(
    kubectl get pods -A -o json |
      jq -r --argjson tenants "$tenants_json" "
        .items[]
        | select($workload_filter)
        | select(.status.phase != \"Running\" and .status.phase != \"Succeeded\")
        | \"\(.metadata.namespace)/\(.metadata.name) \(.status.phase)\"
      "
  )"
  assert_empty "Workload Pods Running" "$unhealthy"

  # Every Ingress must have been reconciled into a load balancer address.
  pending="$(
    kubectl get ingress -A -o json |
      jq -r '.items[] | select((.status.loadBalancer.ingress // []) | length == 0) | "\(.metadata.namespace)/\(.metadata.name)"'
  )"
  assert_empty "Ingresses have load balancer addresses" "$pending"
else
  # Greenfield non-goals: nothing is hosted yet.
  assert_eq "No service workloads" "$(kubectl get pods -A -o json | jq --argjson tenants "$tenants_json" "[.items[] | select($workload_filter)] | length")" 0
  assert_eq "No Ingress" "$(kubectl get ingress -A -o json | jq '.items | length')" 0
  assert_eq "No LoadBalancer Service" "$(kubectl get svc -A -o json | jq '[.items[] | select(.spec.type == "LoadBalancer")] | length')" 0
fi

exit "$fail"
