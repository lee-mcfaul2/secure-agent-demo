#!/usr/bin/env bash
set -euo pipefail

# Exports current Grafana dashboards back to dashboards/*.json for iteration.
# Requires Grafana port-forward on http://localhost:3000.

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_AUTH="${GRAFANA_AUTH:-admin:prom-operator}"

mkdir -p dashboards
for uid in "ai-sec-platform" "ai-sec-posture" "ai-sec-agent-loop"; do
  echo "Exporting $uid..."
  curl -sS -u "$GRAFANA_AUTH" "$GRAFANA_URL/api/dashboards/uid/$uid" \
    | jq '.dashboard' > "dashboards/${uid}.tmp.json"

  # Strip Grafana-server-side fields that shouldn't be in source
  jq 'del(.id, .version) | .version = 1' "dashboards/${uid}.tmp.json" \
    > "dashboards/${uid%-*}-$(echo $uid | sed 's/ai-sec-//').json"
  rm "dashboards/${uid}.tmp.json"
done
echo "Done. Diff and commit as appropriate."
