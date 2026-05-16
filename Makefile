.PHONY: help demo demo-down kind-up kind-down smoke traffic traffic-burst \
        sync-dashboards sync-traffic-gen dashboards-export logs ui-open grafana-open \
        agentdojo e2e clean test preflight bootstrap diagnose

KIND_CLUSTER ?= ai-security
HELM_RELEASE ?= ai-security
NAMESPACE    ?= platform
SECRETS_FILE ?= chart/values-secrets.yaml

# Project-local tool dir — bootstrapped binaries land here, no sudo, no system
# pollution. Prepended to PATH for every recipe.
LOCALBIN := $(CURDIR)/.bin
export PATH := $(LOCALBIN):$(PATH)

# Dedicated, isolated kubeconfig. The demo NEVER reads or writes ~/.kube/config
# and never changes your current kubectl context. Every kubectl/helm/script in
# this Makefile inherits this exported KUBECONFIG, and it only ever contains the
# throwaway kind cluster — so the demo provably cannot touch any other cluster
# on this machine, even on a re-run where the kind cluster already exists.
KUBECONFIG := $(CURDIR)/.kube/demo.config
export KUBECONFIG

# Pinned tool versions (reproducible; KIND v0.24 node image is k8s 1.31).
KIND_VERSION    ?= v0.24.0
KUBECTL_VERSION ?= v1.31.4
HELM_VERSION    ?= v3.16.3
JQ_VERSION      ?= 1.7.1

# OS/arch for download URLs.
OS   := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')

help: ## show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS=":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

#### Tooling bootstrap ####

preflight: ## verify a container runtime + curl/tar (real guidance, no fake commands)
	@missing=""; \
	for t in curl tar; do command -v $$t >/dev/null 2>&1 || missing="$$missing $$t"; done; \
	if [ -n "$$missing" ]; then \
	  echo "ERROR: missing:$$missing"; \
	  echo "  Debian/Ubuntu : sudo apt-get update && sudo apt-get install -y$$missing"; \
	  echo "  Fedora/RHEL   : sudo dnf install -y$$missing"; \
	  echo "  macOS         : these ship with macOS; if not, 'brew install$$missing'"; \
	  exit 1; \
	fi; \
	if docker info >/dev/null 2>&1; then \
	  echo "==> preflight OK (docker runtime reachable; curl, tar present)"; \
	elif podman info >/dev/null 2>&1; then \
	  echo "==> preflight OK (podman runtime reachable; curl, tar present)"; \
	  echo "    note: KIND will use podman (export KIND_EXPERIMENTAL_PROVIDER=podman)"; \
	else \
	  echo "ERROR: no working container runtime found (need a reachable docker OR podman)."; \
	  echo ""; \
	  echo "If you DO have Docker but see this: the 'docker' command is not on PATH"; \
	  echo "for non-interactive shells (common when it's a shell alias/function, a"; \
	  echo "snap, or Docker Desktop CLI integration). Make runs recipes via /bin/sh,"; \
	  echo "which does not load your shell rc. Fix by either:"; \
	  echo "  - ensuring the real docker binary's dir is on PATH, e.g.:"; \
	  echo "      make demo PATH=\"\$$(dirname \$$(command -v docker)):\$$PATH\""; \
	  echo "  - or run:  which docker   and add that dir to PATH in your environment"; \
	  echo ""; \
	  echo "To install a runtime from scratch (these are docs pages, not commands):"; \
	  echo "  Docker Engine (Linux) : https://docs.docker.com/engine/install/"; \
	  echo "  Docker Desktop (mac)  : https://www.docker.com/products/docker-desktop/"; \
	  echo "  Podman                : https://podman.io/docs/installation"; \
	  exit 1; \
	fi; \
	if [ -r /proc/sys/fs/inotify/max_user_instances ]; then \
	  ins=$$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0); \
	  wat=$$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0); \
	  if [ "$$ins" -lt 512 ] || [ "$$wat" -lt 524288 ]; then \
	    echo ""; \
	    echo "WARNING: low inotify limits (instances=$$ins watches=$$wat)."; \
	    echo "This is the #1 cause of KIND failing at 'Starting control-plane'"; \
	    echo "with 'kubelet is not healthy'. Raise them (host-level, needs root):"; \
	    echo "  sudo sysctl fs.inotify.max_user_instances=8192"; \
	    echo "  sudo sysctl fs.inotify.max_user_watches=1048576"; \
	    echo "Persist in /etc/sysctl.d/99-kind.conf. Continuing anyway..."; \
	    echo ""; \
	  fi; \
	fi

