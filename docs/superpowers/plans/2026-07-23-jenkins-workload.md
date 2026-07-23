# Jenkins Workload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Jenkins as the first example workload on the Fargate-only EKS platform, using the upstream `jenkins/jenkins` Helm chart driven by Argo CD, with EFS-backed persistence, an internal ALB, and dynamic Fargate build agents.

**Architecture:** Terraform provisions an encrypted EFS filesystem plus a Jenkins access point and surfaces their IDs as annotations on the Argo CD cluster Secret (the repo's Terraform→Argo CD handoff). A new workload-side GitOps fan-out (`config-workload-charts` bootstrap ApplicationSet → `jenkins` ApplicationSet) renders a two-source Argo CD Application: the upstream Jenkins chart plus a local `jenkins-storage` chart that turns the EFS IDs into a static `StorageClass`/`PersistentVolume`/`PersistentVolumeClaim`. Fargate mounts the EFS volume natively, so no CSI driver is installed.

**Tech Stack:** Terraform (`terraform-aws-modules/eks` v21, AWS provider), Amazon EFS, Helm (upstream `jenkins` chart + local charts), Argo CD ApplicationSets, Kustomize, kubeconform.

## Global Constraints

- Ownership boundary: Terraform owns AWS resources only; Argo CD owns every Kubernetes object under `gitops/`. No object is managed by both. (EFS filesystem + access point are the only new AWS resources.)
- Jenkins runs in namespace `apps-jenkins` (controller + agents). This matches the existing `apps-*` selector on the `future_workloads` Fargate profile — no Fargate profile change is made.
- Account-specific values never hardcoded in YAML — they flow from Terraform outputs → `platform_cluster_bootstrap` variables → cluster-Secret annotations → `{{ .metadata.annotations.* }}` in ApplicationSet Helm values.
- Terraform conventions: `snake_case` names, typed variables with descriptions, deterministic tags from `var.tags`, inline `#checkov:skip=CKV_...: <justification>` for any suppression.
- No new Terraform root is created (`efs.tf` lives in `modules/platform_cluster`), so the duplicated `TF_ROOTS`/CI `roots` arrays are NOT touched.
- CI runs `make terraform-check` and `make yaml-check`; both must pass. CI calls the same Makefile targets, so updating the Makefile is sufficient (no separate CI array for helm).
- One Conventional Commit per task; the commit body lists the exact validation commands run.
- EFS is part of the destroyable platform (no `prevent_destroy`); data durability comes from the PV `Retain` reclaim policy, not a Terraform lifecycle guard.

---

## File Structure

Created:

- `modules/platform_cluster/efs.tf` — EFS KMS key, filesystem, security group + ingress rule, per-AZ mount targets, Jenkins access point.
- `gitops/workloads/charts/jenkins-storage/` — local Helm chart (Chart.yaml, .helmignore, values.yaml, values-test.yaml, templates for StorageClass/PV/PVC).
- `gitops/workloads/config/charts/kustomization.yaml` + `jenkins.yaml` — the Jenkins ApplicationSet (two-source Application).
- `gitops/platform/bootstrap/config-workload-charts.yaml` — bootstrap ApplicationSet that syncs `gitops/workloads/config/charts`.
- `gitops/workloads/manifests/.gitkeep` — home for future plain-manifest workloads.
- `docs/operations/deploy-jenkins.md` — runbook.

Modified:

- `modules/platform_cluster/outputs.tf` — add `efs_file_system_id`, `jenkins_efs_access_point_id`.
- `modules/platform_cluster_bootstrap/variables.tf` — add the two EFS variables.
- `modules/platform_cluster_bootstrap/kubernetes.tf` — add the two Secret annotations.
- `environments/platform/main.tf` — wire the two module outputs into the bootstrap module.
- `Makefile` — extend `helm-check` to lint/template/validate the `jenkins-storage` chart.
- `gitops/platform/bootstrap/config-workloads.yaml` — repoint its source path to `gitops/workloads/manifests` so it stops recursing the new chart/config trees.
- `gitops/workloads/README.md` — document the new workload layout.

---

## Task 1: EFS filesystem, access point, and networking (Terraform)

**Files:**
- Create: `modules/platform_cluster/efs.tf`
- Modify: `modules/platform_cluster/outputs.tf`

**Interfaces:**
- Consumes: `local.cluster_name`, `module.vpc.vpc_id`, `module.vpc.private_subnets`, `module.eks.cluster_primary_security_group_id`, `var.tags` (all already defined in the module).
- Produces: module outputs `efs_file_system_id` (string) and `jenkins_efs_access_point_id` (string), consumed by Task 3's wiring.

- [ ] **Step 1: Create `modules/platform_cluster/efs.tf`**

```hcl
# Amazon EFS provides the only Fargate-compatible persistent storage (EBS
# requires EC2 nodes). Jenkins mounts JENKINS_HOME through the access point
# below. Fargate mounts efs.csi.aws.com volumes natively, so no EFS CSI driver
# is installed in the cluster.

resource "aws_kms_key" "efs" {
  description             = "KMS key for ${local.cluster_name} EFS application storage"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = var.tags
}

resource "aws_kms_alias" "efs" {
  name          = "alias/${local.cluster_name}-efs"
  target_key_id = aws_kms_key.efs.key_id
}

resource "aws_efs_file_system" "apps" {
  creation_token = "${local.cluster_name}-apps"
  encrypted      = true
  kms_key_id     = aws_kms_key.efs.arn

  tags = merge(var.tags, { Name = "${local.cluster_name}-apps" })
}

resource "aws_security_group" "efs" {
  name_prefix = "${local.cluster_name}-efs-"
  description = "Allow NFS from the EKS cluster to the application EFS filesystem"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, { Name = "${local.cluster_name}-efs" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "efs_nfs" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS 2049 from Fargate pods on the EKS cluster security group"
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.cluster_primary_security_group_id
}

resource "aws_efs_mount_target" "apps" {
  for_each = toset(module.vpc.private_subnets)

  file_system_id  = aws_efs_file_system.apps.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "jenkins" {
  file_system_id = aws_efs_file_system.apps.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/jenkins-home"

    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "0755"
    }
  }

  tags = merge(var.tags, { Name = "${local.cluster_name}-jenkins" })
}
```

- [ ] **Step 2: Append outputs to `modules/platform_cluster/outputs.tf`**

```hcl
output "efs_file_system_id" {
  description = "ID of the EFS filesystem backing platform application storage."
  value       = aws_efs_file_system.apps.id
}

output "jenkins_efs_access_point_id" {
  description = "ID of the EFS access point scoping Jenkins to /jenkins-home."
  value       = aws_efs_access_point.jenkins.id
}
```

- [ ] **Step 3: Format and validate**

Run:
```bash
cd /Users/huyng/ws/aws-eks-infra
terraform fmt -recursive
terraform -chdir=environments/platform init -backend=false -input=false
terraform -chdir=environments/platform validate
```
Expected: `fmt` reports no changes (or reformats cleanly); `validate` prints `Success! The configuration is valid.`

- [ ] **Step 4: Lint and security-scan**

Run:
```bash
tflint --chdir=modules/platform_cluster
checkov -d modules/platform_cluster --framework terraform --config-file .checkov.yml
```
Expected: tflint passes. If checkov flags an EFS check (for example `CKV_AWS_184` for CMK encryption is already satisfied; a check on EFS SG or backup policy may appear), add an inline `#checkov:skip=CKV_...: <justification>` at the specific resource and re-run until clean. Do not add global skips.

- [ ] **Step 5: Commit**

```bash
git add modules/platform_cluster/efs.tf modules/platform_cluster/outputs.tf
git commit -m "feat: add EFS filesystem and Jenkins access point

Validation:
  terraform fmt -recursive
  terraform -chdir=environments/platform validate
  tflint --chdir=modules/platform_cluster
  checkov -d modules/platform_cluster --framework terraform --config-file .checkov.yml

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Surface EFS identifiers through the Argo CD handoff (Terraform)

**Files:**
- Modify: `modules/platform_cluster_bootstrap/variables.tf`
- Modify: `modules/platform_cluster_bootstrap/kubernetes.tf:12-21` (the Secret `annotations` block)
- Modify: `environments/platform/main.tf:80-96` (the `platform_cluster_bootstrap` module call)

**Interfaces:**
- Consumes: Task 1 outputs `module.platform_cluster.efs_file_system_id`, `module.platform_cluster.jenkins_efs_access_point_id`.
- Produces: cluster-Secret annotations `efs_file_system_id` and `jenkins_efs_access_point_id`, consumed by Task 5's ApplicationSet as `{{ .metadata.annotations.* }}`.

- [ ] **Step 1: Add variables to `modules/platform_cluster_bootstrap/variables.tf`**

Append:
```hcl
variable "efs_file_system_id" {
  description = "ID of the EFS filesystem backing platform application storage."
  type        = string
}

variable "jenkins_efs_access_point_id" {
  description = "ID of the EFS access point scoping Jenkins to /jenkins-home."
  type        = string
}
```

- [ ] **Step 2: Add annotations in `modules/platform_cluster_bootstrap/kubernetes.tf`**

In the `annotations = { ... }` block (currently lines 12-21), add two entries after `fargate_log_group_name`:
```hcl
      fargate_log_group_name                = var.fargate_log_group_name
      efs_file_system_id                    = var.efs_file_system_id
      jenkins_efs_access_point_id           = var.jenkins_efs_access_point_id
```

- [ ] **Step 3: Wire the module inputs in `environments/platform/main.tf`**

In the `module "platform_cluster_bootstrap"` block, add after `fargate_log_group_name`:
```hcl
  fargate_log_group_name                = module.platform_cluster.fargate_log_group_name
  efs_file_system_id                    = module.platform_cluster.efs_file_system_id
  jenkins_efs_access_point_id           = module.platform_cluster.jenkins_efs_access_point_id
```

- [ ] **Step 4: Format and validate**

Run:
```bash
cd /Users/huyng/ws/aws-eks-infra
terraform fmt -recursive
terraform -chdir=modules/platform_cluster_bootstrap init -backend=false -input=false
terraform -chdir=modules/platform_cluster_bootstrap validate
terraform -chdir=environments/platform init -backend=false -input=false
terraform -chdir=environments/platform validate
```
Expected: both `validate` calls print `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add modules/platform_cluster_bootstrap/variables.tf modules/platform_cluster_bootstrap/kubernetes.tf environments/platform/main.tf
git commit -m "feat: surface EFS identifiers through the Argo CD handoff

Validation:
  terraform fmt -recursive
  terraform -chdir=modules/platform_cluster_bootstrap validate
  terraform -chdir=environments/platform validate

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Local `jenkins-storage` Helm chart

**Files:**
- Create: `gitops/workloads/charts/jenkins-storage/Chart.yaml`
- Create: `gitops/workloads/charts/jenkins-storage/.helmignore`
- Create: `gitops/workloads/charts/jenkins-storage/values.yaml`
- Create: `gitops/workloads/charts/jenkins-storage/values-test.yaml`
- Create: `gitops/workloads/charts/jenkins-storage/templates/storageclass.yaml`
- Create: `gitops/workloads/charts/jenkins-storage/templates/persistentvolume.yaml`
- Create: `gitops/workloads/charts/jenkins-storage/templates/persistentvolumeclaim.yaml`
- Modify: `Makefile:26-31` (`helm-check` target)

**Interfaces:**
- Consumes: Helm values `fileSystemId`, `accessPointId`, `namespace`, `storageClassName`, `pvName`, `claimName`, `capacity` (supplied by Task 5's ApplicationSet; test values from `values-test.yaml`).
- Produces: a `StorageClass` named per `storageClassName` (default `efs-sc`), a `PersistentVolume` named per `pvName` (default `jenkins-home-pv`), and a `PersistentVolumeClaim` named per `claimName` (default `jenkins-home`) in `namespace` (default `apps-jenkins`). The claim name `jenkins-home` is what the Jenkins chart references via `persistence.existingClaim` in Task 5.

- [ ] **Step 1: Create `Chart.yaml`**

```yaml
apiVersion: v2
name: jenkins-storage
description: Static EFS StorageClass, PersistentVolume, and PVC for the Jenkins controller on Fargate
version: 1.0.0
type: application
```

- [ ] **Step 2: Create `.helmignore`**

```
.DS_Store
.git/
.gitignore
*.swp
*.bak
*.tmp
*.orig
*~
.idea/
.vscode/
```

- [ ] **Step 3: Create `values.yaml`**

```yaml
# EFS filesystem ID backing the Jenkins PersistentVolume. Injected by the
# Jenkins ApplicationSet from the platform-cluster Secret annotations.
fileSystemId: ""
# EFS access point ID scoping the volume to /jenkins-home.
accessPointId: ""
# Namespace for the PersistentVolumeClaim (the PV and StorageClass are cluster-scoped).
namespace: apps-jenkins
# Name of the StorageClass referenced by the PV and PVC.
storageClassName: efs-sc
# Name of the static PersistentVolume.
pvName: jenkins-home-pv
# Name of the PersistentVolumeClaim the Jenkins chart mounts as JENKINS_HOME.
claimName: jenkins-home
# Nominal capacity. EFS is elastic and ignores this value; Kubernetes requires it.
capacity: 20Gi
```

- [ ] **Step 4: Create `values-test.yaml`**

```yaml
fileSystemId: fs-0123456789abcdef0
accessPointId: fsap-0123456789abcdef0
```

- [ ] **Step 5: Create `templates/storageclass.yaml`**

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: {{ .Values.storageClassName }}
# Static provisioning: the PV below references the EFS filesystem directly.
# No dynamic parameters and no EFS CSI controller are required on Fargate.
provisioner: efs.csi.aws.com
```

- [ ] **Step 6: Create `templates/persistentvolume.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: {{ .Values.pvName }}
spec:
  capacity:
    storage: {{ .Values.capacity }}
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: {{ .Values.storageClassName }}
  csi:
    driver: efs.csi.aws.com
    volumeHandle: {{ printf "%s::%s" .Values.fileSystemId .Values.accessPointId | quote }}
```

- [ ] **Step 7: Create `templates/persistentvolumeclaim.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .Values.claimName }}
  namespace: {{ .Values.namespace }}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: {{ .Values.storageClassName }}
  volumeName: {{ .Values.pvName }}
  resources:
    requests:
      storage: {{ .Values.capacity }}
