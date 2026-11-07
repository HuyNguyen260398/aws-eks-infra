# EKS Fargate Cluster Access

The `platform` root creates one Amazon EKS cluster with both private and CIDR-restricted public API access. Use an IAM principal authorized for the AWS account and a source address included in `public_access_cidrs`. The Terraform caller receives cluster administrator permissions through EKS access entries.

## Prerequisites

- The remote Terraform state foundation is applied and local `backend.hcl` and `terraform.tfvars` files are configured.
- AWS CLI v2, `kubectl`, and Terraform are installed.
- The AWS CLI profile has permission to call `eks:DescribeCluster` and retrieve an EKS authentication token.

## Configure kubeconfig

After the platform Terraform apply has completed, update a dedicated kubeconfig context:

```bash
aws eks update-kubeconfig \
  --region <aws-region> \
  --name "$(terraform -chdir=environments/platform output -raw cluster_name)"
```

If the AWS profile is not the default profile, add `--profile <profile-name>` to the command.

## Verify serverless compute

```bash
aws eks list-nodegroups \
  --cluster-name "$(terraform -chdir=environments/platform output -raw cluster_name)"
aws eks list-fargate-profiles \
  --cluster-name "$(terraform -chdir=environments/platform output -raw cluster_name)"
kubectl get nodes -L eks.amazonaws.com/compute-type
kubectl -n kube-system get deployment coredns
```

The node group list must be empty. The Fargate profile list must contain the system, platform-addons, and future-workloads profiles. CoreDNS must become available on Fargate. Nodes are created on demand, so `kubectl get nodes` can be empty until matching Pods require capacity; any displayed nodes must be labeled `fargate`.

## Namespace contract

Fargate scheduling is limited to `kube-system`, `argo-rollouts`, `cert-manager`, `opentelemetry-operator-system`, `amazon-cloudwatch`, and future `apps-*` namespaces. Workloads outside these selectors do not receive Fargate capacity. Do not create managed node groups or other non-Fargate compute for this platform.
