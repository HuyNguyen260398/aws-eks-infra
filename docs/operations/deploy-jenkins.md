# Deploy Jenkins

Jenkins is the first example workload on the Fargate-only platform. It is
deployed by Argo CD from the upstream `jenkins/jenkins` Helm chart plus the
local `jenkins-storage` chart, and runs entirely on AWS Fargate.

## Prerequisites

- The platform is applied and healthy (`./scripts/verify-platform.sh`).
- Terraform has been applied since the EFS filesystem and Jenkins access point
  were added, so the Argo CD cluster Secret carries `efs_file_system_id` and
  `jenkins_efs_access_point_id`.
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
`Running`, the `jenkins-home` PVC is `Bound`, and the `jenkins` Ingress has a
public ALB address.

## Retrieve the admin password

```bash
kubectl -n apps-jenkins get secret jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d; echo
```

The admin user is `admin`.

## Reach the UI

Jenkins is served on the shared public ALB under `/jenkins`:

```bash
aws elbv2 describe-load-balancers --names platform-public \
  --query 'LoadBalancers[0].DNSName' --output text
# open http://<dns-name>/jenkins
```

See [public workload access](public-workload-access.md). The admin UI shows a
"Jenkins URL is not set" monitor: the ALB hostname is assigned by AWS and cannot
be templated in, so JCasC falls back to the in-cluster URL. That URL is the
correct one for the agent JNLP handshake, so the warning is cosmetic. To clear
it, paste the ALB name into Manage Jenkins → System → Jenkins URL.

If you would rather not go over the internet, port-forward instead:

```bash
kubectl -n apps-jenkins port-forward svc/jenkins 8080:8080
# open http://localhost:8080/jenkins
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
