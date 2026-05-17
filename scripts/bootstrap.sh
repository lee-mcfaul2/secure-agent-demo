#!/usr/bin/env bash
set -euo pipefail

# bootstrap.sh — turn a bare clone of this repo into a running demo.
#
# The umbrella chart pulls 13 subcharts: 5 infra charts from public HTTP Helm
# repos (linkerd, spiffe, prometheus-community, dex, bitnami) and 8 local
# file://./charts-local/* charts (the 5 patched platform components plus
# demo-ui, local-llm, and traffic-gen). No subcharts are pulled from any
# remote container registry.
# The .tgz archives are deliberately gitignored (chart/charts/*.tgz), so a
# fresh clone has nothing under chart/charts/. This script registers the HTTP
# repos that dependency resolution needs, fetches every dependency, and installs.
#
# Usage:
#   ./scripts/bootstrap.sh                 # add repos, fetch deps, install
#   SKIP_INSTALL=1 ./scripts/bootstrap.sh  # only add repos + fetch deps
#
# Override the release/namespace via env: RELEASE, NAMESPACE, VALUES, HELM_TIMEOUT.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

RELEASE="${RELEASE:-ai-security}"
NAMESPACE="${NAMESPACE:-platform}"
VALUES="${VALUES:-chart/values-demo.yaml}"
HELM_TIMEOUT="${HELM_TIMEOUT:-20m}"

# HTTP Helm repos the umbrella resolves against. `helm dependency update`
# errors with "no repository definition for ..." unless these are
# registered first — this is the step the README was missing.
declare -A REPOS=(
  [linkerd]="https://helm.linkerd.io/stable"
  [spiffe]="https://spiffe.github.io/helm-charts-hardened/"
  [prometheus-community]="https://prometheus-community.github.io/helm-charts"
  [dex]="https://charts.dexidp.io"
  [bitnami]="https://charts.bitnami.com/bitnami"
)

echo "==> 1. Registering Helm repositories"
for name in "${!REPOS[@]}"; do
  # helm repo add is idempotent with --force-update; safe to re-run.
  helm repo add "$name" "${REPOS[$name]}" --force-update >/dev/null
  echo "    $name -> ${REPOS[$name]}"
done
helm repo update >/dev/null
echo "    helm repo update OK"

echo "==> 2. helm dependency update (resolves + fetches all 13 subcharts)"
# `update` not `build`: all platform charts (plus demo-ui, local-llm, and
# traffic-gen) are local file://./charts-local/* overrides, so Chart.lock is
# regenerated here rather than committed. This also recreates chart/charts/
# from scratch on every run.
helm dependency update ./chart

if [[ "${SKIP_INSTALL:-0}" == "1" ]]; then
  echo "==> SKIP_INSTALL=1 set — dependencies fetched, not installing."
  exit 0
fi

echo "==> 3. Creating namespaces"
# The umbrella spans four namespaces and several subcharts ship pre-install
# hooks (e.g. agent-sql-mcp's DB migration Job in namespace mcp). Helm runs
# pre-install hooks BEFORE normal manifests, so a chart-templated Namespace
# can't exist in time — the hook fails with `namespaces "mcp" not found`.
# Namespaces must therefore be created out-of-band, before Helm runs. This is
# idempotent (kubectl apply) and replaces the old chart/templates/namespaces.yaml.
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata: { name: platform, labels: { linkerd.io/inject: enabled } }
---
apiVersion: v1
kind: Namespace
metadata: { name: gateway, labels: { linkerd.io/inject: enabled } }
---
apiVersion: v1
kind: Namespace
metadata: { name: mcp, labels: { linkerd.io/inject: enabled } }
---
apiVersion: v1
kind: Namespace
metadata: { name: sandbox, labels: { linkerd.io/inject: enabled } }
EOF

echo "==> 4. Preflight: clear any stuck prior ${RELEASE} state (scoped; shared cluster safe)"
status=$(helm -n "$NAMESPACE" status "$RELEASE" -o json 2>/dev/null | jq -r '.info.status // empty' 2>/dev/null || true)
if [ -n "$status" ] && [ "$status" != "deployed" ]; then
  echo "    release status=$status (not deployed) — uninstalling ${RELEASE} only"
  helm uninstall "$RELEASE" -n "$NAMESPACE" --wait --timeout 120s 2>/dev/null || true
fi
# leftover Succeeded hook pod pins the hook PVC — delete by exact label+phase only
kubectl -n "$NAMESPACE" delete pod -l job-name=bundle-fetcher \
  --field-selector=status.phase=Succeeded --ignore-not-found 2>/dev/null || true
# orphaned hook PVC (NOT chart-managed): delete this ONE named PVC; clear finalizer if it hangs
if kubectl -n "$NAMESPACE" get pvc prompt-bundle >/dev/null 2>&1; then
  kubectl -n "$NAMESPACE" delete pvc prompt-bundle --timeout=60s 2>/dev/null \
    || kubectl -n "$NAMESPACE" patch pvc prompt-bundle --type=merge \
         -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
fi
# stale release records, scoped to THIS release's helm secrets only
if [ -n "$status" ] && [ "$status" != "deployed" ]; then
  kubectl -n "$NAMESPACE" delete secret -l owner=helm,name="$RELEASE" \
    --ignore-not-found 2>/dev/null || true
fi

echo "==> 5. helm upgrade --install ${RELEASE} -> namespace ${NAMESPACE}"
helm upgrade --install "$RELEASE" ./chart \
  --namespace "$NAMESPACE" \
  -f "$VALUES" --wait --timeout "$HELM_TIMEOUT"

echo
echo "==> bootstrap PASS — components are up. Reach them with:"
echo "    kubectl -n ${NAMESPACE} port-forward svc/agent-gateway 8080:8080"
echo "    kubectl -n ${NAMESPACE} port-forward svc/demo-ui       8081:80"
echo "    kubectl -n ${NAMESPACE} port-forward svc/${RELEASE}-grafana 3000:80"
