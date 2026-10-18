#!/usr/bin/env bash
# OpenTelemetry Collector add-on acceptance, without a cluster.
#
# Renders gitops/platform/config/addons/opentelemetry-collector.yaml through
# scripts/render-collector.sh, then asserts on the rendered manifests (the
# workload shape: namespace, RBAC, pod, token delivery). Exits 1 on any FAIL.
#
# Needs helm, kubectl, yq (mikefarah v4) and kubeconform. Run: make collector-check
set -euo pipefail

cd "$(dirname "$0")/.."

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
./scripts/render-collector.sh "$out" >/dev/null
manifests="$out/manifests.yaml"

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
q() { yq ea "$1" "$manifests"; }

ds='select(.kind == "DaemonSet")'
pod="$ds | .spec.template.spec"
collector="$pod | .containers[] | select(.name == \"opentelemetry-collector\")"
init="$pod | .initContainers[] | select(.name == \"fetch-grafana-cloud\")"

# ------------------------------------------------------------------ workload ---

# The chart suffixes the DaemonSet with -agent; the Service keeps the
# fullnameOverride, otel-collector, which is the name workloads use.
assert_eq "One DaemonSet otel-collector-agent in observability" \
  "$(q '[select(.kind == "DaemonSet" and .metadata.name == "otel-collector-agent" and .metadata.namespace == "observability")] | length')" 1
assert_eq "No Deployment or StatefulSet" "$(q '[select(.kind == "Deployment" or .kind == "StatefulSet")] | length')" 0
assert_eq "No Secret rendered" "$(q '[select(.kind == "Secret")] | length')" 0
assert_eq "Service exposes only 4318" \
  "$(q 'select(.kind == "Service" and .metadata.name == "otel-collector") | [.spec.ports[].port] | join(",")')" 4318
# A hostPort would publish OTLP on the node's public IP.
assert_eq "No hostPort" "$(q '[.. | select(tag == "!!map" and has("hostPort"))] | length')" 0

image="$(q "$collector | .image")"
if [[ "$image" =~ ^otel/opentelemetry-collector-contrib:[0-9][0-9.]*$ ]]; then
  pass "Image is pinned contrib ($image)"
else
  fail_line "Image is pinned contrib (got '$image')"
fi

assert_eq "Resources" \
  "$(q "$collector | [.resources.requests.cpu, .resources.requests.memory, .resources.limits.memory] | join(\",\")")" \
  "100m,128Mi,256Mi"

assert_empty "Hardened containers" "$(q "$pod | (.containers + .initContainers)[] |
  select(.securityContext.runAsUser != 0
    or .securityContext.readOnlyRootFilesystem != true
    or .securityContext.allowPrivilegeEscalation != false
    or ((.securityContext.capabilities.drop // []) | join(\",\")) != \"ALL\") | .name")"

assert_eq "hostPath is only /var/log/pods" \
  "$(q "$pod | [.volumes[] | select(.hostPath) | .hostPath.path] | join(\",\")")" /var/log/pods
assert_empty "hostPath mounts are read-only" "$(q "$pod | [.volumes[] | select(.hostPath) | .name] as \$hp |
  (.containers + .initContainers)[] | .name as \$c | .volumeMounts[] |
  select((.name as \$n | \$hp | contains([\$n])) and .readOnly != true) | \$c + \"/\" + .name")"

assert_eq "Secrets volume is in memory" \
  "$(q "$pod | .volumes[] | select(.name == \"secrets\") | .emptyDir.medium")" Memory
assert_eq "Init mounts /secrets read-write" \
  "$(q "$init | .volumeMounts[] | select(.name == \"secrets\") | .mountPath + \",\" + ((.readOnly // false) | tostring)")" \
  "/secrets,false"
assert_eq "Collector mounts /secrets read-only" \
  "$(q "$collector | .volumeMounts[] | select(.name == \"secrets\") | .mountPath + \",\" + ((.readOnly // false) | tostring)")" \
  "/secrets,true"

init_image="$(q "$init | .image")"
if [[ "$init_image" =~ ^public\.ecr\.aws/aws-cli/aws-cli:[0-9][0-9.]*$ ]]; then
  pass "Init image is pinned AWS CLI ($init_image)"
else
  fail_line "Init image is pinned AWS CLI (got '$init_image')"
fi
init_command="$(q "$init | (.command + (.args // [])) | join(\" \")")"
missing=""
for needle in otlp-token otlp-endpoint instance-id "test -s"; do
  [[ "$init_command" == *"$needle"* ]] || missing="$missing $needle"
done
assert_empty "Init fetches and checks every parameter" "${missing# }"

# ---------------------------------------------------------------------- RBAC ---

assert_eq "ClusterRole verbs are read-only" \
  "$(q '[select(.kind == "ClusterRole") | .rules[].verbs[]] | unique | sort | join(",")')" "get,list,watch"
assert_eq "ClusterRole resources" \
  "$(q '[select(.kind == "ClusterRole") | .rules[].resources[]] | unique | sort | join(",")')" \
  "daemonsets,deployments,jobs,namespaces,nodes,nodes/stats,pods,replicasets,statefulsets"
assert_eq "Lease Role in observability" \
  "$(q 'select(.kind == "Role" and .metadata.namespace == "observability") | .rules[] | (.apiGroups | join(",")) + ";" + (.resources | join(",")) + ";" + (.verbs | sort | join(","))')" \
  "coordination.k8s.io;leases;create,get,list,patch,update,watch"
assert_eq "Lease Role bound to otel-collector" \
  "$(q 'select(.kind == "RoleBinding" and .metadata.namespace == "observability") | .subjects[] | .kind + "/" + .namespace + "/" + .name')" \
  "ServiceAccount/observability/otel-collector"

# ----------------------------------------------------------------- namespace ---

assert_eq "Namespace observability is privileged" \
  "$(q 'select(.kind == "Namespace" and .metadata.name == "observability") | .metadata.labels | [.["pod-security.kubernetes.io/enforce"], .["pod-security.kubernetes.io/audit"], .["pod-security.kubernetes.io/warn"]] | join(",")')" \
  "privileged,privileged,privileged"
assert_eq "No NetworkPolicy" "$(q '[select(.kind == "NetworkPolicy")] | length')" 0

if kubeconform -strict -summary -ignore-missing-schemas "$manifests" >/dev/null; then
  pass "kubeconform"
else
  fail_line "kubeconform"
fi

exit "$fail"
