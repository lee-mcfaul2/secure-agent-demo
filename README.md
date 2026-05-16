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

## Install (raw Helm — two commands)

```bash
helm dependency build ./chart

helm install ai-security ./chart \
  --namespace platform --create-namespace \
  -f chart/values-demo.yaml --wait
```

That's it. No Makefile, no pre-steps, no `kubectl apply` for CRDs:

- The Linkerd + SPIRE **CRDs ship in `chart/crds/`**, which Helm installs
  before any templates — so the platform's `policy.linkerd.io` /
  `spire.spiffe.io` custom resources resolve in a single `helm install`.
- Dashboards and the traffic-gen script are committed in the chart, so
  `.Files.Get` works with no staging step.
- `Chart.lock` is committed, so `helm dependency build` is deterministic
  (it pulls the exact pinned subchart versions; the umbrella's own
  `chart/charts/*.tgz` are not vendored in git).

Installs into whatever cluster your current `kubectl` context points at;
nothing here rewrites your kubeconfig.

To upgrade, re-run the same `helm install` as `helm upgrade --install`.
To remove: `helm uninstall ai-security -n platform` (the `chart/crds/`
CRDs are intentionally left — `kubectl delete -f chart/crds/` to drop them).

## Prerequisites for install

- `helm` 3.8+ and a `kubectl` context pointed at the target cluster
- A default StorageClass (one small RWO PVC is used)
- ~2 vCPU / ~4Gi schedulable headroom (the local LLM is the heaviest pod;
  disable it in values for a lean install)

## Reach the components

```bash
kubectl -n platform port-forward svc/agent-gateway 8080:8080
kubectl -n platform port-forward svc/demo-ui       8081:80
kubectl -n platform port-forward svc/ai-security-grafana 3000:80
```

## Demo secrets are baked in (and loudly flagged)

`chart/demo-secrets`, `chart/demo-ca`, and `chart/demo-bundle` ship a
throwaway tokenizer key, Linkerd CA, and prompt bundle so the chart is
turnkey. Each is a **deliberate demo-only anti-pattern** documented in its
own README. Override the key for anything real:

```bash
echo "pii-tokenizer: {k_master: \"$(openssl rand -base64 32)\"}" > chart/values-secrets.yaml
helm install ... -f chart/values-demo.yaml -f chart/values-secrets.yaml ...
```

## Optional convenience: a Makefile

The repo includes a thin `Makefile` (`make install`, `make uninstall`,
`make diagnose`, `make smoke`, `make port-forward`) that just wraps the
Helm/kubectl commands above — entirely optional. See
`docs/walkthrough.md` and `docs/troubleshooting.md`.

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
