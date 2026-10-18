#!/usr/bin/env bash
# Render the OpenTelemetry Collector add-on the way Argo CD would, without a
# cluster. Writes into <out-dir>:
#
#   manifests.yaml  helm template of the chart source + kustomize build of the
#                   observability source
#   config.yaml     the collector config (the rendered ConfigMap's relay key)
#
# The ApplicationSet's Go-template placeholders are replaced with this
# platform's values; any placeholder left over fails the render.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <out-dir>" >&2
  exit 2
fi
out="$1"
mkdir -p "$out"

cd "$(dirname "$0")/.."
appset=gitops/platform/config/addons/opentelemetry-collector.yaml
chart_source='.spec.template.spec.sources[0]'

repo_url="$(yq "$chart_source.repoURL" "$appset")"
chart="$(yq "$chart_source.chart" "$appset")"
version="$(yq "$chart_source.targetRevision" "$appset")"
release="$(yq "$chart_source.helm.releaseName" "$appset")"

values="$out/values.yaml"
yq "$chart_source.helm.values" "$appset" |
  sed -e 's|{{ \.metadata\.annotations\.aws_region }}|ap-southeast-1|g' \
    -e 's|{{ \.metadata\.annotations\.platform_parameter_prefix }}|/aws-eks-infra/platform|g' >"$values"
if grep -n '{{' "$values" >&2; then
  echo "unreplaced Go-template placeholder in $appset helm values" >&2
  exit 1
fi

helm template "$release" "$chart" --repo "$repo_url" --version "$version" \
  --namespace observability -f "$values" >"$out/manifests.yaml"
{
  echo "---"
  kubectl kustomize gitops/platform/config/observability
} >>"$out/manifests.yaml"

yq ea 'select(.kind == "ConfigMap" and has("data") and (.data | has("relay"))) | .data.relay' \
  "$out/manifests.yaml" >"$out/config.yaml"
if [ ! -s "$out/config.yaml" ]; then
  echo "no ConfigMap with a relay key in the render" >&2
  exit 1
fi

echo "$out"