```

- [ ] **Step 8: Extend the `helm-check` target in `Makefile`**

After the existing `namespace-config` `@if` block (ends at line 31), add:
```makefile
	@if [ -f gitops/workloads/charts/jenkins-storage/Chart.yaml ]; then \
		helm lint gitops/workloads/charts/jenkins-storage -f gitops/workloads/charts/jenkins-storage/values-test.yaml; \
		helm template jenkins-storage gitops/workloads/charts/jenkins-storage -f gitops/workloads/charts/jenkins-storage/values-test.yaml > /tmp/jenkins-storage-rendered.yaml; \
		kubeconform -strict -summary -ignore-missing-schemas /tmp/jenkins-storage-rendered.yaml; \
	fi
```
Keep the recipe lines TAB-indented to match the file.

- [ ] **Step 9: Render and validate the chart**

Run:
```bash
cd /Users/huyng/ws/aws-eks-infra
helm lint gitops/workloads/charts/jenkins-storage -f gitops/workloads/charts/jenkins-storage/values-test.yaml
helm template jenkins-storage gitops/workloads/charts/jenkins-storage -f gitops/workloads/charts/jenkins-storage/values-test.yaml
```
Expected: lint reports `0 chart(s) failed`; the template output contains a `StorageClass efs-sc`, a `PersistentVolume` with `volumeHandle: "fs-0123456789abcdef0::fsap-0123456789abcdef0"`, and a `PersistentVolumeClaim jenkins-home` in `apps-jenkins`.

- [ ] **Step 10: Run the full YAML gate**

Run:
```bash
make yaml-check
```
Expected: yamllint, helm-check (now including jenkins-storage), and kustomize-check all pass.

- [ ] **Step 11: Commit**

```bash
git add gitops/workloads/charts/jenkins-storage Makefile
git commit -m "feat: add jenkins-storage helm chart

