#!/usr/bin/env bash
set -euo pipefail

NAMESPACES=("gateway" "platform" "mcp" "sandbox")
TIMEOUT="${TIMEOUT:-300s}"

for ns in "${NAMESPACES[@]}"; do
  echo "Waiting for pods in namespace=$ns ..."
  if ! kubectl -n "$ns" get pods -o name 2>/dev/null | head -1 >/dev/null; then
    echo "  (no pods yet in $ns, skipping)"
    continue
  fi
  kubectl -n "$ns" wait --for=condition=ready pod --all --timeout="$TIMEOUT"
done

echo "All platform pods ready."
