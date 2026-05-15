.PHONY: help demo demo-down smoke

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS=":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

demo: ## bring up the full demo on a local KIND cluster
	@echo "demo target not yet implemented"; exit 1

demo-down: ## tear down (kind delete cluster)
	@kind delete cluster --name ai-security || true

smoke: ## run smoke-test script
	@echo "smoke target not yet implemented"; exit 1
