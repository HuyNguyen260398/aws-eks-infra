# Jenkins Workload Design

## Purpose

Deploy Jenkins as the first example **workload** on the Fargate-only EKS platform, using the upstream `jenkins/jenkins` Helm chart driven by Argo CD. Jenkins persists its state on Amazon EFS, is reached through an internal Application Load Balancer, and runs its builds on dynamic Fargate agent pods. The work respects the repository's central ownership boundary: Terraform owns AWS resources, Argo CD owns every Kubernetes object under `gitops/`.

This is a proof-of-service example, not a hardened production CI system. It deliberately keeps namespace governance (NetworkPolicy, ResourceQuota) and TLS termination out of scope, noting them as documented follow-ups.

## Scope

In scope:

- Amazon EFS filesystem, access point, security group, and mount targets in Terraform.
- Terraform → Argo CD handoff of the EFS identifiers via cluster-Secret annotations.
- A local `jenkins-storage` Helm chart that renders the `StorageClass`, static `PersistentVolume`, and `PersistentVolumeClaim`.
- A new workload-charts bootstrap ApplicationSet and a Jenkins ApplicationSet that renders a two-source Argo CD Application (upstream Jenkins chart + local storage chart).
- Jenkins chart values / JCasC for internal ALB ingress and dynamic Fargate agents.
- An operations runbook and passing `make yaml-check` / `make terraform-check` gates.

Out of scope (documented follow-ups):

- NetworkPolicy / ResourceQuota governance for `apps-jenkins` (keep the first workload simple).
- TLS termination on the ALB via ACM.
- Jenkins controller IRSA for AWS API access from pipelines.
- Dynamic EFS provisioning and the EFS CSI controller add-on.

## Namespace and Fargate placement

Jenkins runs in the **`apps-jenkins`** namespace — both the controller and the ephemeral agent pods. This namespace matches the existing `apps-*` selector on the `future_workloads` Fargate profile in `modules/platform_cluster/eks.tf`, so **no Fargate profile change is required**. This is the one exception to the "add the namespace to a Fargate profile selector" rule in `CLAUDE.md`, because the wildcard selector already covers it; the design notes this explicitly so the invariant is not silently bypassed.

The namespace is created by Argo CD via the `CreateNamespace=true` sync option on the Jenkins Application.

## Storage

Jenkins is stateful: `JENKINS_HOME` holds jobs, plugins, credentials, and build history. On Fargate, EBS is unavailable, so persistence uses Amazon EFS with **static provisioning and no CSI driver installed** — AWS Fargate mounts `efs.csi.aws.com` volumes natively, and the EFS CSI node DaemonSet cannot run on Fargate in any case. This keeps zero new platform controllers.

### Terraform (`modules/platform_cluster/efs.tf`)

- A dedicated, encrypted `aws_efs_file_system` (its own `aws_kms_key`, not the observability key), lifecycle-guarded so the filesystem is not destroyed casually.
- An `aws_security_group` allowing inbound NFS (TCP 2049) from the EKS cluster primary security group, so Fargate pod ENIs can reach the filesystem.
- One `aws_efs_mount_target` per private subnet for per-AZ redundancy.
- An `aws_efs_access_point` for Jenkins: POSIX `uid`/`gid` `1000`, root directory `/jenkins-home` created with owner `1000:1000` and mode `0755`.
- Outputs `efs_file_system_id` and `jenkins_efs_access_point_id`.

The filesystem is modeled as a shared "platform apps" EFS so future workloads can add their own access points; only the Jenkins access point is created now.

### Local `jenkins-storage` Helm chart (`gitops/workloads/charts/jenkins-storage`)

A minimal chart with no dependencies that renders, in the `apps-jenkins` namespace:

- A `StorageClass` `efs-sc` with provisioner `efs.csi.aws.com` (referenced by the PV; no dynamic parameters).
- A static `PersistentVolume` `jenkins-home-pv` — capacity nominal (EFS is elastic), `ReadWriteMany`, reclaim policy `Retain`, `csi.driver: efs.csi.aws.com`, `volumeHandle: "<fs-id>::<ap-id>"`.
- A `PersistentVolumeClaim` `jenkins-home` bound to that PV (`storageClassName: efs-sc`, matching size/access mode).

The account-specific `fileSystemId` and `accessPointId` arrive as Helm values, so nothing account-specific is hardcoded in YAML. The chart ships a `values.yaml` (defaults + placeholders) and a `values-test.yaml` for `helm lint`/`template` in CI.

## Terraform → Argo CD handoff

Following the established mechanism: add variables, surface them as cluster-Secret annotations, and reference them as `{{ .metadata.annotations.* }}` in an ApplicationSet template.

- Add `efs_file_system_id` and `jenkins_efs_access_point_id` variables to `modules/platform_cluster_bootstrap`, threaded from `modules/platform_cluster` outputs through `environments/platform`.
- Surface both as annotations on the Argo CD cluster `Secret` in `modules/platform_cluster_bootstrap/kubernetes.tf`.

No new Terraform root is created, so the duplicated `TF_ROOTS` / CI `roots` arrays do **not** change. The new `efs.tf` is validated by the existing `modules/platform_cluster` root.

## Deployment wiring (GitOps fan-out)

The repository uses a two-level "app of ApplicationSets": a `config-*` ApplicationSet renders a per-cluster Application that syncs a kustomize directory of further ApplicationSets, each a cluster generator that interpolates annotations into Helm values. Jenkins follows this pattern on the workload side.

