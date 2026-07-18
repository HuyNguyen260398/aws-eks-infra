# Terraform State Foundation

The `bootstrap/terraform-state` root creates the protected S3 bucket and KMS key used by every Terraform root. It is intentionally separate from normal platform destruction.

## Bootstrap

Copy `terraform.tfvars.example` to a local `terraform.tfvars`, then run:

```bash
terraform -chdir=bootstrap/terraform-state init
terraform -chdir=bootstrap/terraform-state plan -out=tfplan
terraform -chdir=bootstrap/terraform-state apply tfplan
```

After the first apply, add `backend.tf`, derive the bucket and KMS key outputs, and re-run `terraform init -migrate-state` with `use_lockfile=true`. Do not create a DynamoDB lock table.

## Recovery

The bucket and KMS key use `prevent_destroy`; do not remove those lifecycle protections. State recovery uses S3 versioning and the KMS key retained by this bootstrap root.
