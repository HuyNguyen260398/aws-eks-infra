#!/usr/bin/env bash
set -euo pipefail

fail=0
check() { if "$@" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
for tool in terraform aws kubectl helm tflint checkov yamllint kubeconform git; do check command -v "$tool"; done
if terraform version -json | jq -e '.terraform_version | split(".") | .[0:2] | map(tonumber) | .[0] > 1 or (.[0] == 1 and .[1] >= 10)' >/dev/null; then echo "PASS terraform >= 1.10"; else echo "FAIL terraform >= 1.10"; fail=1; fi
check aws sts get-caller-identity
if aws configure get region >/dev/null 2>&1; then echo "PASS configured AWS Region"; else echo "FAIL configured AWS Region"; fail=1; fi
if [ "$(aws sso-admin list-instances --query 'length(Instances)' --output text 2>/dev/null)" = "1" ]; then echo "PASS one Identity Center instance"; else echo "FAIL one Identity Center instance"; fail=1; fi
if git ls-remote --exit-code https://github.com/HuyNguyen260398/aws-eks-infra.git HEAD >/dev/null 2>&1; then echo "PASS GitHub repository access"; else echo "FAIL GitHub repository access"; fail=1; fi
exit "$fail"
