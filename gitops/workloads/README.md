# Workloads

Example and tenant workloads reconciled by Argo CD.

## Layout

- `manifests/` — plain-manifest or Kustomize workloads, recursed by the
  `platform-workloads` ApplicationSet (`gitops/platform/bootstrap/config-workloads.yaml`).
- `charts/` — local Helm charts for workloads (for example `jenkins-storage`).
- `config/charts/` — ApplicationSets that deploy Helm-chart workloads, reconciled
  by the `platform-workload-charts` ApplicationSet
  (`gitops/platform/bootstrap/config-workload-charts.yaml`).

## Contract

Workloads either use `apps-*` namespaces (Fargate capacity, Fargate-compatible
security contexts, ALB IP targets — Jenkins in `apps-jenkins` is the example,
see `docs/operations/deploy-jenkins.md`), or a tenant namespace declared in
`gitops/platform/config/namespaces/values.yaml` (EC2 capacity, Pod Security
`restricted`, default-deny NetworkPolicies the workload must open itself).
