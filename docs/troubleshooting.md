# Troubleshooting

All commands assume your `kubectl` context points at the target cluster and
the release is `ai-security` in namespace `platform`.

## Install fails / a pod won't come up

```bash
kubectl get pods -A | grep -vE 'Running|Completed'
kubectl -n platform get events --sort-by=.lastTimestamp | tail -30
helm status ai-security -n platform
```

`ImagePullBackOff` → the cluster can't reach `ghcr.io` (egress/proxy) or the
image tag is missing. `Pending` with `Insufficient memory/cpu` → see
"Not enough resources". `FailedMount` / PVC `Pending` → no default
StorageClass (the chart needs one small RWO PVC).

## "helm install times out"

Default timeout is 10 minutes. Large clusters pulling images for the first
time can need longer:

```bash
helm upgrade --install ai-security ./chart -n platform --create-namespace \
  -f chart/values-demo.yaml --wait --timeout 20m
```

## Not enough resources

The local Ollama LLM is by far the heaviest pod. For a lean install, disable
it (and trim Prometheus) via a values overlay:

```yaml
# lean.yaml
local-llm: { enabled: false }
agent-gateway: { litellm: { mode: mock } }   # gateway returns canned responses
kube-prometheus-stack:
  prometheus: { prometheusSpec: { retention: 1h } }
```

```bash
helm upgrade --install ai-security ./chart -n platform --create-namespace \
  -f chart/values-demo.yaml -f lean.yaml --wait
```

## "Ollama model pull is taking forever"

First install pulls `llama3.2:3b` (~2 GB) into a PVC; later installs reuse it.

```bash
kubectl -n platform logs job/local-llm-pull-llama3.2-3b -f
```

Smaller model: set `local-llm.model: "llama3.2:1b"` in a values overlay.

## "Dashboards are empty"

```bash
kubectl -n platform port-forward svc/ai-security-kube-prometheus-prometheus 9090:9090
# open http://localhost:9090/targets — every component ServiceMonitor should appear
```

ServiceMonitor selectors are `searchNamespace: ALL`; if a target is missing,
check that component's `serviceMonitor.enabled` value.

## "Smoke test fails on the injection prompt"

Check LLM Guard is up and reachable:

```bash
kubectl -n platform get pod -l app=llm-guard
kubectl -n gateway exec deploy/agent-gateway -- \
  curl -fsS http://llm-guard.platform.svc.cluster.local:8000/healthz
```

If `gateway_llm_guard_enabled` is `0` the `LLMGuardDisabled` alert fires;
set `llm-guard.enabled=true` and re-install.

## "AgentDojo says ImportError: agentdojo"

```bash
pip install -r tests/agentdojo/requirements.txt
```

## Reaching the components

Nothing is exposed publicly by default — use port-forward:

```bash
kubectl -n platform port-forward svc/agent-gateway 8080:8080 &
kubectl -n platform port-forward svc/demo-ui       8081:80   &
kubectl -n platform port-forward svc/ai-security-grafana 3000:80 &
```

## "I want to see what tools each user has"

```bash
JWT=$(scripts/mint-jwt.sh bob)
curl -sS -H "Authorization: Bearer $JWT" \
  http://localhost:8080/v1/debug/catalog | jq .
```

Returns the per-user `AVAILABLE_TOOLS` list (Bob's omits `transaction.*`).

## Clean removal

```bash
helm uninstall ai-security -n platform
kubectl delete -f chart/crds/                 # optional: drop the CRDs
kubectl delete namespace platform gateway mcp sandbox --ignore-not-found
```
