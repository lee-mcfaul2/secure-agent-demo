#!/usr/bin/env bash
set -euo pipefail

# Smoke test for the umbrella chart. Runs:
#   1. `helm dependency update` to pull all subchart sources
#   2. `helm lint` against both values files
#   3. `helm template` to verify the chart renders to non-empty YAML
#
# NOT EXPECTED TO PASS until:
#   - The three in-tree subcharts exist under chart/charts-local/ (added in T14, T16, T17)
#   - The five OCI charts at oci://ghcr.io/lee-mcfaul2/charts/* are published
#
# Until then, run `helm show chart chart/` for a smoke check on Chart.yaml alone.
#
# Requires: helm v3.14+ on PATH.

if ! command -v helm >/dev/null 2>&1; then
  echo "helm not found on PATH" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

echo "==> helm dependency update"
helm dependency update chart/

echo "==> helm lint (values-demo)"
helm lint chart/ -f chart/values-demo.yaml

echo "==> helm template (values-demo) — sanity render"
helm template ai-security chart/ -f chart/values-demo.yaml > /tmp/render-demo.yaml
test -s /tmp/render-demo.yaml

echo "==> helm template (values-ci) — sanity render"
helm template ai-security chart/ -f chart/values-ci.yaml > /tmp/render-ci.yaml
test -s /tmp/render-ci.yaml

echo "PASS"
