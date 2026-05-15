# Troubleshooting

## "Ollama model pull is taking forever"

First install pulls `llama3.2:3b` (~2GB). Subsequent installs reuse the PVC.

Watch progress:
```bash
kubectl -n platform logs job/local-llm-pull-llama3.2-3b -f
```

To use a smaller model for low-RAM laptops, edit `chart/values-demo.yaml`:
```yaml
local-llm:
  model: "llama3.2:1b"  # ~1.3 GB
```
Re-run `make demo`.

## "helm install times out"

The 10-minute timeout in `make demo` is usually enough, but bare-metal
installs that include the model pull can take longer. Bump with:
```bash
make demo HELM_TIMEOUT=20m
```

## "AgentDojo says ImportError: agentdojo"

```bash
pip install -r tests/agentdojo/requirements.txt
```

## "Smoke test fails on injection prompt"

Check LLM Guard is enabled and reachable:
```bash
kubectl -n platform get pod -l app=llm-guard
kubectl -n gateway exec deploy/agent-gateway -- curl -fsS http://llm-guard.platform.svc.cluster.local:8000/healthz
```

If `gateway_llm_guard_enabled` shows `0`, the `LLMGuardDisabled` alert should
also be firing. Resolution: flip `llm-guard.enabled=true` in values and reroll.

## "Dashboards are empty"

Check Prometheus is scraping:
```bash
kubectl -n platform port-forward svc/kps-prometheus 9090:9090
# open http://localhost:9090/targets
```

ServiceMonitor selectors are set to `searchNamespace: ALL` — every subchart's
ServiceMonitor should appear. If not, check the chart's `serviceMonitor.enabled`
flag.

## "Out of memory mid-install"

The 4GB Ollama pod + 1GB Prometheus + scanner ML pulls memory hard.
Recommendations:
- Disable Ollama for CI: use `values-ci.yaml` which sets `litellm.mode: mock`.
- Reduce Prometheus retention: `kube-prometheus-stack.prometheus.prometheusSpec.retention: 1h`.

## "Can't reach localhost:8080"

The UI uses KIND's extraPortMappings (30080→8080). If you're on a host where
KIND's port-forward isn't working (some WSL/Docker-Desktop setups), use:
```bash
kubectl -n platform port-forward svc/demo-ui 8080:80
```

## "I want to see what tools each user has"

The gateway exposes a debug endpoint:
```bash
JWT=$(scripts/mint-jwt.sh bob)
curl -sS -H "Authorization: Bearer $JWT" http://localhost:8080/v1/debug/catalog | jq .
```

This returns the per-user `AVAILABLE_TOOLS` list (Bob's won't include
`transaction.*` tools).

## "Will this touch my existing Kubernetes cluster?"

No. The demo is fully isolated from any other cluster on the machine:

- It runs in its own KIND cluster (separate Docker containers, separate API
  server — it cannot merge with or modify another cluster's workloads).
- It uses a **dedicated kubeconfig** at `.kube/demo.config`. Every
  `kubectl`/`helm` call in the Makefile inherits it via an exported
  `KUBECONFIG`. Your `~/.kube/config` is never read or written, and your
  current `kubectl` context is never changed — even on a re-run where the
  KIND cluster already exists (the Makefile re-exports the KIND cluster's
  config into the isolated file rather than trusting the ambient context).
- `make demo-down` deletes the KIND cluster and removes `.kube/demo.config`.

To inspect the demo cluster manually:
`KUBECONFIG=.kube/demo.config kubectl get pods -A`
