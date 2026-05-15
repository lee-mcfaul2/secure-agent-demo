#!/usr/bin/env bash
set -euo pipefail

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
