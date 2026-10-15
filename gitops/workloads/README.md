# Workloads

Workloads reconciled by Argo CD from this repository. Cashight itself is
deployed from its own repository (its Argo CD Application is added with the
Cashight deployment plan).

## Layout

- `manifests/` — plain-manifest or Kustomize workloads, recursed by the
  `platform-workloads` ApplicationSet (`gitops/platform/bootstrap/config-workloads.yaml`).
  Empty today.

## Contract

Workloads run in a tenant namespace declared in
`gitops/platform/config/namespaces/values.yaml`: Pod Security `restricted`,
default-deny ingress and egress NetworkPolicies that the workload must open
itself, and a LimitRange and ResourceQuota sized for the single node.
