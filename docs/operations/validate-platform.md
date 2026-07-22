# Validate the platform

Static gates run with no AWS credentials. Live gates require credentials and a current kubeconfig.

## Static gates

```bash
make terraform-check   # fmt -check + validate every root + tflint + checkov
make yaml-check        # yamllint + helm lint/template + kubeconform + kustomize build
```

Both must exit `0`. CI runs the same checks with pinned tool versions and never receives AWS credentials.

A Terraform root is only validated if it contains `versions.tf` — the Makefile and the workflow both skip roots without it. A new root must be added to `TF_ROOTS` in the `Makefile` **and** the `roots=(...)` array in `.github/workflows/terraform-ci.yaml`, or CI silently stops validating it.

## Live gates

```bash
./scripts/verify-prerequisites.sh   # tooling and AWS account preflight; mutates nothing
./scripts/verify-platform.sh        # acceptance
./scripts/check-drift.sh            # plan -refresh-only -detailed-exitcode on both stateful roots
```

`verify-platform.sh` prints one `PASS`/`FAIL` line per assertion and exits nonzero if any fail:

- CodeConnections `AVAILABLE`, EKS and all Fargate profiles `ACTIVE`
- `aws eks list-nodegroups` empty — the Fargate-only invariant
- Argo CD, ACK, and kro capabilities `ACTIVE`
- CoreDNS, AWS Load Balancer Controller, Argo Rollouts, and the ADOT operator available
- every Argo CD Application `Synced` and `Healthy`
- no `apps-*` workload, no Ingress, no LoadBalancer Service

`check-drift.sh` passes only on detailed exit code `0`. Exit code `2` means real drift: inspect the refresh plan before reconciling, since capabilities use `RETAIN` and are not recreated by a plain apply.

Failures map to the recovery procedures in [deploy the platform](deploy-platform.md#recovery).
