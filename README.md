# secure-agent-demo

Umbrella Helm chart for the AI Agent Security Platform. You install it into a
Kubernetes cluster you already have.

## Prerequisites

- A Kubernetes cluster (any conformant cluster), with `kubectl` pointed at it
- `helm` 3.8+
- A default StorageClass (one small RWO PVC is used)
- ~2 vCPU / ~4Gi schedulable headroom (the local LLM is the heaviest pod;
  disable it in values for a lean install)

## Install

```bash
./scripts/bootstrap.sh
```

That's the whole install. The script registers the public Helm repos the
chart depends on, checks the platform images/charts were published, fetches
all 13 subcharts, and runs `helm upgrade --install`.

It is **not** a plain `helm dependency build ./chart` because the subchart
`.tgz` archives are intentionally gitignored (`chart/charts/*.tgz`), so a
fresh clone has nothing under `chart/charts/`. `helm dependency build` then
needs the five upstream repos registered first or it fails with
`no repository definition for https://helm.linkerd.io/stable, ...`.

Equivalent manual steps, if you'd rather not use the script:

```bash
helm repo add linkerd             https://helm.linkerd.io/stable
helm repo add spiffe              https://spiffe.github.io/helm-charts-hardened/
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add dex                 https://charts.dexidp.io
helm repo add bitnami             https://charts.bitnami.com/bitnami
helm repo update

helm dependency build ./chart

# The chart spans four namespaces and subcharts ship pre-install hooks that
# run before any chart-templated Namespace would exist. Create them first:
for ns in platform gateway mcp sandbox; do
  kubectl create namespace "$ns" --dry-run=client -o yaml \
    | kubectl label --local -f - linkerd.io/inject=enabled -o yaml \
    | kubectl apply -f -
done

helm upgrade --install ai-security ./chart \
  --namespace platform \
  -f chart/values-demo.yaml --wait
```

### Prerequisite: the platform release must be published

Five subcharts (`agent-gateway`, `agent-sandbox`, `agent-sql-mcp`,
`pii-tokenizer`, `llm-guard`) and their container images are pulled from
`ghcr.io/lee-mcfaul2`. They are published only by each component repo's
`Build and sign` workflow, which fires on a pushed `v*` tag. If that release
never ran (or the packages are private), `bootstrap.sh` stops at the
preflight check with instructions — the demo cannot run without those
artifacts no matter how Helm resolves charts.

The Linkerd + SPIRE CRDs ship in `chart/crds/`, which Helm installs before
templates, so the platform's `policy.linkerd.io` / `spire.spiffe.io` custom
resources resolve in a single install. Dashboards and the traffic-gen
script are committed in the chart, and `Chart.lock` is committed so the
dependency fetch is deterministic.

The install uses your current `kubectl` context. To upgrade, re-run the
command as `helm upgrade --install`. To remove:

```bash
helm uninstall ai-security -n platform
kubectl delete namespace platform gateway mcp sandbox  # not chart-managed
kubectl delete -f chart/crds/   # optional: also drop the CRDs
```

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

See `docs/walkthrough.md` for a guided tour and `docs/troubleshooting.md`
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
