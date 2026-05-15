#!/usr/bin/env bash
set -euo pipefail

# Mints a JWT from Dex for one of the static demo users.
# Usage: mint-jwt.sh <alice|bob|carol>
# Requires: curl, jq, an in-cluster Dex reachable at http://localhost:5556 via
# port-forward (or DEX_URL override).

USER="${1:-alice}"
DEX_URL="${DEX_URL:-http://localhost:5556}"

# Static passwords from chart/templates/dex-config.yaml ("password" for all 3)
PASS="password"

RESP=$(curl -sS -X POST "$DEX_URL/dex/token" \
  -d "grant_type=password" \
  -d "client_id=demo-ui" \
  -d "client_secret=demo-secret" \
  -d "username=${USER}@example.com" \
  -d "password=${PASS}" \
  -d "scope=openid email groups profile")

TOKEN=$(echo "$RESP" | jq -r '.id_token // empty')
if [ -z "$TOKEN" ]; then
  echo "Failed to mint JWT for $USER. Dex response:" >&2
  echo "$RESP" >&2
  exit 1
fi
echo "$TOKEN"
