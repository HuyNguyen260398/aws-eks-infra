#!/usr/bin/env bash
set -euo pipefail
for root in bootstrap/terraform-state environments/platform; do
  set +e; terraform -chdir="$root" plan -refresh-only -detailed-exitcode -input=false; code=$?; set -e
  [ "$code" = 0 ] || { echo "FAIL drift in $root"; exit "$code"; }
  echo "PASS no drift in $root"
done
