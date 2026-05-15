"""Continuous traffic generator for the AI Agent Security Platform demo.

Reads a YAML prompt bank, picks an entry, mints a JWT from Dex for that user,
POSTs to the gateway, logs the outcome. Loops with a jittered interval until
killed. Designed to keep Grafana dashboards populated.

Env:
    INTERVAL_SECONDS  mean delay between prompts (jittered +/-50%)
    GATEWAY_URL       e.g. http://agent-gateway.gateway.svc.cluster.local:8080
    DEX_URL           e.g. http://dex.platform.svc.cluster.local:5556
    PROMPTS_PATH      filesystem path to prompts.yaml (default /prompts/prompts.yaml)
"""
from __future__ import annotations
import json
import os
import random
import sys
import time
from pathlib import Path
from typing import Any

import httpx
import yaml

DEMO_PASSWORD = "password"  # Dex static-user passwords; same for all 3 demo users


def load_prompts(path: Path) -> list[dict[str, str]]:
    """Load and validate prompts.yaml. Returns a list of prompt dicts."""
    data = yaml.safe_load(path.read_text())
    prompts = data.get("prompts") or []
    if not prompts:
        raise ValueError(f"No prompts in {path}")
    return prompts


def pick_prompt(prompts: list[dict[str, str]]) -> dict[str, str]:
    """Pick one prompt at random (uniform)."""
    return random.choice(prompts)


def mint_jwt(user: str, dex_url: str) -> str:
    """Mint a JWT for the static demo user via Dex's password grant."""
    r = httpx.post(
        f"{dex_url.rstrip('/')}/dex/token",
        data={
            "grant_type": "password",
            "client_id": "demo-ui",
            "client_secret": "demo-secret",
            "username": f"{user}@example.com",
            "password": DEMO_PASSWORD,
            "scope": "openid email groups profile",
        },
        timeout=10.0,
    )
    r.raise_for_status()
    return r.json()["id_token"]


def send_prompt(gateway_url: str, jwt: str, text: str) -> dict[str, Any]:
    """POST a chat-completion to the gateway. Returns {status_code, body}."""
    r = httpx.post(
        f"{gateway_url.rstrip('/')}/v1/chat/completions",
        headers={"authorization": f"Bearer {jwt}", "content-type": "application/json"},
        json={"model": "claude-sonnet-4-6", "messages": [{"role": "user", "content": text}]},
        timeout=60.0,
    )
    try:
        body = r.json()
    except Exception:
        body = {"raw": r.text}
    return {"status_code": r.status_code, "body": body}


def jittered_sleep(mean_seconds: float) -> None:
    delay = mean_seconds * random.uniform(0.5, 1.5)
    time.sleep(delay)


def main() -> None:
    interval = float(os.environ.get("INTERVAL_SECONDS", "10"))
    gateway = os.environ["GATEWAY_URL"]
    dex     = os.environ["DEX_URL"]
    path    = Path(os.environ.get("PROMPTS_PATH", "/prompts/prompts.yaml"))

    prompts = load_prompts(path)
    print(f"Loaded {len(prompts)} prompts. Interval mean={interval}s.", flush=True)

    while True:
        try:
            p = pick_prompt(prompts)
            tok = mint_jwt(p["user"], dex)
            result = send_prompt(gateway, tok, p["text"])
            log = {
                "user": p["user"],
                "category": p["category"],
                "status": result["status_code"],
                "text": p["text"][:80],
            }
            print(json.dumps(log), flush=True)
        except Exception as e:
            print(json.dumps({"error": str(e)}), flush=True, file=sys.stderr)
        jittered_sleep(interval)


if __name__ == "__main__":
    main()
