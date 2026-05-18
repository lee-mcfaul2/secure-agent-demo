#!/usr/bin/env bash
set -euo pipefail

# bootstrap.sh — turn a bare clone of this repo into a running demo.
#
# The umbrella chart pulls 12 subcharts: 4 infra charts from public HTTP Helm
# repos (spiffe, prometheus-community, dex, bitnami) and 8 local
# file://./charts-local/* charts (the 5 patched platform components plus
# demo-ui, local-llm, and traffic-gen). No subcharts are pulled from any
# remote container registry. The Linkerd control plane is NOT in the umbrella —
# it is installed as its own release in the `linkerd` namespace (step 5).
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
# prompt-bundle PVC + bundle-fetcher hook live in the gateway ns (their only
# consumer, agent-gateway, runs there; PVCs can't be mounted cross-namespace).
BUNDLE_NS="${BUNDLE_NS:-gateway}"
VALUES="${VALUES:-chart/values-demo.yaml}"
HELM_TIMEOUT="${HELM_TIMEOUT:-7m}"
WATCH_INTERVAL="${WATCH_INTERVAL:-15}"     # secs between live pod snapshots
HELM_LOG="${HELM_LOG:-/tmp/ai-security-helm.log}"
NS_ALL=(linkerd platform gateway mcp sandbox)

# Live pod table across all four demo namespaces (read-only; shared-cluster safe).
snapshot() {
  echo "    ---- pod snapshot $(date +%H:%M:%S) (not-ready first) ----"
  for ns in "${NS_ALL[@]}"; do
    out=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null) || continue
    [ -z "$out" ] && continue
    echo "    [$ns]"
    # "bad" = phase not Running/Completed OR a Running pod whose READY column
    # is a/b with a<b (a container is up but not Ready — exactly what blocks
    # `helm --wait`). Print bad first, then the rest.
    echo "$out" | awk 'function bad(){n=split($2,r,"/");return ($3!="Running"&&$3!="Completed")||($3=="Running"&&n==2&&r[1]!=r[2])} bad(){printf "      ! %-42s %-20s ready=%s restarts=%s\n",$1,$3,$2,$4}'
    echo "$out" | awk 'function bad(){n=split($2,r,"/");return ($3!="Running"&&$3!="Completed")||($3=="Running"&&n==2&&r[1]!=r[2])} !bad(){printf "        %-42s %-20s ready=%s\n",$1,$3,$2}'
  done
}

# On non-convergence, dump exactly why each stuck pod is stuck.
diagnose() {
  echo
  echo "==> DIAGNOSTICS — helm --wait did not converge; per-pod cause below"
  for ns in "${NS_ALL[@]}"; do
    bad=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null \
      | awk 'function bad(){n=split($2,r,"/");return ($3!="Running"&&$3!="Completed")||($3=="Running"&&n==2&&r[1]!=r[2])} bad(){print $1}') || true
    [ -z "$bad" ] && continue
    echo "==== namespace: $ns ===="
    for p in $bad; do
      echo ">> POD $ns/$p"
      kubectl -n "$ns" describe pod "$p" 2>/dev/null | sed -n '/^Events:/,$p' | tail -15
      # Focus on the container(s) actually not Ready; fall back to all.
      nr=$(kubectl -n "$ns" get pod "$p" -o jsonpath='{range .status.initContainerStatuses[?(@.ready==false)]}{.name}{" "}{end}{range .status.containerStatuses[?(@.ready==false)]}{.name}{" "}{end}' 2>/dev/null)
      echo "   not-ready containers: ${nr:-<none flagged; dumping all>}"
      for c in ${nr:-$(kubectl -n "$ns" get pod "$p" -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null)}; do
        echo "   -- logs: $c (tail 20) --"
        kubectl -n "$ns" logs "$p" -c "$c" --tail=20 2>/dev/null \
          || kubectl -n "$ns" logs "$p" -c "$c" --tail=20 --previous 2>/dev/null \
          || echo "      (no logs yet)"
      done
    done
    echo "---- $ns recent Warning events ----"
    kubectl -n "$ns" get events --field-selector type=Warning \
      --sort-by=.lastTimestamp 2>/dev/null | tail -12
  done
  echo
  echo "    full helm output: $HELM_LOG"
}

