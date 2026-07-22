#!/usr/bin/env bash
set -euo pipefail
cluster="${CLUSTER_NAME:-$(terraform -chdir=environments/platform output -raw cluster_name)}"
region="${AWS_REGION:-$(aws configure get region)}"
fail=0; pass() { echo "PASS $1"; }; fail_line() { echo "FAIL $1"; fail=1; }
assert_eq() { [ "$2" = "$3" ] && pass "$1" || fail_line "$1"; }
connection="$(terraform -chdir=environments/platform output -raw github_connection_arn)"
assert_eq "CodeConnections AVAILABLE" "$(aws codeconnections get-connection --connection-arn "$connection" --query 'Connection.ConnectionStatus' --output text)" AVAILABLE
assert_eq "EKS ACTIVE" "$(aws eks describe-cluster --name "$cluster" --region "$region" --query 'cluster.status' --output text)" ACTIVE
if aws eks list-fargate-profiles --cluster-name "$cluster" --region "$region" --query 'fargateProfileNames[]' --output text | xargs -n1 -I{} aws eks describe-fargate-profile --cluster-name "$cluster" --fargate-profile-name {} --region "$region" --query 'fargateProfile.status' --output text | grep -qv '^ACTIVE$'; then fail_line "Fargate profiles ACTIVE"; else pass "Fargate profiles ACTIVE"; fi
assert_eq "No node groups" "$(aws eks list-nodegroups --cluster-name "$cluster" --region "$region" --query 'length(nodegroups)' --output text)" 0
for capability in argocd ack kro; do assert_eq "${capability} capability ACTIVE" "$(aws eks describe-capability --cluster-name "$cluster" --capability-name "${cluster}-${capability}" --region "$region" --query 'capability.status' --output text)" ACTIVE; done
for deployment in 'kube-system coredns' 'kube-system aws-load-balancer-controller' 'argo-rollouts argo-rollouts' 'cert-manager cert-manager' 'cert-manager cert-manager-webhook' 'opentelemetry-operator-system opentelemetry-operator'; do read -r ns name <<<"$deployment"; kubectl -n "$ns" rollout status deployment/"$name" --timeout=5m >/dev/null && pass "Deployment $ns/$name" || fail_line "Deployment $ns/$name"; done
kubectl -n argocd get applications -o json | jq -e '.items | all(.status.sync.status == "Synced" and .status.health.status == "Healthy")' >/dev/null && pass "Argo Applications Synced Healthy" || fail_line "Argo Applications Synced Healthy"
[ "$(kubectl get pods -A -o json | jq '[.items[] | select(.metadata.namespace | startswith("apps-"))] | length')" = 0 ] && pass "No service workloads" || fail_line "No service workloads"
[ "$(kubectl get ingress -A --no-headers 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && pass "No Ingress" || fail_line "No Ingress"
[ "$(kubectl get svc -A -o json | jq '[.items[] | select(.spec.type == "LoadBalancer")] | length')" = 0 ] && pass "No LoadBalancer Service" || fail_line "No LoadBalancer Service"
exit "$fail"