bootstrap: preflight ## auto-install kind/kubectl/helm/jq into ./.bin if missing
	@mkdir -p $(LOCALBIN)
	@if ! command -v kind >/dev/null 2>&1; then \
	  echo "==> installing kind $(KIND_VERSION) -> $(LOCALBIN)"; \
	  curl -fsSL -o $(LOCALBIN)/kind "https://kind.sigs.k8s.io/dl/$(KIND_VERSION)/kind-$(OS)-$(ARCH)" && chmod +x $(LOCALBIN)/kind; \
	fi
	@if ! command -v kubectl >/dev/null 2>&1; then \
	  echo "==> installing kubectl $(KUBECTL_VERSION) -> $(LOCALBIN)"; \
	  curl -fsSL -o $(LOCALBIN)/kubectl "https://dl.k8s.io/release/$(KUBECTL_VERSION)/bin/$(OS)/$(ARCH)/kubectl" && chmod +x $(LOCALBIN)/kubectl; \
	fi
	@if ! command -v helm >/dev/null 2>&1; then \
	  echo "==> installing helm $(HELM_VERSION) -> $(LOCALBIN)"; \
	  curl -fsSL "https://get.helm.sh/helm-$(HELM_VERSION)-$(OS)-$(ARCH).tar.gz" | tar -xz -C /tmp $(OS)-$(ARCH)/helm && mv /tmp/$(OS)-$(ARCH)/helm $(LOCALBIN)/helm && chmod +x $(LOCALBIN)/helm; \
	fi
	@if ! command -v jq >/dev/null 2>&1; then \
	  echo "==> installing jq $(JQ_VERSION) -> $(LOCALBIN)"; \
	  curl -fsSL -o $(LOCALBIN)/jq "https://github.com/jqlang/jq/releases/download/jq-$(JQ_VERSION)/jq-$(OS)-$(ARCH)" && chmod +x $(LOCALBIN)/jq; \
	fi
	@echo "==> bootstrap OK: $$(command -v kind) $$(command -v kubectl) $$(command -v helm) $$(command -v jq)"

#### KIND ####

kind-up: ## create the KIND cluster if missing (isolated kubeconfig)
	@mkdir -p $(dir $(KUBECONFIG))
	@if docker info >/dev/null 2>&1; then PROV=""; \
	 elif podman info >/dev/null 2>&1; then PROV="KIND_EXPERIMENTAL_PROVIDER=podman"; \
	 else echo "ERROR: no container runtime (run 'make preflight' for guidance)"; exit 1; fi; \
	 if env $$PROV kind get clusters 2>/dev/null | grep -q "^$(KIND_CLUSTER)$$"; then \
	   echo "==> kind cluster '$(KIND_CLUSTER)' exists; exporting its kubeconfig to $(KUBECONFIG)"; \
	   env $$PROV kind export kubeconfig --name $(KIND_CLUSTER) --kubeconfig "$(KUBECONFIG)"; \
	 else \
	   env $$PROV kind create cluster --config kind/demo-cluster.yaml --kubeconfig "$(KUBECONFIG)"; \
	 fi
	@kubectl apply -f kind/metrics-server.yaml

kind-down: ## delete the KIND cluster + its isolated kubeconfig
	@kind delete cluster --name $(KIND_CLUSTER) || true
	@rm -f "$(KUBECONFIG)"

#### Sync (build-time prep) ####

