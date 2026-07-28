# AWS EKS Platform Architecture Diagrams Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate editable and rendered AWS and Kubernetes architecture diagrams that accurately represent the repository's complete declared desired state.

**Architecture:** Build two independent diagrams with the declarative `drawio-ai` layout engine. The AWS view emphasizes account, Region, VPC, managed services, Fargate, storage, and observability topology; the Kubernetes view emphasizes Terraform/Argo CD ownership, GitOps fan-out, scheduling profiles, namespaces, controllers, and Jenkins runtime relationships.

**Tech Stack:** draw.io XML, `drawio-ai`, mxGraph AWS4 stencils, PNG rendering, repository Terraform and Kubernetes YAML as evidence.

## Global Constraints

- Represent declared desired state; label both diagrams to state that the platform is currently torn down.
- Keep AWS infrastructure and Kubernetes/GitOps in separate diagrams.
- Use `drawio-ai`'s declarative layout engine; do not hand-write coordinates.
- Preserve AWS catalog icon colors and use only stencils resolved through `drawio-ai search`.
- Keep Terraform and Argo CD ownership visually distinct and never assign one Kubernetes resource to both.
- Write final artifacts only under `docs/architecture/`.
- Run render-based visual checks in addition to automated validation.
- Commit one Conventional Commit per completed diagram task.

---

### Task 1: AWS Infrastructure Diagram

**Files:**

- Create: `docs/architecture/aws-platform-architecture.drawio`
- Create: `docs/architecture/aws-platform-architecture.png`

**Interfaces:**

- Consumes: Terraform and approved design evidence listed in `docs/superpowers/specs/2026-07-26-architecture-diagrams-design.md`.
- Produces: An editable AWS infrastructure topology and its PNG preview.

- [ ] **Step 1: Read the diagram-engine workflow and AWS rules**

Run:

```bash
DRAWIO_AI_ROOT="$(drawio-ai root)"
sed -n '1,260p' "$DRAWIO_AI_ROOT/docs/api-cheatsheet.md"
drawio-ai workflow
drawio-ai principles --mode aws
```

Expected: the API cheatsheet, build workflow, AWS nesting rules, and catalog guidance are available.

- [ ] **Step 2: Resolve all required AWS icons in one search**

Run:

```bash
drawio-ai search "Amazon EKS, AWS Fargate, Elastic Load Balancing, Amazon EFS, Amazon VPC, public subnet, private subnet, NAT gateway, internet gateway, Amazon S3, AWS KMS, AWS IAM Identity Center, AWS IAM, AWS CodeConnections, Amazon CloudWatch, GitHub"
```

Expected: catalog-backed stencil names for every AWS service used in the diagram; unsupported external concepts use neutral boxes.

- [ ] **Step 3: Scaffold and adapt the build script**

Run:

```bash
drawio-ai scaffold --list
drawio-ai scaffold aws/build_vpc_eks.mjs -o /tmp/aws-platform-architecture-build.mjs
```

Edit `/tmp/aws-platform-architecture-build.mjs` so the layout contains:

- External Terraform operator, GitHub, and internet-client actors.
- AWS account and Region boundaries.
- S3/KMS state, IAM Identity Center, CodeConnections, IAM/OIDC/IRSA.
- EKS control plane and managed Argo CD, ACK, and kro capabilities outside the VPC.
- Three Availability Zones with one public and one private subnet each.
- Internet Gateway, one NAT gateway, shared public ALB, Fargate data plane, and per-AZ EFS mount targets.
- Jenkins EFS access point, CloudWatch logging, and both KMS keys.
- Labeled provisioning, reconciliation, traffic, storage, and telemetry flows.
- A visible declared-state/torn-down annotation and compact legend.

The build writes:

```text
/Users/huyng/ws/aws-eks-infra/docs/architecture/aws-platform-architecture.drawio
/Users/huyng/ws/aws-eks-infra/docs/architecture/aws-platform-architecture.png
```

- [ ] **Step 4: Run the automated build/fix loop**

Run:

```bash
node /tmp/aws-platform-architecture-build.mjs
```

Expected: final validation JSON reports `ok: true`; the machine-readable render issue list is empty. Apply all reported fixes in one edit and rerun until both conditions hold.

- [ ] **Step 5: Visually inspect and finalize the render**

Inspect `docs/architecture/aws-platform-architecture.png` for clipping, overlap, unreadable text, incorrect nesting, and connector crossings. Fix all discovered issues in one edit, rerun the build, and then render the final PNG without `--check`:

```bash
drawio-ai render docs/architecture/aws-platform-architecture.drawio \
  -o docs/architecture/aws-platform-architecture.png
```

Expected: a legible diagram with no unresolved visual defects.

- [ ] **Step 6: Verify and commit**

Run:

```bash
drawio-ai validate docs/architecture/aws-platform-architecture.drawio --strict
test -s docs/architecture/aws-platform-architecture.drawio
test -s docs/architecture/aws-platform-architecture.png
git diff --check
git add docs/architecture/aws-platform-architecture.drawio \
  docs/architecture/aws-platform-architecture.png
git commit -m "docs: add AWS platform architecture diagram"
```

Expected: strict validation passes, both artifacts are non-empty, and the Conventional Commit succeeds.

### Task 2: Kubernetes and GitOps Diagram

**Files:**

- Create: `docs/architecture/kubernetes-platform-architecture.drawio`
- Create: `docs/architecture/kubernetes-platform-architecture.png`

**Interfaces:**

