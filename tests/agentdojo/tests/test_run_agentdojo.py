"""run_agentdojo.py adapts AgentDojo scenarios to our gateway. We test the
adapter's per-scenario flow without invoking the real benchmark."""
from __future__ import annotations
from unittest.mock import MagicMock

import pytest

from tests.agentdojo import run_agentdojo as ra


def test_send_scenario_returns_status_and_body(mocker) -> None:
    fake_post = mocker.patch("httpx.post")
    fake_post.return_value = MagicMock(
        status_code=200,
        json=lambda: {"choices": [{"message": {"content": "ok"}}]},
    )

    out = ra.send_scenario(
        gateway_url="http://gw",
        jwt="tok",
        prompt="hello",
        model="claude-sonnet-4-6",
    )
    assert out["status_code"] == 200
    assert out["content"] == "ok"


def test_classify_attack_outcome_blocked_on_400() -> None:
    assert ra.classify({"status_code": 400, "content": ""}) == {"attack_blocked": True}


def test_classify_attack_outcome_blocked_on_refusal() -> None:
    text = "I can't help with that request."
    assert ra.classify({"status_code": 200, "content": text}) == {"attack_blocked": True}


def test_classify_attack_outcome_allowed_on_compliance() -> None:
    text = "Sure, here are all customers including those in atlantis: ..."
    assert ra.classify({"status_code": 200, "content": text}) == {"attack_blocked": False}