sync-dashboards: ## copy dashboards/*.json into chart/dashboards/
	@mkdir -p chart/dashboards
	@cp dashboards/*.json chart/dashboards/

sync-traffic-gen: ## copy traffic_gen.py into the subchart so .Files.Get sees it
	@cp traffic_gen/traffic_gen.py chart/charts-local/traffic-gen/traffic_gen.py

#### Demo bring-up ####

demo: bootstrap kind-up sync-dashboards sync-traffic-gen ## bring up the full demo (turnkey — no manual setup)
	@if [ -f $(SECRETS_FILE) ]; then \
	  echo "==> using operator-supplied $(SECRETS_FILE) (overrides baked-in demo key)"; \
	else \
	  echo "==> no $(SECRETS_FILE); using baked-in DEMO key (see chart/demo-secrets/README.md)"; \
	fi
	@echo "==> helm dependency update"
	@cd chart && helm dependency update
	@echo "==> installing CRDs out-of-band (Linkerd + SPIRE) before the umbrella"
	@# The umbrella contains both CRDs and the custom resources that use them.
	@# Helm validates the whole release against the API server before applying,
	@# so CRDs defined in the same release aren't visible yet. Render the two
	@# CRD-only subcharts and apply them first (idempotent, re-run safe; the
	@# umbrella has linkerd-crds/spire-crds disabled so there's no ownership
	@# conflict).
	@helm template crds chart/charts/linkerd-crds-*.tgz | kubectl apply --server-side -f -
	@helm template crds chart/charts/spire-crds-*.tgz   | kubectl apply --server-side -f -
	@echo "==> waiting for CRDs to be Established..."
	@kubectl wait --for=condition=Established crd --all --timeout=120s
	@echo "==> checking for a prior non-deployed release (clean install beats a stuck upgrade)"
	@st=$$(helm status $(HELM_RELEASE) -n $(NAMESPACE) 2>/dev/null | sed -n 's/^STATUS: //p' | head -1); \
	 echo "  current release status: $${st:-<none>}"; \
	 if [ -n "$$st" ] && [ "$$st" != "deployed" ]; then \
	   echo "  uninstalling '$$st' release so we do a clean install (pre-install, not pre-upgrade)"; \
	   helm uninstall $(HELM_RELEASE) -n $(NAMESPACE) --wait --timeout 3m || true; \
	 fi
	@echo "==> helm install (verbose: --debug shows hook-by-hook progress)"
	@helm upgrade --install $(HELM_RELEASE) ./chart \
	  --namespace $(NAMESPACE) --create-namespace \
	  -f chart/values-demo.yaml \
	  $(if $(wildcard $(SECRETS_FILE)),-f $(SECRETS_FILE),) \
	  --timeout 10m \
	  --wait --debug \
	  || { echo ""; echo "############ helm install FAILED — auto-diagnostics ############"; \
	       $(MAKE) --no-print-directory diagnose; \
	       echo "################################################################"; \
	       exit 1; }
	@echo "==> waiting for pods..."
	@scripts/wait-for-ready.sh
	@echo "==> port-forward"
	@scripts/port-forward-ui.sh

demo-down: kind-down ## tear down

#### Operations ####

ui-open: ## open the UI in your default browser
	@xdg-open http://localhost:8081 || open http://localhost:8081 || true

grafana-open: ## open Grafana
	@xdg-open http://localhost:3000 || open http://localhost:3000 || true

logs: ## tail logs from a chosen component
	@kubectl logs -n gateway -l app.kubernetes.io/name=agent-gateway --tail=50 -f

diagnose: ## dump cluster state to explain a failed/stuck bring-up
	@echo "### helm releases (all namespaces)"; helm list -A 2>/dev/null || true
	@echo; echo "### helm status $(HELM_RELEASE)"; helm status $(HELM_RELEASE) -n $(NAMESPACE) 2>/dev/null | sed -n '1,20p' || true
	@echo; echo "### pods NOT Running/Completed (the actual problem is almost always here)"; \
	  kubectl get pods -A 2>/dev/null | awk 'NR==1 || ($$4!="Running" && $$4!="Completed")' || true
	@echo; echo "### all pods (wide)"; kubectl get pods -A -o wide 2>/dev/null || true
	@echo; echo "### hook jobs in $(NAMESPACE)"; kubectl get jobs -n $(NAMESPACE) 2>/dev/null || true
	@echo; echo "### bundle-fetcher job describe (tail)"; kubectl describe job/bundle-fetcher -n $(NAMESPACE) 2>/dev/null | tail -25 || true
	@echo; echo "### bundle-fetcher pod logs"; kubectl logs -n $(NAMESPACE) -l job-name=bundle-fetcher --tail=50 --all-containers 2>/dev/null || true
	@echo; echo "### recent events in $(NAMESPACE) (look for FailedScheduling / Insufficient / ImagePull / FailedMount)"; \
	  kubectl get events -n $(NAMESPACE) --sort-by=.lastTimestamp 2>/dev/null | tail -30 || true
	@echo; echo "### recent events (all namespaces)"; kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -30 || true
	@echo; echo "### node capacity / pressure (RAM is the usual culprit on small boxes)"; \
	  kubectl describe nodes 2>/dev/null | grep -A6 -iE 'Allocated resources|Conditions:' | head -40 || true

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

e2e: bootstrap kind-up sync-dashboards sync-traffic-gen ## full CI: bring up, run agentdojo, smoke
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
	  chart/charts-local/traffic-gen/traffic_gen.py .kube
