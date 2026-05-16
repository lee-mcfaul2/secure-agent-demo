.PHONY: help install uninstall cluster-check port-forward demo demo-down \
        kind-up kind-down smoke traffic traffic-burst \
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

# Primary path is `make install` / `helm install` against an existing cluster
# you point kubectl at — it uses your AMBIENT kubeconfig/context, nothing here
# hijacks it. The optional local-KIND convenience path (`make demo`) uses this
# separate, isolated kubeconfig so KIND never touches ~/.kube/config.
KIND_KUBECONFIG := $(CURDIR)/.kube/demo.config

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
	    if [ "$$(id -u)" = "0" ]; then \
	      echo "==> raising low inotify limits (was instances=$$ins watches=$$wat; running as root)"; \
	      sysctl -w fs.inotify.max_user_instances=8192 >/dev/null; \
	      sysctl -w fs.inotify.max_user_watches=1048576 >/dev/null; \
	      printf 'fs.inotify.max_user_instances=8192\nfs.inotify.max_user_watches=1048576\n' > /etc/sysctl.d/99-kind.conf 2>/dev/null || true; \
	      echo "    set to instances=8192 watches=1048576 (persisted to /etc/sysctl.d/99-kind.conf)"; \
	      echo "    NOTE: any KIND cluster created BEFORE this is already broken —"; \
	      echo "          run 'make demo-down' once, then 'make demo' again."; \
	    elif [ "$$INOTIFY_OK" = "1" ]; then \
	      echo "WARNING: low inotify (instances=$$ins watches=$$wat) but INOTIFY_OK=1 set; proceeding."; \
	    else \
	      echo ""; \
	      echo "ERROR: inotify limits are too low for a working Kubernetes node"; \
	      echo "       (instances=$$ins, need >=512;  watches=$$wat, need >=524288)."; \
	      echo ""; \
	      echo "This GUARANTEES a broken cluster: the control plane starts but"; \
	      echo "kube-proxy / coredns / local-path-provisioner crash-loop (they"; \
	      echo "can't create inotify watches), so storage + DNS never come up."; \
	      echo "It is NOT optional and NOT a warning to skip."; \
	      echo ""; \
	      echo "Fix (host-level, needs root) then re-run:"; \
	      echo "  sudo sysctl fs.inotify.max_user_instances=8192"; \
	      echo "  sudo sysctl fs.inotify.max_user_watches=1048576"; \
	      echo "  sudo sh -c 'printf \"fs.inotify.max_user_instances=8192\\\\nfs.inotify.max_user_watches=1048576\\\\n\" > /etc/sysctl.d/99-kind.conf'"; \
	      echo ""; \
	      echo "Or just run the demo with sudo (it will set these for you):"; \
	      echo "  sudo make demo"; \
	      echo ""; \
	      echo "If a cluster was already created under the low limit, it is"; \
	      echo "poisoned — 'make demo-down' first, then retry."; \
	      echo "(Override, not recommended: make demo INOTIFY_OK=1)"; \
	      exit 1; \
	    fi; \
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

kind-up: ## (optional, local) create a throwaway KIND cluster
	@mkdir -p $(dir $(KIND_KUBECONFIG))
	@if docker info >/dev/null 2>&1; then PROV=""; \
	 elif podman info >/dev/null 2>&1; then PROV="KIND_EXPERIMENTAL_PROVIDER=podman"; \
	 else echo "ERROR: no container runtime (run 'make preflight' for guidance)"; exit 1; fi; \
	 if env $$PROV kind get clusters 2>/dev/null | grep -q "^$(KIND_CLUSTER)$$"; then \
	   echo "==> kind cluster '$(KIND_CLUSTER)' exists; exporting its kubeconfig to $(KIND_KUBECONFIG)"; \
	   env $$PROV kind export kubeconfig --name $(KIND_CLUSTER) --kubeconfig "$(KIND_KUBECONFIG)"; \
	 else \
	   env $$PROV kind create cluster --config kind/demo-cluster.yaml --kubeconfig "$(KIND_KUBECONFIG)"; \
	 fi
	@KUBECONFIG="$(KIND_KUBECONFIG)" kubectl apply -f kind/metrics-server.yaml