# helm_wait <release> <chart> <namespace> [extra helm args...]
# Runs `helm upgrade --install --wait` in the background while streaming live
# pod snapshots; on failure dumps per-pod diagnostics. Returns helm's rc so the
# caller decides whether to abort. Used by every blocking install step.
helm_wait() {
  local rel="$1" chart="$2" ns="$3"; shift 3
  echo "    helm: $rel -> ns/$ns (timeout $HELM_TIMEOUT); live status every ${WATCH_INTERVAL}s"
  echo "    raw helm output -> $HELM_LOG (tail -f it in another pane)"
  helm upgrade --install "$rel" "$chart" --namespace "$ns" \
    --wait --timeout "$HELM_TIMEOUT" ${HELM_DEBUG:+--debug} "$@" \
    >"$HELM_LOG" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    snapshot
    sleep "$WATCH_INTERVAL"
  done
  set +e
  wait "$pid"; local rc=$?
  set -e
  echo "    ---- helm log (tail 25) ----"
  tail -n 25 "$HELM_LOG" | sed 's/^/    /'
  if [ "$rc" -ne 0 ]; then
    snapshot
    diagnose
  fi
  return "$rc"
}

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

echo "==> 2. helm dependency update (resolves + fetches all 12 subcharts)"
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
kubectl -n "$BUNDLE_NS" delete pod -l job-name=bundle-fetcher \
  --field-selector=status.phase=Succeeded --ignore-not-found 2>/dev/null || true
# orphaned hook PVC (NOT chart-managed): delete this ONE named PVC; clear finalizer if it hangs
if kubectl -n "$BUNDLE_NS" get pvc prompt-bundle >/dev/null 2>&1; then
  kubectl -n "$BUNDLE_NS" delete pvc prompt-bundle --timeout=60s 2>/dev/null \
    || kubectl -n "$BUNDLE_NS" patch pvc prompt-bundle --type=merge \
         -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
fi
# stale release records, scoped to THIS release's helm secrets only
if [ -n "$status" ] && [ "$status" != "deployed" ]; then
  kubectl -n "$NAMESPACE" delete secret -l owner=helm,name="$RELEASE" \
    --ignore-not-found 2>/dev/null || true
fi

echo "==> 5. Linkerd control plane (separate release; namespace: linkerd)"
# Linkerd's Helm chart renders the control-plane proxies ITSELF (partials.proxy
# in destination/identity/proxy-injector). The runtime proxy-injector webhook
# must therefore SKIP the control-plane namespace, or the control plane gets
# double-injected -> identity Init:0/1 / destination,injector PostStartHookError.
# The webhook's namespaceSelector is `admission-webhooks NotIn [disabled]`, so
# the linkerd ns MUST carry config.linkerd.io/admission-webhooks=disabled. It
# must also NEVER be linkerd.io/inject=enabled (the original platform-ns wedge).
# The umbrella's platform/gateway/mcp/sandbox namespaces stay inject=enabled and
# are meshed by this control plane's cluster-scoped webhook.
LINKERD_VERSION="${LINKERD_VERSION:-1.16.11}"
# Pair linkerd-crds to linkerd-control-plane by matching appVersion (the
# Linkerd release, e.g. stable-2.14.10). A mismatched crds chart serves the
# wrong HTTPRoute API version -> the policy controller 404-loops on
# httproutes.policy.linkerd.io and linkerd-destination never reaches 4/4.
# Override LINKERD_CRDS_VERSION to skip auto-resolution.
if [ -z "${LINKERD_CRDS_VERSION:-}" ]; then
  _lap=$(helm show chart linkerd/linkerd-control-plane --version "$LINKERD_VERSION" 2>/dev/null \
    | awk -F'[: ]+' '/^appVersion:/{print $2}')
  LINKERD_CRDS_VERSION=$(helm search repo linkerd/linkerd-crds --versions -o json 2>/dev/null \
    | jq -r --arg a "$_lap" 'map(select(.app_version==$a))|.[0].version // empty' 2>/dev/null)
  LINKERD_CRDS_VERSION="${LINKERD_CRDS_VERSION:-1.8.0}"
  echo "    linkerd-crds resolved to $LINKERD_CRDS_VERSION (control-plane appVersion=${_lap:-unknown})"
fi
kubectl get ns linkerd >/dev/null 2>&1 || kubectl create namespace linkerd
kubectl label namespace linkerd \
  config.linkerd.io/admission-webhooks=disabled --overwrite >/dev/null
