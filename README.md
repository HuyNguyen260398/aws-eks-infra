<div align="center">

# AWS EKS Fargate Platform Infrastructure

**Terraform and GitOps blueprint for a serverless Amazon EKS platform running exclusively on AWS Fargate.**

[![Terraform](https://img.shields.io/badge/Terraform-1.10%2B-844FBA?logo=terraform&logoColor=white)](https://www.terraform.io/)
[![Amazon EKS](https://img.shields.io/badge/Amazon%20EKS-1.35-FF9900)](https://aws.amazon.com/eks/)
[![AWS Fargate](https://img.shields.io/badge/AWS%20Fargate-serverless-FF9900)](https://aws.amazon.com/fargate/)
[![Argo CD](https://img.shields.io/badge/Argo%20CD-GitOps-EF7B4D?logo=argo&logoColor=white)](https://argo-cd.readthedocs.io/)
[![Helm](https://img.shields.io/badge/Helm-charts-0F1689?logo=helm&logoColor=white)](https://helm.sh/)
[![Kustomize](https://img.shields.io/badge/Kustomize-overlays-326CE5?logo=kubernetes&logoColor=white)](https://kustomize.io/)
[![Jenkins](https://img.shields.io/badge/Jenkins-workload-D24939?logo=jenkins&logoColor=white)](https://www.jenkins.io/)
[![GitHub Actions](https://img.shields.io/badge/GitHub%20Actions-CI-2088FF?logo=githubactions&logoColor=white)](.github/workflows)
[![Checkov](https://img.shields.io/badge/Checkov-scanned-7D3C98)](https://www.checkov.io/)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE.md)

</div>

This repository is a **reference architecture**. Fork it, set a handful of
Terraform variables, and you get the whole platform in your own AWS account.
Start at [Getting Started](#getting-started).

## Overview

The repository provides one environment named `platform` with:

- A three-Availability-Zone VPC and private Fargate scheduling.
- Amazon EKS with no EC2 node groups, Auto Mode, or Karpenter.
- AWS-managed Argo CD, ACK, and kro EKS Capabilities.
- GitHub as the GitOps source of truth through AWS CodeConnections.
- Terraform-managed S3/KMS remote state using native S3 lockfiles.
- Fargate-compatible logging, metrics, ingress control, and rollout tooling.
- A shared internet-facing ALB (`platform-public`) that any workload can join by Ingress annotation alone.
- A Jenkins workload on Fargate backed by an encrypted EFS access point.

Further workloads are added through separately approved service plans; the platform itself is at parity.

## Architecture

Both diagrams describe the **declared desired state**. Editable sources live beside the renders in [`docs/architecture/`](docs/architecture).

### AWS infrastructure

Account, Region, VPC, managed services, Fargate scheduling, persistent storage, and observability.

![AWS platform architecture](docs/architecture/aws-platform-architecture.png)

### Kubernetes and GitOps

Terraform/Argo CD ownership, the bootstrap handoff, ApplicationSet fan-out, Fargate profiles, namespaces, and the Jenkins runtime.

![Kubernetes platform architecture](docs/architecture/kubernetes-platform-architecture.png)

Terraform owns customer-controlled AWS resources and the minimum Argo CD bootstrap. Argo CD owns ongoing Kubernetes platform configuration. No resource is intentionally managed by both systems.

## Technology Stack

| Area | Technologies |
| --- | --- |
| Infrastructure | Terraform, AWS Provider, terraform-aws-modules |
| Compute | Amazon EKS 1.35, AWS Fargate |
| GitOps | GitHub, AWS CodeConnections, managed Argo CD, Helm, Kustomize |
| Platform | ACK, kro, Argo Rollouts, cert-manager, AWS Load Balancer Controller |
| Networking | Three-AZ VPC, single NAT gateway, shared internet-facing ALB |
| Storage | Amazon EFS access points, AWS KMS, S3 remote state |
| Workloads | Jenkins on Fargate with EFS-backed `JENKINS_HOME` |
| Observability | CloudWatch Logs, VPC Flow Logs, ADOT, OpenTelemetry Operator |
| Quality | TFLint, Checkov, yamllint, Helm, Kustomize, kubeconform, GitHub Actions |

## Repository Structure

```text
aws-eks-infra/
├── bootstrap/
│   └── terraform-state/                 S3 + KMS remote-state foundation (native S3 lockfiles)
├── environments/
│   └── platform/                        The only deployable Terraform root
├── modules/
│   ├── platform_cluster/                VPC, EKS, Fargate profiles, capabilities, IAM, observability
│   │   └── policies/                    JSON IAM policy documents (ALB controller)
│   ├── platform_cluster_bootstrap/      Terraform-to-Argo CD handoff objects
│   └── ack_iam_role_selector/           Namespace-scoped IAM roles for ACK (not yet wired in)
├── gitops/
│   ├── platform/
│   │   ├── bootstrap/                   ApplicationSets Argo CD reconciles first
│   │   ├── config/
│   │   │   ├── addons/                  cert-manager, ALB controller, Argo Rollouts, OTel operator
│   │   │   ├── observability/           Fargate logging ConfigMap and ADOT collector
│   │   │   └── kro-definitions/         kro ResourceGraphDefinitions
│   │   └── charts/
│   │       └── namespace-config/        Namespace, quota, limits, RBAC, NetworkPolicy chart
│   └── workloads/
│       ├── charts/
│       │   └── jenkins-storage/         Static EFS StorageClass, PersistentVolume, and PVC
│       ├── config/charts/               Argo CD Application definitions for workload charts
│       └── manifests/                   Plain workload manifests (empty placeholder)
├── scripts/                             Validation and operational helpers
│   ├── verify-prerequisites.sh          Tool and AWS account preflight
│   ├── verify-platform.sh               Acceptance checks
│   ├── platform-info.sh                 Post-deploy report: cluster, ALB, workload URLs
│   ├── check-drift.sh                   Refresh-only drift detection
│   └── destroy-platform.sh              Guarded teardown
├── docs/
│   ├── architecture/                    Architecture diagrams (.drawio sources + .png renders)
│   └── operations/                      Deployment, access, observability, and recovery runbooks
├── .github/workflows/                   terraform-ci and yaml-ci quality gates (no AWS credentials)
└── Makefile                             terraform-check, yaml-check, shell-check
```

> [!WARNING]
> **This costs money to run.** An EKS control plane, a NAT gateway, an
> Application Load Balancer, an EFS filesystem, and four CloudWatch log groups
> bill continuously, and none of them are covered by the AWS free tier. Expect a
> few US dollars per day in a quiet account. Tear the platform down when you are
> not using it — see [Tearing Down](#tearing-down).

## Getting Started

This walkthrough takes a fresh AWS account to a running platform with the
example Jenkins workload reachable over the internet. Budget about 60 minutes,
most of it waiting for the EKS control plane and the capabilities.

Every command runs from the repository root.

### 1. Install the tools

| Tool | Minimum | CI pins |
| --- | --- | --- |
| Terraform | 1.10 | 1.10.5 |
| AWS CLI | v2 | — |
| kubectl | 1.32 | v1.35.0 |
| Helm | 3 | v3.18.4 |
| TFLint | — | v0.59.1 |
| Checkov | — | 3.2.471 |
| yamllint | — | 1.37.1 |
| kubeconform | — | v0.7.0 |
| jq, git | — | — |

Terraform 1.10 is a hard floor: the remote state uses native S3 locking
(`use_lockfile`), which older versions do not support.

```bash
brew install terraform awscli kubectl helm tflint kubeconform jq git
pip install checkov==3.2.471 yamllint==1.37.1
```

Matching the pinned versions locally means `make terraform-check` reproduces
what CI does; drifting from them mostly shows up as different Checkov findings.

### 2. Prepare the AWS account

Configure credentials, then confirm which account you are pointed at:

```bash
aws configure --profile my-platform
export AWS_PROFILE=my-platform
export AWS_REGION=ap-southeast-1
aws sts get-caller-identity
```

This platform requires **IAM Identity Center** — the Terraform root asserts that
exactly one instance exists and creates the Argo CD administrators group inside
it. If your account has none, enable it in the AWS Console (IAM Identity Center
→ Enable) before continuing; there is no Terraform path for that step.

Collect the Identity Store user IDs that will administer Argo CD:

```bash
aws identitystore list-users \
  --identity-store-id "$(aws sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text)" \
  --query 'Users[].{id:UserId,name:UserName}' --output table
```

Note your public egress address — you need it as a `/32` for the EKS API
allowlist. `0.0.0.0/0` is rejected by variable validation:

```bash
curl -s https://checkip.amazonaws.com
```

Then run the preflight, which checks tooling, credentials, the Identity Center
instance, and access to your GitOps repository:

```bash
./scripts/verify-prerequisites.sh
```

It must exit `0`. It installs nothing and changes no AWS or GitHub state. It
checks the repository through this checkout's `origin` remote; if your GitOps
repository is somewhere else, set `GITOPS_REPO_URL` to override.

### 3. Fork and clone

**Forking is mandatory, not a courtesy.** Argo CD reads the GitOps repository
through AWS CodeConnections and reconciles what is on its `main` branch — not
your working tree. If you deploy from an unforked clone, the cluster follows the
upstream repository and no change you make locally will ever reach it.

```bash
gh repo fork <github_owner>/<github_repository> --clone
cd <github_repository>
```

Or fork in the GitHub UI and clone your copy. Note your fork's owner and
repository name; both are required Terraform inputs in step 5.

### 4. Create the Terraform state foundation

State lives in an S3 bucket that Terraform itself creates, so the first apply is
a chicken-and-egg: it runs with **local** state, then migrates that state into
the bucket it just made.

```bash
cp bootstrap/terraform-state/terraform.tfvars.example bootstrap/terraform-state/terraform.tfvars
# edit aws_profile / aws_region / resource_prefix to taste

terraform -chdir=bootstrap/terraform-state init
terraform -chdir=bootstrap/terraform-state plan -out=tfplan
terraform -chdir=bootstrap/terraform-state apply tfplan
```

Take the two outputs and write the backend config:

```bash
terraform -chdir=bootstrap/terraform-state output
```

```bash
cp bootstrap/terraform-state/backend.hcl.example bootstrap/terraform-state/backend.hcl
# set bucket = <state_bucket_name>, kms_key_id = <state_kms_key_arn>, region

terraform -chdir=bootstrap/terraform-state init -migrate-state -backend-config=backend.hcl
```

Answer `yes` when Terraform offers to copy the existing state. Do **not** create
a DynamoDB lock table — this repository uses native S3 lockfiles.

Confirm the foundation is applied and drift-free:

```bash
terraform -chdir=bootstrap/terraform-state plan -detailed-exitcode
```

Exit code `0` means converged. The bucket and KMS key carry `prevent_destroy`
and are deliberately outside the platform teardown path.

### 5. Configure your inputs

```bash
cp environments/platform/terraform.tfvars.example environments/platform/terraform.tfvars
cp environments/platform/backend.hcl.example environments/platform/backend.hcl
```

Edit `backend.hcl` with the same bucket and KMS key as step 4, keeping
`key = "platform/terraform.tfstate"`. Then fill `terraform.tfvars`:

| Variable | Required | What to put in it |
| --- | --- | --- |
| `github_owner` | **yes** | The GitHub user or org that owns **your fork** |
| `github_repository` | **yes** | Your fork's repository name |
| `public_access_cidrs` | **yes** | Your egress address as a `/32`. `0.0.0.0/0` is rejected |
| `argocd_admin_user_ids` | **yes** | Identity Store user IDs from step 2 |
| `aws_profile` | no | Defaults to `default` |
| `aws_region` | no | Defaults to `ap-southeast-1` |
| `resource_prefix` | no | Defaults to `aws-eks-infra`; prefixes every resource name and tag |
| `vpc_cidr` | no | Defaults to `10.0.0.0/16` |
| `kubernetes_version` | no | Defaults to `1.35` |
| `gitops_revision` | no | Defaults to `main` |

> [!CAUTION]
> `terraform.tfvars`, `backend.hcl`, `tfplan`, and `*.tfstate` are gitignored and
> must never be committed. They carry account identifiers and, in state's case,
> resource attributes you do not want in a public repository.

### 6. Apply the platform

> [!IMPORTANT]
> **A single `terraform apply` of this root cannot succeed.** The apply is
> staged, and the stages are not optional.
>
> `modules/platform_cluster_bootstrap` writes Argo CD objects with the
> `kubernetes` provider, whose endpoint comes from the cluster that does not
> exist yet. Worse, `kubernetes_manifest` validates against the live API server
> at **plan** time, so the Argo CD `ApplicationSet` CRD must already be
> installed before the untargeted root can even be planned. That CRD arrives
> with the Argo CD capability, which stage 6c creates.

**6a. Initialize:**

```bash
terraform -chdir=environments/platform init -backend-config=backend.hcl
```

**6b. Create the Identity Center group and the GitHub connection only:**

```bash
terraform -chdir=environments/platform apply \
  -target=aws_identitystore_group.argocd_admins \
  -target=aws_identitystore_group_membership.argocd_admins \
  -target=aws_codeconnections_connection.github
```

**6c. Authorize the connection — a human step in the console.** The connection
is created `PENDING`. Open **AWS Developer Tools → Settings → Connections**,
select `<resource_prefix>-github`, complete the GitHub handshake, and restrict
the GitHub App installation to your fork alone.

```bash
aws codeconnections get-connection \
  --connection-arn "$(terraform -chdir=environments/platform output -raw github_connection_arn)" \
  --query 'Connection.ConnectionStatus' --output text
```

Do not continue while this reads `PENDING` — the Argo CD capability would be
created with a connection it cannot use. See
[GitHub CodeConnections](docs/operations/github-connection.md).

**6d. Build the cluster:**

```bash
terraform -chdir=environments/platform plan -target=module.platform_cluster -out=tfplan
terraform -chdir=environments/platform apply tfplan
```

About 80 resources and 20-30 minutes: the VPC with six subnets across three AZs,
one NAT gateway, the EKS cluster, three Fargate profiles, two KMS keys, four
CloudWatch log groups, VPC Flow Logs, CoreDNS, the IRSA roles, and the three EKS
capabilities. The `Resource targeting is in effect` warning is expected here.

If CoreDNS stalls `Pending` with no scheduling events, apply the one conditional
restart in
[deploy the platform](docs/operations/deploy-platform.md#coredns-may-need-one-manual-restart).
On a clean deployment it is not needed.

**6e. Push your branch before the final apply.** Argo CD reads GitHub, not your
working tree:

```bash
git push origin main
```

**6f. Apply the untargeted root:**

```bash
terraform -chdir=environments/platform plan -out=tfplan
terraform -chdir=environments/platform apply tfplan
```

The plan must add only `module.platform_cluster_bootstrap` resources and show
**no changes** to `module.platform_cluster`. Changes to already-applied cluster
resources mean stage 6d ran with different inputs — stop and reconcile first.

### 7. Wait for the capabilities

All three EKS capabilities must reach `ACTIVE`. `DEGRADED`, `CREATE_FAILED`,
`UPDATE_FAILED`, and `DELETING` are terminal — stop and read
[managed EKS capabilities](docs/operations/capabilities.md).

```bash
cluster="$(terraform -chdir=environments/platform output -raw cluster_name)"
for capability in argocd ack kro; do
  aws eks describe-capability --cluster-name "$cluster" \
    --capability-name "${cluster}-${capability}" --region "$AWS_REGION" \
    --query 'capability.status' --output text
done
```

### 8. Configure kubectl

```bash
aws eks update-kubeconfig --name "$cluster" --region "$AWS_REGION"
kubectl api-resources | grep -E 'applications|applicationsets|resourcegraphdefinitions|iamroleselectors'
```

Add `--profile <name>` if you are not on the default profile. All four API
groups must be present. See [cluster access](docs/operations/cluster-access.md).

Argo CD then discovers `gitops/platform/bootstrap/` and fans out to the addons,
observability, kro definitions and workloads ApplicationSets:

```bash
kubectl -n argocd get applications -o wide
kubectl get nodes -L eks.amazonaws.com/compute-type
```

Every node must report `fargate`. Pods only get capacity in a namespace a
Fargate profile selects: `kube-system`, `argo-rollouts`, `cert-manager`,
`opentelemetry-operator-system`, `amazon-cloudwatch`, and `apps-*`. A Pod
anywhere else stays `Pending` forever with no scheduling event.

### 9. Verify

```bash
./scripts/verify-platform.sh
./scripts/check-drift.sh
```

`verify-platform.sh` must print `PASS` on every assertion and exit `0`. The
static gates run without AWS credentials and are what CI enforces:

```bash
make terraform-check
make yaml-check
make shell-check
```

### 10. Deploy the example workload

Jenkins needs **no further Terraform**. It is already declared in
`gitops/workloads/`, so Argo CD deploys it as part of the bootstrap fan-out:

```bash
kubectl -n argocd get applications | grep jenkins
kubectl -n apps-jenkins get pods,pvc,ingress
```

Expect the Application `Synced`/`Healthy`, the controller Pod `Running`, the
`jenkins-home` PVC `Bound`, and the Ingress carrying an ALB address. See
[deploy Jenkins](docs/operations/deploy-jenkins.md) for a test pipeline that
proves Fargate agents work.

From now on, run acceptance with workloads expected — the default asserts the
greenfield non-goals and will report `FAIL` the moment a workload the platform
exists to host actually runs:

```bash
EXPECT_WORKLOADS=true ./scripts/verify-platform.sh
```

### 11. Find your application

Infrastructure facts come from Terraform:

```bash
terraform -chdir=environments/platform output
terraform -chdir=environments/platform output -raw cluster_name
```

Live URLs do not. The public ALB is created by the load balancer controller
after Argo CD syncs an Ingress, long after `terraform apply` returns, so it is
not a Terraform output. Use:

```bash
./scripts/platform-info.sh
```

```text
Cluster
  Name           aws-eks-infra-platform
  Status         ACTIVE
  Region         ap-southeast-1
  Account        <account-id>
  Endpoint       https://XXXX.gr7.ap-southeast-1.eks.amazonaws.com

GitOps
  Repository     https://codeconnections.ap-southeast-1.amazonaws.com/git-http/...
  Connection     AVAILABLE

Public ALB
  DNS            platform-public-1234567890.ap-southeast-1.elb.amazonaws.com
  State          active

Workloads
  apps-jenkins   http://platform-public-1234567890.ap-southeast-1.elb.amazonaws.com/jenkins

Jenkins sign-in
  User           admin
  Password       kubectl -n apps-jenkins get secret jenkins \
                   -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
```

Open the Jenkins URL and sign in as `admin`. All workloads share one
internet-facing ALB named `platform-public` and are routed by path prefix; `/`
returns 404 by design, because the group has no catch-all member.

> [!WARNING]
> The ALB is HTTP-only and open to `0.0.0.0/0` by design, so credentials cross
> the internet in cleartext. To avoid that, skip the ALB entirely:
>
> ```bash
> kubectl -n apps-jenkins port-forward svc/jenkins 8080:8080
> # http://localhost:8080/jenkins
> ```
>
> To restrict the ALB's source range instead, add
> `alb.ingress.kubernetes.io/inbound-cidrs` to the Ingress — see
> [public workload access](docs/operations/public-workload-access.md).

To expose your own workload, put it in an `apps-*` namespace and copy the
IngressGroup annotation block from
[public workload access](docs/operations/public-workload-access.md). It is a
pure-GitOps change; Terraform is not involved.

## Tearing Down

Delete workload ApplicationSets **first**. Their Ingresses are backed by an ALB
that Terraform has no record of; destroy the cluster first and the load balancer
is orphaned, and its ENIs and security groups then block the VPC destroy.

```bash
kubectl -n argocd delete applicationset jenkins
aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text  # 0
./scripts/destroy-platform.sh "destroy platform"
```

The literal argument is required and there is no `-auto-approve`. By default the
CodeConnections connection and the Identity Center group survive, because
re-authorizing the GitHub App is a manual console step; use
`DESTROY_ROOT=true` to remove them too.

Two things legitimately remain: KMS keys in `PendingDeletion` for 30 days, and
stale entries in the Resource Groups Tagging API. `bootstrap/terraform-state` is
never touched. See [destroy the platform](docs/operations/destroy-platform.md).

## Validation

```bash
make terraform-check
make yaml-check
make shell-check
```

These are the local and CI quality gates. The `terraform-ci`, `yaml-ci`, and `shell-ci` workflows run the same checks with pinned tool versions; pull-request workflows do not receive AWS credentials and never apply infrastructure. Adding a Terraform root requires updating both `TF_ROOTS` in the `Makefile` and the root list in `.github/workflows/terraform-ci.yaml`.

Before deploying from scratch, read [first deployment defects](docs/operations/first-deployment-defects.md). It records the ten defects found during the first end-to-end deployment — none of which `make terraform-check`, `make yaml-check`, or CI can catch — along with the Argo CD and Fargate invariants they established.

## GitHub Protection

After the `terraform-ci` and `yaml-ci` workflows have each passed once on `main`, configure a GitHub ruleset for `main` that requires both checks, requires pull requests, and blocks force pushes. This one-time GitHub setting is intentionally not managed through Terraform.

## Runbook Reference

The README is the happy path. These are authoritative for everything else.

| Runbook | Covers |
| --- | --- |
| [terraform-state](docs/operations/terraform-state.md) | The S3/KMS state foundation and its migration |
| [deploy-platform](docs/operations/deploy-platform.md) | The staged apply in full, with recovery for every stage |
| [github-connection](docs/operations/github-connection.md) | CodeConnections authorization |
| [capabilities](docs/operations/capabilities.md) | Argo CD, ACK and kro capability lifecycle |
| [cluster-access](docs/operations/cluster-access.md) | kubeconfig and the Fargate namespace contract |
| [deploy-jenkins](docs/operations/deploy-jenkins.md) | The example workload end to end |
| [public-workload-access](docs/operations/public-workload-access.md) | Joining the shared ALB; TLS/DNS upgrade path |
| [observability](docs/operations/observability.md) | Logs, metrics and traces |
| [telemetry-validation](docs/operations/telemetry-validation.md) | Confirming telemetry actually flows |
| [validate-platform](docs/operations/validate-platform.md) | Every gate, static and live |
| [destroy-platform](docs/operations/destroy-platform.md) | Guarded teardown |
| [first-deployment-defects](docs/operations/first-deployment-defects.md) | Ten defects from the first real deployment that no gate catches |
