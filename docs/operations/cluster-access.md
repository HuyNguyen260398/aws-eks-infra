# EKS Cluster Access

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

## Verify capacity

```bash
cluster="$(terraform -chdir=environments/platform output -raw cluster_name)"
aws eks describe-nodegroup --cluster-name "$cluster" --nodegroup-name "${cluster}-general" --query 'nodegroup.status' --output text
kubectl get nodes -L kubernetes.io/arch,eks.amazonaws.com/capacityType,node.kubernetes.io/instance-type
kubectl -n kube-system get deployment coredns
```

The node group must be `ACTIVE` with one `arm64` `SPOT` node (`t4g.medium` by default), and CoreDNS must be available. There are no Fargate profiles.

## Capacity contract

Everything runs on the one node: the EKS add-ons, the GitOps add-ons (when Argo CD is on) and Cashight. Memory is the limit, not Pod count — prefix delegation and `maxPods: 110` lift the per-node Pod limit. When `kubectl describe pod` shows `Insufficient memory`, raise `node_count` or list larger Graviton types in `node_instance_types`.

A Spot interruption replaces the node; every Pod is down until the new node is `Ready`, typically a few minutes.
