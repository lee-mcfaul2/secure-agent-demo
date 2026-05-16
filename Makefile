.PHONY: help cluster-check install uninstall port-forward logs diagnose \
        traffic traffic-burst smoke test agentdojo dashboards-export clean \
        ui-open grafana-open

HELM_RELEASE ?= ai-security
NAMESPACE    ?= platform
SECRETS_FILE ?= chart/values-secrets.yaml

help: ## show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS=":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---- Install into the cluster your kubectl context points at ----
# This is just a thin convenience wrapper around two helm commands. The
# supported path is documented in README.md as raw helm; nothing here is
# required.

cluster-check: ## verify helm + a reachable cluster (uses current kubectl context)
	@command -v helm    >/dev/null 2>&1 || { echo "ERROR: 'helm' not found (need Helm 3.8+): https://helm.sh/docs/intro/install/"; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "ERROR: 'kubectl' not found: https://kubernetes.io/docs/tasks/tools/"; exit 1; }
	@kubectl cluster-info >/dev/null 2>&1 || { \
	  echo "ERROR: kubectl cannot reach a cluster. Point it at one first:"; \
	  echo "  kubectl config get-contexts"; \
	  echo "  kubectl config use-context <your-context>"; exit 1; }
	@printf '==> target context: %s\n' "$$(kubectl config current-context 2>/dev/null)"

install: cluster-check ## helm dependency build + helm upgrade --install into current cluster
	@if [ -f $(SECRETS_FILE) ]; then \
	  echo "==> using operator-supplied $(SECRETS_FILE) (overrides baked-in demo key)"; \
	else \
	  echo "==> no $(SECRETS_FILE); using baked-in DEMO key (see chart/demo-secrets/README.md)"; \
	fi
	@echo "==> helm dependency build"
	@cd chart && helm dependency build
	@echo "==> checking for a prior non-deployed release (clean install beats a stuck upgrade)"
	@st=$$(helm status $(HELM_RELEASE) -n $(NAMESPACE) 2>/dev/null | sed -n 's/^STATUS: //p' | head -1); \
	 echo "  current release status: $${st:-<none>}"; \
	 if [ -n "$$st" ] && [ "$$st" != "deployed" ]; then \
	   echo "  uninstalling '$$st' release for a clean install"; \
	   helm uninstall $(HELM_RELEASE) -n $(NAMESPACE) --wait --timeout 3m || true; \
	 fi
	@echo "==> helm upgrade --install (CRDs in chart/crds/ install before templates)"
	@helm upgrade --install $(HELM_RELEASE) ./chart \
	  --namespace $(NAMESPACE) --create-namespace \
	  -f chart/values-demo.yaml \
	  $(if $(wildcard $(SECRETS_FILE)),-f $(SECRETS_FILE),) \
	  --timeout 10m --wait --debug \
	  || { echo ""; echo "######## helm install FAILED — auto-diagnostics ########"; \
	       $(MAKE) --no-print-directory diagnose; \
	       echo "########################################################"; exit 1; }
	@scripts/wait-for-ready.sh
	@echo ""
	@echo "==> installed. Expose components with:  make port-forward"

uninstall: ## remove the release (chart/crds/ CRDs are left; kubectl delete -f chart/crds/ to drop)
	@helm uninstall $(HELM_RELEASE) -n $(NAMESPACE) --wait --timeout 5m || true

port-forward: ## port-forward gateway/demo-ui/grafana/dex locally
	@scripts/port-forward-ui.sh

# ---- Operations ----

logs: ## tail agent-gateway logs
	@kubectl logs -n gateway -l app.kubernetes.io/name=agent-gateway --tail=50 -f

ui-open: ## open the demo UI in a browser
	@xdg-open http://localhost:8081 || open http://localhost:8081 || true

grafana-open: ## open Grafana in a browser
	@xdg-open http://localhost:3000 || open http://localhost:3000 || true

diagnose: ## dump cluster state to explain a failed/stuck install
	@echo "### helm releases"; helm list -A 2>/dev/null || true
	@echo; echo "### helm status $(HELM_RELEASE)"; helm status $(HELM_RELEASE) -n $(NAMESPACE) 2>/dev/null | sed -n '1,20p' || true
	@echo; echo "### pods NOT Running/Completed (the problem is almost always here)"; \
	  kubectl get pods -A 2>/dev/null | awk 'NR==1 || ($$4!="Running" && $$4!="Completed")' || true
	@echo; echo "### all pods (wide)"; kubectl get pods -A -o wide 2>/dev/null || true
	@echo; echo "### jobs in $(NAMESPACE)"; kubectl get jobs -n $(NAMESPACE) 2>/dev/null || true
	@echo; echo "### bundle-fetcher describe (tail)"; kubectl describe job/bundle-fetcher -n $(NAMESPACE) 2>/dev/null | tail -25 || true
	@echo; echo "### bundle-fetcher logs"; kubectl logs -n $(NAMESPACE) -l job-name=bundle-fetcher --tail=50 --all-containers 2>/dev/null || true
	@echo; echo "### recent events $(NAMESPACE) (FailedScheduling / Insufficient / ImagePull / FailedMount)"; \
	  kubectl get events -n $(NAMESPACE) --sort-by=.lastTimestamp 2>/dev/null | tail -30 || true
	@echo; echo "### recent events (all namespaces)"; kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -30 || true
	@echo; echo "### node capacity / pressure"; \
	  kubectl describe nodes 2>/dev/null | grep -A6 -iE 'Allocated resources|Conditions:' | head -40 || true

# ---- Traffic / verification ----

traffic: ## show whether the traffic-gen pod is enabled
	@kubectl -n $(NAMESPACE) get deployment traffic-gen 2>&1 | tail -5

traffic-burst: ## fire 50 prompts now (mix of legit + adversarial)
	@scripts/traffic-burst.sh 50

smoke: ## run smoke test (happy path + blocked-attack)
	@scripts/smoke.sh

agentdojo: ## run AgentDojo against the running platform
	@cd tests/agentdojo && python run_agentdojo.py --config config.yaml --out agentdojo-results.json
	@python tests/agentdojo/score_gate.py tests/agentdojo/agentdojo-results.json tests/agentdojo/config.yaml

test: ## run unit tests (helm render + traffic_gen + agentdojo gate)
	@tests/helm/test_chart_renders.sh
	@PYTHONPATH=. python -m pytest traffic_gen/tests/ tests/agentdojo/tests/ -v

dashboards-export: ## dump live Grafana dashboards back to dashboards/*.json
	@scripts/dashboards-export.sh

clean: ## remove build cruft (vendored subchart tarballs)
	@rm -rf chart/charts/*.tgz
