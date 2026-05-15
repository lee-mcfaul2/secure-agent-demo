# secure-agent-demo

Umbrella Helm chart + bring-up scripts for the AI Agent Security Platform demo.

## Quickstart

```bash
make demo            # bring up the full platform on KIND
make smoke           # verify the happy path + blocked-attack
make traffic-burst   # fire 50 prompts at the gateway
make demo-down       # tear down
```

See `docs/walkthrough.md` for the demo script and `docs/troubleshooting.md` for common issues.

## Platform repos

This repo is only the integration layer — it wires together six independent
components, each published as a signed container image and Helm chart that this
umbrella consumes. Each is a standalone repo:

- **[lib-agent-prompt](https://github.com/lee-mcfaul2/lib-agent-prompt)** —
  the shared contract. Multi-language JSON Schemas for every agent prompt and
  tool, plus the PII type list, packaged as a signed, cosign-verifiable OCI
  bundle. Every other component validates against it so the platform stays in
  lockstep across versions.
- **[pii-tokenizer](https://github.com/lee-mcfaul2/pii-tokenizer)** — a Go
  service that replaces PII with AEAD-encrypted, reversible tokens (AES-GCM-SIV,
  per-request keys, KMS-pluggable master key). The gateway is its only caller.
- **[llm-guard](https://github.com/lee-mcfaul2/llm-guard)** — a scanning
  service wrapping Protect AI's llm-guard: prompt-injection, secrets, and
  toxicity detection on text entering and leaving the model. Fails closed.
- **[agent-gateway](https://github.com/lee-mcfaul2/agent-gateway)** — the
  security choke point. Single service handling user ingress and all tool-call
  mediation: JWT auth, LLM Guard scanning, scrubbing/tokenization, OPA
  authorization, the LLM proxy, and the agent-loop driver.
- **[agent-sandbox](https://github.com/lee-mcfaul2/agent-sandbox)** — the
  isolated per-request agent runtime. A thin loop driver that only ever talks
  to LiteLLM (inside the gateway), launched as a short-lived Job.
- **[agent-sql-mcp](https://github.com/lee-mcfaul2/agent-sql-mcp)** — an MCP
  server exposing read tools over a demo customer database, enforcing per-tool
  permissions and row-level filtering (the Atlantis-customer authz scenario)
  from the forwarded JWT.
