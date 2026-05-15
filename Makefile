.PHONY: help demo demo-down smoke kind-up kind-down traffic traffic-burst sync-dashboards

KIND_CLUSTER ?= ai-security

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS=":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

sync-dashboards: ## copy dashboards/*.json into chart/dashboards/ before helm install
	@mkdir -p chart/dashboards
	@cp dashboards/*.json chart/dashboards/

kind-up: ## create the KIND cluster
	@kind get clusters 2>/dev/null | grep -q "^$(KIND_CLUSTER)$$" || \
		kind create cluster --config kind/demo-cluster.yaml
	@kubectl apply -f kind/metrics-server.yaml

kind-down: ## delete the KIND cluster
	@kind delete cluster --name $(KIND_CLUSTER) || true

demo: kind-up sync-dashboards ## bring up the full demo on a local KIND cluster
	@echo "TODO: helm install (added in T26)"

demo-down: kind-down ## tear down (kind delete cluster)

smoke: ## run smoke-test script (happy path + blocked attack)
	@scripts/smoke.sh

traffic: ## show whether traffic-gen pod is enabled
	@kubectl -n platform get deployment traffic-gen 2>&1 | tail -5

traffic-burst: ## fire 50 prompts now (mix of legit + adversarial)
	@scripts/traffic-burst.sh 50
