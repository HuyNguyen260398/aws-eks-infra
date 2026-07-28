# AWS EKS Platform Architecture Diagrams — Design

Date: 2026-07-26

## Purpose

Create two complementary architecture diagrams representing the complete
declared desired state of this repository. The platform is currently torn down
to save cost, so the diagrams describe infrastructure and Kubernetes resources
defined by Terraform and GitOps rather than live AWS inventory.

## Deliverables

Create editable draw.io sources and rendered PNG previews under
`docs/architecture/`:

- `aws-platform-architecture.drawio`
- `aws-platform-architecture.png`
- `kubernetes-platform-architecture.drawio`
- `kubernetes-platform-architecture.png`

The diagrams must remain separate so that the AWS topology and Kubernetes
reconciliation model are both readable without creating one oversized diagram.

## Diagram 1: AWS Infrastructure

The AWS diagram presents the platform from external inputs through AWS account,
Region, networking, compute, storage, identity, and observability boundaries.

### External systems and actors

- Terraform operator and Terraform CLI.
- GitHub repository as the GitOps source of truth.
- Internet clients reaching public workloads.

### AWS global and regional services

- S3 remote state with native S3 lockfiles and a customer-managed KMS key.
- IAM Identity Center administrator group used by managed Argo CD.
- AWS CodeConnections for GitHub repository access.
- IAM roles, EKS access associations, OIDC/IRSA, and the Fargate pod execution
  role.
- Amazon EKS control plane with private and CIDR-restricted public API access.
- AWS-managed EKS Capabilities for Argo CD, ACK, and kro.
- CloudWatch log groups for EKS control-plane logs, Fargate logs, Container
  Insights, and VPC Flow Logs, protected by a customer-managed KMS key.

### VPC and data plane

- One VPC spanning three Availability Zones.
- One public and one private subnet per Availability Zone.
- An Internet Gateway and one shared NAT gateway.
- An internet-facing shared Application Load Balancer in public subnets.
- Fargate-only workloads in private subnets with no EC2 node groups, EKS Auto
  Mode, or Karpenter.
- EFS mount targets in each private subnet and an EFS access point for Jenkins,
  protected by a dedicated customer-managed KMS key and NFS security group.
- ALB IP targets routing `/jenkins` to the Jenkins workload.

### Primary flows

- Terraform provisions the AWS desired state and Argo CD bootstrap resources.
- GitHub reaches managed Argo CD through CodeConnections.
- Argo CD reconciles Kubernetes configuration into the EKS cluster.
- Internet traffic enters the shared ALB and reaches Fargate pod IP targets.
- Jenkins mounts persistent storage through the EFS access point.
- Control-plane, application, and network telemetry flows to CloudWatch.

## Diagram 2: Kubernetes and GitOps

The Kubernetes diagram presents control ownership, GitOps fan-out, scheduling,
platform controllers, observability, and the Jenkins workload.

### Ownership and reconciliation

- Terraform owns the EKS cluster-registration Secret and root
  `platform-bootstrap` ApplicationSet only.
- Managed Argo CD reads GitHub through CodeConnections.
- The root ApplicationSet creates platform add-on, observability, kro
  definition, workload chart, and plain workload discovery ApplicationSets.
- Argo CD owns all continuing reconciliation under `gitops/platform/` and
  `gitops/workloads/`.
- No Kubernetes resource is shown as jointly owned by Terraform and Argo CD.

### Managed capabilities

- Managed Argo CD, ACK, and kro capabilities are shown outside the Fargate pod
  data plane.
- kro consumes the `WebApp` ResourceGraphDefinition.
- ACK is enabled but has no service-specific AWS resource definitions in the
  current desired state.

### Fargate scheduling

- The `system` profile selects `kube-system`.
- The `platform-addons` profile selects `argo-rollouts`, `cert-manager`,
  `opentelemetry-operator-system`, and `amazon-cloudwatch`.
- The `future-workloads` profile selects namespaces matching `apps-*`, including
  `apps-jenkins`.
- `aws-observability` supplies Fargate-native log routing configuration.

### Platform components

- CoreDNS and AWS Load Balancer Controller in `kube-system`.
- cert-manager in `cert-manager`.
- Argo Rollouts in `argo-rollouts`.
- OpenTelemetry Operator in `opentelemetry-operator-system`.
- ADOT service account and collectors in `amazon-cloudwatch`.
- Namespace chart building blocks for Namespace, quotas, limits,
  NetworkPolicy, Role, and RoleBinding.

### Jenkins workload

- A two-source Argo CD Application combines the pinned upstream Jenkins chart
  with the local `jenkins-storage` chart.
- Jenkins controller and ephemeral agent pods run in `apps-jenkins` on Fargate.
- A hostless Ingress joins the `platform-public` IngressGroup and routes
  `/jenkins` through the shared internet-facing ALB using IP targets.
- The `jenkins-home` PVC binds to a static EFS-backed PV through the `efs-sc`
  StorageClass and the Jenkins EFS access point.
- Fargate and ADOT telemetry flows to CloudWatch.

## Visual Design

- Use AWS Architecture Icons with their catalog-defined colors in the AWS
  diagram.
- Use Kubernetes-native or neutral component notation for Kubernetes objects;
  AWS services that cross the Kubernetes boundary retain AWS icons.
- Use nested containers only for real ownership or deployment boundaries:
  AWS account, Region, VPC, Availability Zone, subnet, cluster, Fargate profile,
  and namespace.
- Distinguish provisioning, GitOps reconciliation, request traffic, storage,
  and telemetry flows using labeled connectors and a compact legend.
- Prefer left-to-right primary flow and avoid crossing connectors.
- Mark the platform as “Declared desired state — platform currently torn down”
  on both diagrams.

## Evidence Sources

- `README.md`
- `environments/platform/main.tf`
- `modules/platform_cluster/vpc.tf`
- `modules/platform_cluster/eks.tf`
- `modules/platform_cluster/capabilities_argocd.tf`
- `modules/platform_cluster/capabilities_ack.tf`
- `modules/platform_cluster/capabilities_kro.tf`
- `modules/platform_cluster/efs.tf`
- `modules/platform_cluster/observability.tf`
- `modules/platform_cluster_bootstrap/kubernetes.tf`
- `gitops/platform/bootstrap/`
- `gitops/platform/config/`
- `gitops/workloads/config/charts/jenkins.yaml`
- `gitops/workloads/charts/jenkins-storage/`
- `docs/superpowers/specs/2026-07-18-eks-fargate-platform-recreation-design.md`
- `docs/superpowers/specs/2026-07-23-jenkins-workload-design.md`
- `docs/superpowers/specs/2026-07-26-public-workload-access-design.md`

## Acceptance Criteria

- Both `.drawio` files open as editable draw.io diagrams.
- Both diagrams have PNG previews.
- The AWS diagram uses ground-truth AWS stencils and preserves their category
  colors.
- Automated diagram validation reports no errors, warnings, or advice.
- Render-based inspection finds no clipped labels, overlapping nodes, invalid
  nesting, or unreadable connector routing.
- The diagrams represent the declared desired state and do not imply that the
  platform is currently deployed.
- The diagrams preserve the Terraform/Argo CD ownership boundary.
