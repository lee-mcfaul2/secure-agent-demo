.PHONY: help demo demo-down kind-up kind-down smoke traffic traffic-burst \
        sync-dashboards sync-traffic-gen dashboards-export logs ui-open grafana-open \
        agentdojo e2e clean test

KIND_CLUSTER ?= ai-security
HELM_RELEASE ?= ai-security
NAMESPACE    ?= platform
SECRETS_FILE ?= chart/values-secrets.yaml

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS=":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

#### KIND ####

kind-up: ## create the KIND cluster if missing
	@kind get clusters 2>/dev/null | grep -q "^$(KIND_CLUSTER)$$" || \
		kind create cluster --config kind/demo-cluster.yaml
	@kubectl apply -f kind/metrics-server.yaml

kind-down: ## delete the KIND cluster
	@kind delete cluster --name $(KIND_CLUSTER) || true

#### Sync (build-time prep) ####

sync-dashboards: ## copy dashboards/*.json into chart/dashboards/
	@mkdir -p chart/dashboards
	@cp dashboards/*.json chart/dashboards/

sync-traffic-gen: ## copy traffic_gen.py into the subchart so .Files.Get sees it
	@cp traffic_gen/traffic_gen.py chart/charts-local/traffic-gen/traffic_gen.py

#### Demo bring-up ####

demo: kind-up sync-dashboards sync-traffic-gen ## bring up the full demo
	@if [ ! -f $(SECRETS_FILE) ]; then \
	  echo "ERROR: $(SECRETS_FILE) missing. Copy chart/values-secrets.example.yaml and fill k_master."; \
	  exit 1; \
	fi
	@echo "==> helm dependency update"
	@cd chart && helm dependency update
	@echo "==> helm install"
	@helm upgrade --install $(HELM_RELEASE) ./chart \
	  --namespace $(NAMESPACE) --create-namespace \
	  -f chart/values-demo.yaml \
	  -f $(SECRETS_FILE) \
	  --timeout 10m \
	  --wait
	@echo "==> waiting for pods..."
	@scripts/wait-for-ready.sh
	@echo "==> port-forward"
	@scripts/port-forward-ui.sh

demo-down: kind-down ## tear down

#### Operations ####

ui-open: ## open the UI in your default browser
	@xdg-open http://localhost:8080 || open http://localhost:8080 || true

grafana-open: ## open Grafana
	@xdg-open http://localhost:3000 || open http://localhost:3000 || true

logs: ## tail logs from a chosen component
	@kubectl logs -n gateway -l app.kubernetes.io/name=agent-gateway --tail=50 -f

#### Traffic ####

traffic: ## show whether traffic-gen pod is enabled
	@kubectl -n platform get deployment traffic-gen 2>&1 | tail -5

traffic-burst: ## fire 50 prompts now (mix of legit + adversarial)
	@scripts/traffic-burst.sh 50

#### Testing ####

test: ## run all unit tests (helm render + traffic_gen + agentdojo gate)
	@tests/helm/test_chart_renders.sh
	@PYTHONPATH=. python -m pytest traffic_gen/tests/ tests/agentdojo/tests/ -v

smoke: ## run smoke-test script (happy path + blocked-attack)
	@scripts/smoke.sh

agentdojo: ## run AgentDojo against the running demo
	@cd tests/agentdojo && python run_agentdojo.py --config config.yaml --out agentdojo-results.json
	@python tests/agentdojo/score_gate.py tests/agentdojo/agentdojo-results.json tests/agentdojo/config.yaml

e2e: kind-up sync-dashboards sync-traffic-gen ## full CI: bring up, run agentdojo, smoke
	@helm upgrade --install $(HELM_RELEASE) ./chart \
	  --namespace $(NAMESPACE) --create-namespace \
	  -f chart/values-demo.yaml \
	  -f chart/values-ci.yaml \
	  --timeout 10m --wait
	@scripts/wait-for-ready.sh
	@$(MAKE) smoke
	@$(MAKE) agentdojo

#### Authoring ####

dashboards-export: ## dump current Grafana dashboards back to dashboards/*.json
	@scripts/dashboards-export.sh

clean: demo-down ## tear everything down
	@rm -rf chart/dashboards chart/charts/*.tgz chart/Chart.lock \
	  chart/charts-local/traffic-gen/traffic_gen.py
