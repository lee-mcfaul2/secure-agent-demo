#!/usr/bin/env bash
set -euo pipefail

# Background port-forwards for Grafana (3000) and Dex (5556).
# The Demo UI is exposed via KIND's extraPortMappings (30080→host:8080)
# and doesn't need a port-forward.

GRAFANA_POD=$(kubectl -n platform get pod -l app.kubernetes.io/name=grafana -o name | head -n 1)
if [ -z "$GRAFANA_POD" ]; then
  echo "Grafana pod not found in 'platform' namespace" >&2
  exit 1
fi

DEX_SVC=$(kubectl -n platform get svc -l app.kubernetes.io/name=dex -o name | head -n 1)
if [ -z "$DEX_SVC" ]; then
  echo "Dex service not found in 'platform' namespace" >&2
  exit 1
fi

echo "  UI:       http://localhost:8080"
echo "  Grafana:  http://localhost:3000  (admin/prom-operator)"
echo "  Dex:      http://localhost:5556"
echo
echo "Starting port-forwards (Ctrl-C to stop)..."

kubectl -n platform port-forward "$GRAFANA_POD" 3000:3000 &
GP=$!
kubectl -n platform port-forward "$DEX_SVC" 5556:5556 &
DP=$!
trap "kill $GP $DP 2>/dev/null || true" EXIT

wait