- **`gitops/platform/bootstrap/config-workload-charts.yaml`** — a new ApplicationSet (cluster generator, `workload_cluster: "true"` selector) that renders a per-cluster Application syncing `gitops/workloads/charts` (`directory.recurse`).
- **`gitops/workloads/charts/kustomization.yaml`** — lists `jenkins.yaml`.
- **`gitops/workloads/charts/jenkins.yaml`** — a cluster-generator ApplicationSet that renders a **two-source** Argo CD Application:
  - **Source 1 — upstream Jenkins:** `repoURL: https://charts.jenkins.io`, `chart: jenkins`, pinned `targetRevision` (exact version confirmed at implementation), `releaseName: jenkins` (pinned so object names stay deterministic), with inline Helm values for ingress, JCasC, agents, and `persistence.existingClaim`.
  - **Source 2 — local storage chart:** `repoURL: {{ .metadata.annotations.gitops_repo_url }}`, `path: gitops/workloads/charts/jenkins-storage`, `targetRevision: {{ .metadata.annotations.gitops_revision }}`, with `helm.values` injecting `fileSystemId` / `accessPointId` from annotations.
  - `destination.namespace: apps-jenkins`, `syncPolicy.automated` with `CreateNamespace=true` and `ServerSideApply=true`.

The two-source shape keeps the upstream chart pulled directly from its repo (no Helm subchart dependency resolution) while still feeding both charts account-specific values through Helm values only.

The existing `platform-workloads` ApplicationSet (`config-workloads.yaml`, `directory.recurse` over `gitops/workloads`) renders plain manifests and must not pick up the Helm chart directories; `gitops/workloads/charts/**` contains only ApplicationSet manifests and Helm charts, and the plan verifies the two ApplicationSets do not both act on the same objects.

## Jenkins configuration (chart values / JCasC)

- **Ingress:** internal ALB via `aws-load-balancer-controller` — `controller.ingress.enabled: true`, `ingressClassName: alb`, annotations `alb.ingress.kubernetes.io/scheme: internal`, `target-type: ip`, `healthcheck-path: /login`, `listen-ports: [{"HTTP": 80}]`. HTTP only for the example; ACM/TLS is a follow-up.
- **Agents:** `rbac.create: true` plus a dedicated agent `ServiceAccount`; JCasC configures the Kubernetes cloud so each build launches an ephemeral agent pod in `apps-jenkins`, scaling to zero when idle, with explicit CPU/memory requests and limits sized to a valid Fargate task.
- **Controller:** `runAsUser: 1000`, `runAsNonRoot: true`, `fsGroup: 1000` (Fargate-compatible and matching the EFS access point identity); explicit memory and CPU requests/limits to avoid OOMKill; admin password auto-generated by the chart into the `jenkins` Secret (retrieval documented, not committed).
- **Persistence:** `persistence.enabled: true`, `persistence.existingClaim: jenkins-home`, mounted at the chart's default `/var/jenkins_home`.
- **Version pinning:** the upstream chart version and the Jenkins image are pinned; the exact chart version is confirmed against `https://charts.jenkins.io` during implementation.

## Documentation and validation

- New runbook `docs/operations/deploy-jenkins.md`: how the workload syncs, retrieving the admin password, reaching the internal ALB (VPN/bastion/port-forward), and running a test job that spawns a Fargate agent.
- `make yaml-check` must pass: `helm lint`/`template` of the local `jenkins-storage` chart with its `values-test.yaml`, `kubeconform`, and `kustomize build` of `gitops/workloads/charts`. If the Makefile's `helm-check` does not already discover charts under `gitops/workloads/charts`, the plan adds that path (flagged like the known duplicated-roots gotcha).
- `make terraform-check` must pass for the new `efs.tf` (fmt, validate, tflint, checkov) with any needed inline `#checkov:skip=` justifications (for example, EFS-related checks) documented at the resource.

## Commit strategy

One Conventional Commit per completed plan task, each message including the exact validation commands run, matching the repository convention:

- `feat: add EFS filesystem and Jenkins access point`
- `feat: surface EFS identifiers through the Argo CD handoff`
- `feat: add jenkins-storage helm chart`
- `feat: wire jenkins workload applicationset`
- `docs: add jenkins deployment runbook`

## Acceptance Criteria

- `modules/platform_cluster` provisions an encrypted EFS filesystem, per-AZ mount targets, a security group permitting NFS from the cluster, and a Jenkins access point (uid/gid 1000, `/jenkins-home`), and outputs the filesystem and access point IDs.
- `environments/platform` and `platform_cluster_bootstrap` thread those IDs through and surface them as Argo CD cluster-Secret annotations.
- The `jenkins-storage` chart renders a valid `StorageClass`, static `PersistentVolume` (EFS `volumeHandle`), and `PersistentVolumeClaim`, with no account-specific values hardcoded.
- A `config-workload-charts` bootstrap ApplicationSet and a `jenkins` ApplicationSet render a two-source Application deploying the upstream Jenkins chart plus the local storage chart into `apps-jenkins`.
- Jenkins is configured for internal-ALB ingress and dynamic Fargate agents, with a Fargate-compatible security context and persistence bound to the EFS-backed PVC.
- `make yaml-check` and `make terraform-check` pass.
- `docs/operations/deploy-jenkins.md` documents deploy, admin-password retrieval, access, and a test build.
- No Kubernetes object is owned by both Terraform and Argo CD; the EFS filesystem and access point are the only new AWS resources.