kind-down: ## (optional, local) delete the KIND cluster + its isolated kubeconfig
	@kind delete cluster --name $(KIND_CLUSTER) || true
	@rm -f "$(KIND_KUBECONFIG)"

#### Sync (build-time prep) ####

sync-dashboards: ## copy dashboards/*.json into chart/dashboards/
	@mkdir -p chart/dashboards
	@cp dashboards/*.json chart/dashboards/

sync-traffic-gen: ## copy traffic_gen.py into the subchart so .Files.Get sees it
	@cp traffic_gen/traffic_gen.py chart/charts-local/traffic-gen/traffic_gen.py

#### Demo bring-up ####

#### Install into YOUR cluster (primary path) ####

cluster-check: ## verify helm + a reachable cluster (uses your current kubectl context)
	@command -v helm    >/dev/null 2>&1 || { echo "ERROR: 'helm' not found on PATH (need Helm 3.8+). https://helm.sh/docs/intro/install/"; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "ERROR: 'kubectl' not found on PATH. https://kubernetes.io/docs/tasks/tools/"; exit 1; }
	@kubectl cluster-info >/dev/null 2>&1 || { \
	  echo "ERROR: kubectl cannot reach a cluster."; \
	  echo "Point kubectl at the target cluster first, e.g.:"; \
	  echo "  kubectl config get-contexts"; \
	  echo "  kubectl config use-context <your-context>"; \
	  exit 1; }
	@printf '==> target context: %s\n' "$$(kubectl config current-context 2>/dev/null)"
	@kubectl version -o yaml 2>/dev/null | grep -i gitVersion | head -2 || true

install: cluster-check sync-dashboards sync-traffic-gen ## install/upgrade the platform into the current kubectl cluster
	@if [ -f $(SECRETS_FILE) ]; then \
	  echo "==> using operator-supplied $(SECRETS_FILE) (overrides baked-in demo key)"; \
	else \
	  echo "==> no $(SECRETS_FILE); using baked-in DEMO key (see chart/demo-secrets/README.md)"; \
	fi
	@echo "==> helm dependency update"
	@cd chart && helm dependency update
	@echo "==> installing CRDs out-of-band (Linkerd + SPIRE) before the umbrella"
	@# The umbrella ships both CRDs and the custom resources that use them.
	@# Helm validates the whole release against the API server before applying,
	@# so CRDs defined in the same release aren't visible yet. Apply the two
	@# CRD-only subcharts first (idempotent, re-run safe; the umbrella has
	@# linkerd-crds/spire-crds disabled so there is no ownership conflict).
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
	@echo "==> helm upgrade --install (verbose: --debug shows hook-by-hook progress)"
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
	@echo ""
	@echo "==> installed. Reach the components with port-forward, e.g.:"
	@echo "    kubectl -n $(NAMESPACE) port-forward svc/agent-gateway 8080:8080"
	@echo "    kubectl -n $(NAMESPACE) port-forward svc/demo-ui       8081:80"
	@echo "    (or run: make port-forward)"

uninstall: ## remove the platform release (leaves out-of-band CRDs in place)
	@helm uninstall $(HELM_RELEASE) -n $(NAMESPACE) --wait --timeout 5m || true
	@echo "Release removed. Linkerd/SPIRE CRDs were applied out-of-band and were"
	@echo "left in place; delete them manually if you want a fully clean cluster:"
	@echo "  kubectl delete crd -l linkerd.io/control-plane-ns 2>/dev/null || true"

port-forward: ## port-forward gateway + demo-ui + grafana + dex locally
	@scripts/port-forward-ui.sh

#### Optional: throwaway local KIND cluster ####

demo: bootstrap kind-up sync-dashboards sync-traffic-gen ## (optional) spin up a local KIND cluster and install into it
	@echo "==> installing into the throwaway KIND cluster ($(KIND_KUBECONFIG))"
	@KUBECONFIG="$(KIND_KUBECONFIG)" $(MAKE) --no-print-directory install
	@echo "==> port-forward (KIND)"
	@KUBECONFIG="$(KIND_KUBECONFIG)" scripts/port-forward-ui.sh

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
