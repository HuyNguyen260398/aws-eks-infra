<div align="center">

# Cashight EKS Platform

**Terraform and GitOps for the single, low-cost Amazon EKS cluster that hosts Cashight.**

[![Terraform](https://img.shields.io/badge/Terraform-1.10%2B-844FBA?logo=terraform&logoColor=white)](https://www.terraform.io/)
[![Amazon EKS](https://img.shields.io/badge/Amazon%20EKS-1.35-FF9900)](https://aws.amazon.com/eks/)
[![Graviton Spot](https://img.shields.io/badge/EC2-Graviton%20Spot-FF9900)](https://aws.amazon.com/ec2/graviton/)
[![Argo CD](https://img.shields.io/badge/Argo%20CD-GitOps-EF7B4D?logo=argo&logoColor=white)](https://argo-cd.readthedocs.io/)
[![Checkov](https://img.shields.io/badge/Checkov-scanned-7D3C98)](https://www.checkov.io/)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE.md)

</div>

This repository began as a general-purpose EKS reference platform (Fargate,
Jenkins, ACK, kro, CloudWatch/ADOT observability). It has been cut down to what
[Cashight](https://github.com/HuyNguyen260398/cashight) needs, at the lowest cost
that still runs it.

## What it builds

- A three-AZ VPC. The node runs in a **public subnet** with its own public IPv4
  address, so there is **no NAT gateway**; private subnets hold only the EKS
  control-plane ENIs.
- Amazon EKS 1.35 with **one Spot Graviton node** (`t4g.medium`, `m7g.medium` or
  `m6g.medium`, 4 GiB). VPC CNI with NetworkPolicy enforcement and prefix
  delegation, kube-proxy, CoreDNS, EKS Pod Identity Agent.
- **Managed Argo CD, opt-in** (`enable_argocd`, default `false`) through AWS
  CodeConnections. When on, it installs from `gitops/`: AWS Load Balancer
  Controller, cert-manager, Argo Rollouts, KEDA, and the guarded `cashight`
  namespace (Pod Security `restricted`, default-deny NetworkPolicies, quota).
- IAM for the load balancer controller (IRSA) and KEDA (EKS Pod Identity).
- An account-wide monthly **budget alarm**.
- SSM parameters under `/<resource_prefix>/platform/` that Cashight's Terraform
  reads instead of hardcoding cluster identifiers.
- S3/KMS remote state with native S3 lockfiles.

Telemetry is not part of the platform yet; Cashight's observability plan adds it.

## Cost

Singapore list prices, 730 hours a month. Verify before relying on them.

| Item | USD / month |
| --- | ---: |
| EKS control plane | 73 |
| 1 × Spot 4 GiB Graviton node (on-demand `t4g.medium` ≈ 31) | ≈ 14 |
| 20 GB gp3 root volume, node public IPv4 | ≈ 6 |
| Control-plane logs (audit + authenticator), KMS keys | ≈ 3 |
| **Platform without Argo CD** | **≈ 96** |
| Managed Argo CD (`enable_argocd = true`) | ≈ 27 + 1.32 per Application |
| Shared ALB once a workload has an Ingress | ≈ 26 |

Nothing here is covered by the AWS free tier. The EKS control plane bills from
the moment the cluster exists, so create the cluster only when there is
something to run on it, and tear it down when there is not.

## Repository structure

```text
aws-eks-infra/
├── bootstrap/terraform-state/        S3 + KMS remote-state foundation
├── environments/platform/            The only deployable root: budget, Identity Center
│                                     group, CodeConnections, published identifiers
├── modules/
│   ├── platform_cluster/             VPC, EKS, node group, add-ons, IAM, optional Argo CD
│   └── platform_cluster_bootstrap/   Terraform → Argo CD handoff (only with enable_argocd)
├── gitops/
│   ├── platform/
│   │   ├── bootstrap/                ApplicationSets Argo CD reconciles first
│   │   ├── config/addons/            LB controller, cert-manager, Argo Rollouts, KEDA
│   │   ├── config/namespaces/        Tenant namespaces (cashight)
│   │   └── charts/namespace-config/  Namespace, quota, limits, NetworkPolicy chart
│   └── workloads/manifests/          Plain workload manifests (empty placeholder)
├── scripts/                          Preflight, acceptance, repo-access probe, drift, teardown
├── docs/operations/                  Runbooks
├── .github/workflows/                terraform-ci, yaml-ci, shell-ci (no AWS credentials)
└── Makefile                          terraform-check, yaml-check, shell-check
```

## Deploying

Follow [deploy the platform](docs/operations/deploy-platform.md). In short:

1. Preflight: `./scripts/verify-prerequisites.sh`.
2. State foundation: [Terraform state](docs/operations/terraform-state.md).
3. Copy `environments/platform/terraform.tfvars.example` and `backend.hcl.example`
   to their ignored local names and fill them in.
4. Apply the budget, the Identity Center group and the CodeConnections connection
   first, then authorize the connection in the console for **both** this
   repository and `cashight`.
5. Apply the root. With `enable_argocd = false` this is a single apply.
6. Accept: `./scripts/verify-platform.sh`.
7. When Cashight is ready to deploy, set `enable_argocd = true` and follow the
   staged Argo CD apply in the same runbook.

`terraform.tfvars`, `backend.hcl`, `tfplan` and `*.tfstate` are gitignored and
must never be committed.

## Tearing down

```bash
./scripts/destroy-platform.sh "destroy platform"
```

Delete any Ingress first: its ALB is not in Terraform state and would block the
VPC destroy. The script refuses while one exists. The budget, the CodeConnections
connection and the Identity Center group survive unless `DESTROY_ROOT=true`. See
[destroy the platform](docs/operations/destroy-platform.md).

## Validation

```bash
make terraform-check
make yaml-check
make shell-check
```

The `terraform-ci`, `yaml-ci` and `shell-ci` workflows run the same checks with
pinned tool versions and never receive AWS credentials. Adding a Terraform root
requires updating both `TF_ROOTS` in the `Makefile` and the root list in
`.github/workflows/terraform-ci.yaml`.

## Runbooks

| Runbook | Covers |
| --- | --- |
| [terraform-state](docs/operations/terraform-state.md) | The S3/KMS state foundation and its migration |
| [deploy-platform](docs/operations/deploy-platform.md) | The apply, and turning Argo CD on |
| [github-connection](docs/operations/github-connection.md) | CodeConnections authorization and repository access |
| [capabilities](docs/operations/capabilities.md) | The managed Argo CD capability |
| [cluster-access](docs/operations/cluster-access.md) | kubeconfig and node capacity |
| [public-workload-access](docs/operations/public-workload-access.md) | Joining the shared ALB |
| [validate-platform](docs/operations/validate-platform.md) | Every gate, static and live |
| [destroy-platform](docs/operations/destroy-platform.md) | Guarded teardown |
| [first-deployment-defects](docs/operations/first-deployment-defects.md) | Defects from the original Fargate deployment (historical) |

`docs/architecture/` holds diagrams of the original reference design. They
predate the cut-down and are not current.
