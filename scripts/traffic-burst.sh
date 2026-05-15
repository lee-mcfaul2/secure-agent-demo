#!/usr/bin/env bash
set -euo pipefail

# Fires N prompts from the prompt bank against the running gateway.
# Usage: scripts/traffic-burst.sh [COUNT]

COUNT="${1:-50}"
PROMPTS_FILE="${PROMPTS_FILE:-chart/charts-local/traffic-gen/prompts.yaml}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
DEX_URL="${DEX_URL:-http://localhost:5556}"

# Run inside a transient Python container so we don't depend on host Python.
docker run --rm \
  --network host \
  -v "$(pwd)/$PROMPTS_FILE:/prompts/prompts.yaml:ro" \
  -v "$(pwd)/traffic_gen:/work:ro" \
  -e GATEWAY_URL="$GATEWAY_URL" \
  -e DEX_URL="$DEX_URL" \
  -e PROMPTS_PATH="/prompts/prompts.yaml" \
  -e INTERVAL_SECONDS="0.3" \
  python:3.11-slim sh -c "
    pip install --quiet httpx pyyaml &&
    python -c \"
import os, sys; sys.path.insert(0, '/work')
from traffic_gen.traffic_gen import load_prompts, pick_prompt, mint_jwt, send_prompt
import random, json, time, os
prompts = load_prompts(__import__('pathlib').Path(os.environ['PROMPTS_PATH']))
for i in range($COUNT):
    p = pick_prompt(prompts)
    try:
        tok = mint_jwt(p['user'], os.environ['DEX_URL'])
        r = send_prompt(os.environ['GATEWAY_URL'], tok, p['text'])
        print(json.dumps({'i':i+1, 'user':p['user'], 'cat':p['category'], 'status':r['status_code']}))
    except Exception as e:
        print(json.dumps({'i':i+1, 'error':str(e)}), file=sys.stderr)
    time.sleep(0.3)
print('burst complete')
\"
  "
