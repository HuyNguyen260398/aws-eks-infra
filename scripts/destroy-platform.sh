#!/usr/bin/env bash
# Destroy the platform. See docs/operations/destroy-platform.md.
#
# By default this destroys the two cluster modules and PRESERVES the account
# level resources in the root - the CodeConnections connection and the Identity
# Center group. Destroying the connection forces a manual GitHub App
# reauthorization in the console before the next deploy, which cannot be
# automated. Set DESTROY_ROOT=true to remove them as well.
#
# Never touches bootstrap/terraform-state.
set -euo pipefail

ROOT=environments/platform
DESTROY_ROOT="${DESTROY_ROOT:-false}"

[ "${1:-}" = "destroy platform" ] || {
  echo 'Refusing: pass the literal argument "destroy platform".' >&2
  exit 2
}

refuse() {
  echo "Refusing: $1" >&2
  exit 1
}

# Only enforce the in-cluster guards while the cluster still exists. A partially
# destroyed platform must stay destroyable, but a stale kubeconfig must not be
# mistaken for "no workloads".
cluster_in_state=$(
  terraform -chdir="$ROOT" state list 2>/dev/null |
    grep -c 'module\.platform_cluster\.module\.eks\.aws_eks_cluster' || true
)

if [ "$cluster_in_state" != 0 ]; then
  kubectl -n argocd get applications -o json >/dev/null 2>&1 ||
    refuse "the EKS cluster is still in state but kubectl cannot reach it.
  Fix your kubeconfig (docs/operations/cluster-access.md) so the workload guards
  can run, or remove the cluster from state deliberately."

  # An Application declares either a single .spec.source or, for multi-source
  # Applications, a .spec.sources array. Checking only .spec.source.path leaves
  # .spec.source null for a multi-source workload such as Jenkins, so the guard
  # passes while the workload is live - and its controller-created ALB then
  # survives into the VPC destroy and blocks it.
  workload_apps=$(
    kubectl -n argocd get applications -o json | jq -r '
      .items[]
      | select(
          ([ .spec.source?.path? ] + [ (.spec.sources // [])[]?.path? ])
          | map(select(type == "string"))
          | any(startswith("gitops/workloads"))
        )
      | .metadata.name
    '
  )
  [ -z "$workload_apps" ] || refuse "workload Applications exist:
    ${workload_apps//$'\n'/$'\n'    }
  Delete them and let Argo CD prune their resources first."

  # Ingresses and LoadBalancer Services are backed by load balancers that the
  # aws-load-balancer-controller creates. Terraform has no record of them, so
  # destroying the cluster first orphans them, and the leftover ENIs and
  # security groups then fail the VPC destroy. Their finalizers only release the
  # AWS resources while the controller is still running.
  ingresses=$(
    kubectl get ingress -A -o json 2>/dev/null |
      jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"'
  )
  [ -z "$ingresses" ] || refuse "Ingress objects still exist:
    ${ingresses//$'\n'/$'\n'    }
  Delete them and wait for their load balancers to disappear first."

  lb_services=$(
    kubectl get svc -A -o json 2>/dev/null |
      jq -r '.items[] | select(.spec.type == "LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"'
  )
  [ -z "$lb_services" ] || refuse "LoadBalancer Services still exist:
    ${lb_services//$'\n'/$'\n'    }
  Delete them and wait for their load balancers to disappear first."
fi

plan_dir="$(mktemp -d)"
trap 'rm -rf "$plan_dir"' EXIT
plan="$plan_dir/platform-destroy.tfplan"

# The bootstrap module goes first: its kubernetes provider is configured from the
# cluster endpoint, so it cannot be planned once the cluster is gone.
terraform -chdir="$ROOT" destroy \
  -target=module.platform_cluster_bootstrap -input=false

if [ "$DESTROY_ROOT" = true ]; then
  echo "DESTROY_ROOT=true - the CodeConnections connection and Identity Center group will also be destroyed."
  terraform -chdir="$ROOT" plan -destroy -out="$plan" -input=false
else
  echo "Preserving the CodeConnections connection and Identity Center group (DESTROY_ROOT=true to remove them)."
  terraform -chdir="$ROOT" plan -destroy \
    -target=module.platform_cluster -out="$plan" -input=false
fi

terraform -chdir="$ROOT" apply "$plan"