Renders the static EFS StorageClass, PersistentVolume, and PVC for the
Jenkins controller and wires the chart into make helm-check.

Validation:
  helm lint gitops/workloads/charts/jenkins-storage -f .../values-test.yaml
  make yaml-check

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Jenkins ApplicationSet and workload-charts fan-out (GitOps)

**Files:**
- Create: `gitops/workloads/manifests/.gitkeep`
- Create: `gitops/workloads/config/charts/kustomization.yaml`
- Create: `gitops/workloads/config/charts/jenkins.yaml`
- Create: `gitops/platform/bootstrap/config-workload-charts.yaml`
- Modify: `gitops/platform/bootstrap/config-workloads.yaml` (repoint `source.path`)
- Modify: `gitops/workloads/README.md`

**Interfaces:**
- Consumes: cluster-Secret annotations from Task 2 (`efs_file_system_id`, `jenkins_efs_access_point_id`, plus existing `gitops_repo_url`, `gitops_revision`); the `jenkins-storage` chart path and the `jenkins-home` claim name from Task 3.
- Produces: a `jenkins` ApplicationSet rendering a two-source Application into `apps-jenkins`, reconciled by the new `platform-workload-charts` bootstrap ApplicationSet.

- [ ] **Step 1: Determine and pin the upstream Jenkins chart version**