# Earlier iterations created the linkerd CRDs via `kubectl apply` (no Helm
# ownership metadata). The linkerd-crds chart then refuses to adopt them
# ("invalid ownership metadata"). Patch Helm ownership onto the existing
# *.linkerd.io CRDs so the chart adopts them — non-destructive (no CRD
# deletion, no CR data loss). Scoped to the linkerd.io API group only: no
# other tenant on this shared cluster owns those (Gateway API CRDs are NOT
# touched — the chart creates the genuinely-absent one fresh).
for crd in $(kubectl get crd -o name 2>/dev/null | grep -E '\.linkerd\.io$'); do
  kubectl label "$crd" app.kubernetes.io/managed-by=Helm \
    --overwrite >/dev/null 2>&1 || true
  kubectl annotate "$crd" \
    meta.helm.sh/release-name=linkerd-crds \
    meta.helm.sh/release-namespace=linkerd --overwrite >/dev/null 2>&1 || true
done
# CRDs first via the OFFICIAL linkerd-crds chart (standard Linkerd Helm path),
# NOT the hand-extracted chart/crds/linkerd-crds.yaml — that copy was missing
# httproutes.gateway.networking.k8s.io, so the policy controller 404-looped
# and linkerd-destination never reached 4/4. The chart ships the complete,
# version-matched CRD set incl. the Gateway API CRDs. Idempotent; the
# umbrella's own crds/ apply later becomes a no-op.
cstatus=$(helm -n linkerd status linkerd-crds -o json 2>/dev/null \
  | jq -r '.info.status // empty' 2>/dev/null || true)
if [ -n "$cstatus" ] && [ "$cstatus" != "deployed" ]; then
  echo "    linkerd-crds status=$cstatus — uninstalling (scoped)"
  helm uninstall linkerd-crds -n linkerd --wait --timeout 120s 2>/dev/null || true
fi
helm upgrade --install linkerd-crds linkerd/linkerd-crds \
  --version "$LINKERD_CRDS_VERSION" --namespace linkerd \
  --wait --timeout 120s ${HELM_DEBUG:+--debug}
# Scoped preflight: clear ONLY a stuck linkerd-control-plane release in the
# linkerd ns (demo-owned; same safety rationale as the ai-security preflight).
lstatus=$(helm -n linkerd status linkerd-control-plane -o json 2>/dev/null \
  | jq -r '.info.status // empty' 2>/dev/null || true)
if [ -n "$lstatus" ] && [ "$lstatus" != "deployed" ]; then
  echo "    linkerd-control-plane status=$lstatus — uninstalling (scoped)"
  helm uninstall linkerd-control-plane -n linkerd --wait --timeout 120s 2>/dev/null || true
fi
# A leftover cluster-scoped Linkerd webhook from an earlier failed attempt
# keeps a live injector mutating the fresh control-plane pods (the cause of the
# persistent Init:0/1 / PostStartHookError loop). When we are about to (re)
# install (no healthy release present), delete ONLY these exact, uniquely
# Linkerd-named cluster resources so the reinstall recreates them clean.
if [ -z "$lstatus" ] || [ "$lstatus" != "deployed" ]; then
  kubectl delete mutatingwebhookconfiguration linkerd-proxy-injector-webhook-config \
    --ignore-not-found 2>/dev/null || true
  kubectl delete validatingwebhookconfiguration linkerd-sp-validator-webhook-config \
    --ignore-not-found 2>/dev/null || true
fi
if ! helm_wait linkerd-control-plane linkerd/linkerd-control-plane linkerd \
     --version "$LINKERD_VERSION" -f chart/linkerd-values.yaml; then
  echo; echo "==> bootstrap FAILED at step 5 (Linkerd control plane)"
  exit 1
fi
echo "    linkerd control plane ready (ns: linkerd, v$LINKERD_VERSION)"

echo "==> 6. ai-security umbrella -> namespace ${NAMESPACE}"
if ! helm_wait "$RELEASE" ./chart "$NAMESPACE" -f "$VALUES"; then
  echo; echo "==> bootstrap FAILED at step 6 (umbrella, ${RELEASE})"
  exit 1
fi

echo
echo "==> bootstrap PASS — components are up. Reach them with:"
echo "    kubectl -n ${NAMESPACE} port-forward svc/agent-gateway 8080:8080"
echo "    kubectl -n ${NAMESPACE} port-forward svc/demo-ui       8081:80"
echo "    kubectl -n ${NAMESPACE} port-forward svc/${RELEASE}-grafana 3000:80"
