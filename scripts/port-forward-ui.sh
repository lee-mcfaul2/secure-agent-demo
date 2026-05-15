#!/usr/bin/env bash
set -euo pipefail

# Demo-UI port-forward via NodePort 30080->host:8080 is already done by KIND's
# extraPortMappings. This script forwards Grafana (which uses ClusterIP) and
# prints the URLs.

GRAFANA_POD=$(kubectl -n platform get pod -l app.kubernetes.io/name=grafana -o name | head -1)
if [ -z "$GRAFANA_POD" ]; then
  echo "Grafana pod not found in 'platform' namespace" >&2
  exit 1
fi

echo "  UI:       http://localhost:8080"
echo "  Grafana:  http://localhost:3000  (admin/prom-operator)"
echo "  Dex:      http://localhost:5556"
echo
echo "Starting port-forward (Ctrl-C to stop)..."

kubectl -n platform port-forward "$GRAFANA_POD" 3000:3000 &
GP=$!
trap "kill $GP 2>/dev/null || true" EXIT

wait
