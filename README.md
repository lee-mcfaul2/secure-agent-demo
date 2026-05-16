# secure-agent-demo

Umbrella Helm chart for the AI Agent Security Platform. You install it into a
Kubernetes cluster you already have.

## Prerequisites

- A Kubernetes cluster (any conformant cluster: managed, on-prem, k3s, etc.)
- `kubectl` pointed at it (`kubectl config use-context <ctx>`)
- `helm` 3.8+
- The cluster needs a default StorageClass (one small RWO PVC is used) and
  enough room for the platform (~2 vCPU / ~4Gi of schedulable headroom; the
  local LLM is the heaviest pod — disable it via values for a lean install).

## Install

```bash
# Installs into whatever cluster your current kubectl context points at.
make install
```

`make install` does the non-obvious ordering for you: pulls chart deps,
applies the Linkerd + SPIRE CRDs out-of-band (they must exist before the
release that uses them), then `helm upgrade --install`. It uses your
**ambient** kubeconfig/context — nothing here hijacks or rewrites it.

Prefer raw Helm? The equivalent is:

```bash
make sync-dashboards sync-traffic-gen        # stage chart file assets
cd chart && helm dependency update && cd ..
helm template crds chart/charts/linkerd-crds-*.tgz | kubectl apply --server-side -f -
helm template crds chart/charts/spire-crds-*.tgz   | kubectl apply --server-side -f -
kubectl wait --for=condition=Established crd --all --timeout=120s
helm upgrade --install ai-security ./chart -n platform --create-namespace \
  -f chart/values-demo.yaml --wait
```

## Use / tear down

```bash
make port-forward    # gateway :8080, demo-ui :8081, grafana :3000, dex :5556
make smoke           # verify happy path + blocked-attack
make traffic-burst   # fire 50 prompts at the gateway
make diagnose        # dump cluster state if something is wrong
make uninstall       # remove the release
```

The baked-in demo key/CA/bundle (`chart/demo-secrets`, `chart/demo-ca`,
`chart/demo-bundle`) make this turnkey but are **demo-only anti-patterns** —
each is loudly flagged in its own README. Override the master key with your
own by creating `chart/values-secrets.yaml` (gitignored); `make install`
layers it automatically.

### Optional: throwaway local KIND cluster

If you don't have a cluster and just want to kick the tires locally,
`make demo` will create a single-node KIND cluster (needs Docker/Podman) in
an isolated kubeconfig and install into that. KIND is finicky about host
limits (inotify, cgroups) — see `docs/troubleshooting.md`. The supported path
is `make install` into a real cluster.

See `docs/walkthrough.md` for the demo script and `docs/troubleshooting.md`
for common issues.

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