Run:
```bash
helm repo add jenkins https://charts.jenkins.io
helm repo update jenkins
helm search repo jenkins/jenkins --versions | head -5
```
Note the latest stable version (the top row's CHART VERSION). Use it as `targetRevision` in Step 4, replacing `5.8.60` if the printed version differs.

- [ ] **Step 2: Create `gitops/workloads/manifests/.gitkeep`**

```
# Plain-manifest / kustomize workloads reconciled by the platform-workloads
# ApplicationSet live here. Helm-chart workloads use gitops/workloads/charts
# plus an ApplicationSet under gitops/workloads/config/charts instead.
```

- [ ] **Step 3: Repoint `gitops/platform/bootstrap/config-workloads.yaml`**

Change the source path so it no longer recurses the new chart/config trees:
```yaml
      source:
        repoURL: '{{ .metadata.annotations.gitops_repo_url }}'
        targetRevision: '{{ .metadata.annotations.gitops_revision }}'
        path: gitops/workloads/manifests
        directory:
          recurse: true
```
(Only the `path` line changes, from `gitops/workloads` to `gitops/workloads/manifests`.)

- [ ] **Step 4: Create `gitops/workloads/config/charts/jenkins.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: jenkins
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            workload_cluster: "true"
  template:
    metadata:
      name: '{{ .name }}-jenkins'
    spec:
      project: default
      sources:
        - repoURL: https://charts.jenkins.io
          chart: jenkins
          targetRevision: "5.8.60"
          helm:
            # Pin the release name so rendered object names stay deterministic.
            releaseName: jenkins
            values: |
              controller:
                serviceType: ClusterIP
                jenkinsUrlProtocol: http
                resources:
                  requests:
                    cpu: "1000m"
                    memory: "2Gi"
                  limits:
                    cpu: "2000m"
                    memory: "4Gi"
                podSecurityContextOverride:
                  runAsUser: 1000
                  runAsGroup: 1000
                  fsGroup: 1000
                  runAsNonRoot: true
                ingress:
                  enabled: true
                  ingressClassName: alb
                  annotations:
                    alb.ingress.kubernetes.io/scheme: internal
                    alb.ingress.kubernetes.io/target-type: ip
                    alb.ingress.kubernetes.io/healthcheck-path: /login
                    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
                persistence:
                  enabled: true
                  existingClaim: jenkins-home
              agent:
                enabled: true
                namespace: apps-jenkins
                resources:
                  requests:
                    cpu: "500m"
                    memory: "512Mi"
                  limits:
                    cpu: "1000m"
                    memory: "1Gi"
              rbac:
                create: true
              serviceAccount:
                create: true
                name: jenkins
              serviceAccountAgent:
                create: true
                name: jenkins-agent
        - repoURL: '{{ .metadata.annotations.gitops_repo_url }}'
          targetRevision: '{{ .metadata.annotations.gitops_revision }}'
          path: gitops/workloads/charts/jenkins-storage
          helm:
            releaseName: jenkins-storage
            values: |
              fileSystemId: '{{ .metadata.annotations.efs_file_system_id }}'
              accessPointId: '{{ .metadata.annotations.jenkins_efs_access_point_id }}'
              namespace: apps-jenkins
      destination:
        server: '{{ .server }}'
        namespace: apps-jenkins
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - ServerSideApply=true
          - CreateNamespace=true
```

- [ ] **Step 5: Create `gitops/workloads/config/charts/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - jenkins.yaml
```

- [ ] **Step 6: Create `gitops/platform/bootstrap/config-workload-charts.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-workload-charts
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            workload_cluster: "true"
  template:
    metadata:
      name: '{{ .name }}-platform-workload-charts'
    spec:
      project: default
      source:
        repoURL: '{{ .metadata.annotations.gitops_repo_url }}'
        targetRevision: '{{ .metadata.annotations.gitops_revision }}'
        path: gitops/workloads/config/charts
        directory:
          recurse: true
      destination:
        server: '{{ .server }}'
        namespace: argocd
      syncPolicy:
        automated:
          prune: true
          allowEmpty: true
        syncOptions:
          - ServerSideApply=true
```

- [ ] **Step 7: Update `gitops/workloads/README.md`**

Replace its contents with:
```markdown
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
```

- [ ] **Step 8: Validate the manifests**

Run:
```bash
cd /Users/huyng/ws/aws-eks-infra
kubectl kustomize gitops/workloads/config/charts | kubeconform -strict -summary -ignore-missing-schemas
make yaml-check
```
Expected: kustomize build emits the `jenkins` ApplicationSet; kubeconform summary reports no errors (ApplicationSet schema is skipped via `-ignore-missing-schemas`); `make yaml-check` passes end to end.

- [ ] **Step 9: Commit**

```bash
git add gitops/workloads/manifests gitops/workloads/config gitops/workloads/README.md gitops/platform/bootstrap/config-workload-charts.yaml gitops/platform/bootstrap/config-workloads.yaml
git commit -m "feat: wire jenkins workload applicationset

Adds the platform-workload-charts fan-out and a two-source jenkins
ApplicationSet (upstream chart + jenkins-storage), and repoints
platform-workloads to gitops/workloads/manifests.

Validation:
  kubectl kustomize gitops/workloads/config/charts | kubeconform -strict -summary -ignore-missing-schemas
  make yaml-check

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Deployment runbook

**Files:**
- Create: `docs/operations/deploy-jenkins.md`

**Interfaces:**
- Consumes: names established in earlier tasks (`apps-jenkins`, `jenkins-home` PVC, the `jenkins` Argo CD Application, internal ALB ingress).
- Produces: operator documentation only; no code depends on it.

- [ ] **Step 1: Create `docs/operations/deploy-jenkins.md`**

```markdown
# Deploy Jenkins

Jenkins is the first example workload on the Fargate-only platform. It is
deployed by Argo CD from the upstream `jenkins/jenkins` Helm chart plus the
local `jenkins-storage` chart, and runs entirely on AWS Fargate.

## Prerequisites

- The platform is applied and healthy (`./scripts/verify-platform.sh`).
- Terraform has been applied since the EFS filesystem and Jenkins access point
  were added (Task 1/2 of the Jenkins workload plan), so the Argo CD cluster
  Secret carries `efs_file_system_id` and `jenkins_efs_access_point_id`.
- `kubectl` and AWS credentials are configured (see `docs/operations/cluster-access.md`).

## How it reconciles

1. `platform-bootstrap` applies `config-workload-charts.yaml`.
2. `platform-workload-charts` syncs `gitops/workloads/config/charts` and creates
   the `jenkins` ApplicationSet.
3. `jenkins` renders a two-source Application into `apps-jenkins`: the upstream
   Jenkins chart and the `jenkins-storage` chart (StorageClass + static PV + PVC
   bound to the EFS access point).
4. Fargate schedules the controller in `apps-jenkins` (matched by the `apps-*`
   Fargate profile) and mounts the EFS volume natively.

## Verify

```bash
kubectl -n argocd get applications | grep jenkins
kubectl -n apps-jenkins get pods,pvc,ingress
```

Expected: the Jenkins Application is `Synced`/`Healthy`, the controller pod is
`Running`, the `jenkins-home` PVC is `Bound`, and the `jenkins` Ingress has an
internal ALB address.

## Retrieve the admin password

```bash
kubectl -n apps-jenkins exec -it sts/jenkins -c jenkins -- \
  cat /run/secrets/additional/chart-admin-password 2>/dev/null || \
kubectl -n apps-jenkins get secret jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo
```

The admin user is `admin`.

## Reach the UI

The ALB is internal. From a host inside the VPC (VPN or bastion), browse to the
ingress address. Otherwise port-forward:

```bash
kubectl -n apps-jenkins port-forward svc/jenkins 8080:8080
# open http://localhost:8080
```

## Run a test build (Fargate agent)

Create a Pipeline job with:

```groovy
pipeline {
  agent { kubernetes { defaultContainer 'jnlp' } }
  stages {
    stage('hello') {
      steps { sh 'echo built on $(hostname) on Fargate' }
    }
  }
}
```

Run it and confirm an ephemeral agent pod appears in `apps-jenkins`
(`kubectl -n apps-jenkins get pods -w`) and terminates after the build.

## Follow-ups (out of scope for the first example)

- TLS termination on the ALB via ACM.
- NetworkPolicy / ResourceQuota governance for `apps-jenkins`.
- Controller IRSA if pipelines need AWS API access.
```

- [ ] **Step 2: Lint docs and run the full gate**

Run:
```bash
cd /Users/huyng/ws/aws-eks-infra
make yaml-check
```
Expected: passes (the runbook is Markdown; this confirms nothing else regressed).

- [ ] **Step 3: Commit**

```bash
git add docs/operations/deploy-jenkins.md
git commit -m "docs: add jenkins deployment runbook

Validation:
  make yaml-check

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

Run the full CI-equivalent gates from the repo root and confirm both pass:

```bash
cd /Users/huyng/ws/aws-eks-infra
make terraform-check
make yaml-check
```

Expected: `make terraform-check` (fmt-check + validate on every root + tflint + checkov) and `make yaml-check` (yamllint + helm lint/template + kubeconform + kustomize build) both complete without error.

Note: this plan changes configuration only. Applying Terraform (creating the EFS filesystem) and letting Argo CD sync Jenkins require AWS credentials + kubeconfig and are performed by an operator following `docs/operations/deploy-jenkins.md`; they are not part of CI.
