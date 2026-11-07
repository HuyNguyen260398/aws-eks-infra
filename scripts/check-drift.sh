#!/usr/bin/env bash
# Report drift on both stateful roots. See docs/operations/validate-platform.md.
#
# `plan -refresh-only -detailed-exitcode` returns 2 whenever the refresh would
# write anything back to state, which includes a completely empty plan - no
# resource diffs, no output changes, no "Objects have changed" note. Gating on
# that exit code reports FAIL on a converged platform, so this inspects the JSON
# plan instead:
#
#   resource_drift    the real object changed outside Terraform
#   resource_changes  state no longer matches configuration
#
# Both roots are always checked, so one drifting root does not hide the other.
#
# Some attributes are read-only counters that AWS updates as the workload runs.
# They appear in resource_drift on every refresh forever, which would make this
# gate permanently red and therefore ignored. IGNORED_DRIFT_ATTRS lists them per
# resource type. A drift entry is suppressed only when *every* differing
# attribute is on its type's list, so a real change alongside a counter still
# fails. Keep the lists minimal and justify each entry.
set -euo pipefail

# aws_efs_file_system.size_in_bytes: metered capacity. Jenkins writing to
# /jenkins-home moves it on every refresh; it is not settable in configuration.
IGNORED_DRIFT_ATTRS='{
  "aws_efs_file_system": ["size_in_bytes"]
}'

plan_dir="$(mktemp -d)"
trap 'rm -rf "$plan_dir"' EXIT

status=0

for root in bootstrap/terraform-state environments/platform; do
  plan="$plan_dir/${root//\//_}.tfplan"

  if ! terraform -chdir="$root" plan -refresh-only -out="$plan" -input=false >"$plan.log" 2>&1; then
    echo "FAIL could not plan $root"
    sed 's/^/    /' "$plan.log"
    status=1
    continue
  fi

  json="$(terraform -chdir="$root" show -json "$plan")"

  drifted="$(
    printf '%s' "$json" |
      jq -r --argjson ignored "$IGNORED_DRIFT_ATTRS" '
        # Attributes whose refreshed value differs from the value in state.
        def diff_keys($b; $a):
          ((($b // {}) | keys_unsorted) + (($a // {}) | keys_unsorted))
          | unique
          | map(select((($b // {})[.]) != (($a // {})[.])));

        (.resource_drift // [])[]
        | . as $d
        | (diff_keys($d.change.before; $d.change.after) - ($ignored[$d.type] // [])) as $material
        | select(($material | length) > 0)
        | "    drifted outside Terraform: \($d.address) [\($material | join(","))]"
      '
  )"
  changed="$(
    printf '%s' "$json" | jq -r '
      (.resource_changes // [])[]
      | select(.change.actions != ["no-op"] and .change.actions != ["read"])
      | "    differs from configuration: \(.address) [\(.change.actions | join(","))]"
    '
  )"

  if [ -z "$drifted" ] && [ -z "$changed" ]; then
    echo "PASS no drift in $root"
  else
    echo "FAIL drift in $root"
    [ -z "$drifted" ] || echo "$drifted"
    [ -z "$changed" ] || echo "$changed"
    status=1
  fi
done

exit "$status"
