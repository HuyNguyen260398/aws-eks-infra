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

Workloads must use `apps-*` namespaces (Fargate capacity), Fargate-compatible
security contexts, and ALB IP targets. Jenkins (`apps-jenkins`) is the first
example — see `docs/operations/deploy-jenkins.md`.