- Consumes: GitOps manifests, Terraform bootstrap resources, and the approved design specification.
- Produces: An editable Kubernetes/GitOps ownership and runtime diagram and its PNG preview.

- [ ] **Step 1: Read the diagram-engine workflow and shared AWS rules**

Run:

```bash
DRAWIO_AI_ROOT="$(drawio-ai root)"
sed -n '1,260p' "$DRAWIO_AI_ROOT/docs/api-cheatsheet.md"
drawio-ai workflow
drawio-ai principles --mode aws
```

Expected: declarative layout and validation rules are available. AWS-crossing services use catalog icons; Kubernetes resources use neutral semantic shapes because the installed engine has no Kubernetes mode.

- [ ] **Step 2: Resolve cross-boundary AWS icons in one search**

Run:

```bash
drawio-ai search "Amazon EKS, AWS Fargate, Elastic Load Balancing, Amazon EFS, AWS CodeConnections, Amazon CloudWatch, AWS IAM, GitHub"
```

Expected: catalog-backed stencils for AWS services that appear at the Kubernetes boundary.

- [ ] **Step 3: Scaffold and adapt the build script**

Run:

```bash
drawio-ai scaffold --list
drawio-ai scaffold aws/build_pipeline.mjs -o /tmp/kubernetes-platform-architecture-build.mjs
```

Edit `/tmp/kubernetes-platform-architecture-build.mjs` so the layout contains:

- Terraform-owned cluster-registration Secret and root `platform-bootstrap` ApplicationSet.
- GitHub → CodeConnections → managed Argo CD reconciliation.
- Root fan-out to add-ons, observability, kro definitions, workload charts, and plain workload discovery.
- Managed Argo CD, ACK, and kro capabilities outside the Fargate data plane.
- Fargate profile boundaries for `system`, `platform-addons`, and `future-workloads`.
- Namespaces and components: CoreDNS, AWS Load Balancer Controller, cert-manager, Argo Rollouts, OpenTelemetry Operator, ADOT, and Fargate logging.
- `WebApp` ResourceGraphDefinition and reusable namespace chart building blocks.
- Jenkins two-source Application, controller, ephemeral agents, Service, hostless Ingress, shared `platform-public` ALB, PVC, static PV, StorageClass, and EFS access point.
- Labeled ownership, reconciliation, request, storage, scheduling, and telemetry flows.
- A visible declared-state/torn-down annotation and compact legend.

The build writes:

```text
/Users/huyng/ws/aws-eks-infra/docs/architecture/kubernetes-platform-architecture.drawio
/Users/huyng/ws/aws-eks-infra/docs/architecture/kubernetes-platform-architecture.png
```

- [ ] **Step 4: Run the automated build/fix loop**

Run:

```bash
node /tmp/kubernetes-platform-architecture-build.mjs
```

Expected: final validation JSON reports `ok: true`; the machine-readable render issue list is empty. Apply all reported fixes in one edit and rerun until both conditions hold.

- [ ] **Step 5: Visually inspect and finalize the render**

Inspect `docs/architecture/kubernetes-platform-architecture.png` for clipping, overlap, unreadable text, false ownership, and connector crossings. Fix all discovered issues in one edit, rerun the build, and then render the final PNG without `--check`:

```bash
drawio-ai render docs/architecture/kubernetes-platform-architecture.drawio \
  -o docs/architecture/kubernetes-platform-architecture.png
```

Expected: a legible diagram with no unresolved visual defects.

- [ ] **Step 6: Verify and commit**

Run:

```bash
drawio-ai validate docs/architecture/kubernetes-platform-architecture.drawio --strict
test -s docs/architecture/kubernetes-platform-architecture.drawio
test -s docs/architecture/kubernetes-platform-architecture.png
git diff --check
git add docs/architecture/kubernetes-platform-architecture.drawio \
  docs/architecture/kubernetes-platform-architecture.png
git commit -m "docs: add Kubernetes platform architecture diagram"
```

Expected: strict validation passes, both artifacts are non-empty, and the Conventional Commit succeeds.

### Task 3: Final Cross-Diagram Verification

**Files:**

- Verify: `docs/architecture/aws-platform-architecture.drawio`
- Verify: `docs/architecture/aws-platform-architecture.png`
- Verify: `docs/architecture/kubernetes-platform-architecture.drawio`
- Verify: `docs/architecture/kubernetes-platform-architecture.png`

**Interfaces:**

- Consumes: both completed diagram tasks.
- Produces: fresh evidence that all artifacts meet the approved specification.

- [ ] **Step 1: Run strict validation and artifact checks**

Run:

```bash
drawio-ai validate docs/architecture/aws-platform-architecture.drawio --strict
drawio-ai validate docs/architecture/kubernetes-platform-architecture.drawio --strict
test -s docs/architecture/aws-platform-architecture.png
test -s docs/architecture/kubernetes-platform-architecture.png
git diff --check
git status --short
```

Expected: both validators report `ok: true`, both PNGs are non-empty, no whitespace errors exist, and the worktree has no uncommitted diagram changes.

- [ ] **Step 2: Check acceptance criteria against the approved design**

Confirm:

- Both diagrams say they represent desired state while the platform is torn down.
- AWS topology includes all three Availability Zones and their public/private subnet boundaries.
- Kubernetes view preserves the Terraform/Argo CD ownership split.
- Jenkins traffic and storage paths are present.
- Managed EKS Capabilities are not shown as Fargate Pods.
- No EC2 node group, Karpenter, or EKS Auto Mode compute appears.

Expected: every approved acceptance criterion is visibly satisfied.
