# OpenStudio Server Nomad Pack — Dev Environment + OpenStack Cluster
#
# Prerequisites: Docker, nomad-pack
# macOS also needs: consul (auto-installed via brew if missing)
#
# ── Local dev (Docker Compose) ────────────────────────────────────────────────
#   make up           Start Consul + Nomad
#   make deploy       Deploy OpenStudio Server via nomad-pack
#   make open         Open web UI in browser
#   make down         Stop everything and clean up
#
# ── OpenStack Nomad cluster (NREL aurora-179d) ────────────────────────────────
#   make os-run       Full bootstrap + deploy (consul + infra + pack)
#   make os-bootstrap Install Consul + configure all Nomad clients only
#   make os-deploy    Deploy pack only (bootstrap must be done first)
#   make os-status    Show job/node/service status
#   make os-ingress-check Validate jump-host Traefik router + ingress path
#   make os-traefik-reconcile Reconcile jump-host Traefik managed config + validate ingress
#   make os-conformance-audit Audit role/constraint conformance for critical jobs
#   make os-disk-audit Audit node free disk and report low-disk risk
#   make os-legacy-job-audit Audit legacy/orphan pack jobs that can break metadata queries
#   make os-periodic-forensics Capture queue-sweeper/watchdog periodic alloc evidence
#   make os-consul-transient-check Check recent queue-sweeper/watchdog Consul transient rate
#   make os-alerts-check Verify required ingress + periodic OpenStudio alert rules in Prometheus
#   make os-logs      Tail web job logs
#   make os-ui        Open SSH tunnels + launch Nomad/Consul UIs
#   make os-stop      Stop pack jobs
#   make os-teardown  Stop pack + infra-setup job
#   make os-tunnel    Open SSH tunnels only (foreground)
#
# OpenStack var-file: examples/advanced/openstack.hcl
# Deploy script:     scripts/deploy-openstack.sh

COMPOSE_FILE   = docker/docker-compose.yaml
VAR_FILE       = examples/quickstart/minimal-dev.hcl
PACK_DIR       = packs/openstudio-server
JOB_NAME       = openstudio-server-dev

# Derive web port from var file (falls back to the variable default of 80).
WEB_PORT := $(or $(shell grep -E '^\s*web_port\s*=' $(VAR_FILE) 2>/dev/null | grep -o '[0-9]*' | head -1),80)

OS := $(shell uname -s)

# ── Infrastructure Lifecycle ──────────────────────────────────────────────────

.PHONY: up
up: check ## Start Consul + Nomad (stops any existing pack jobs first)
	@EXISTING=$$(curl -sf "http://127.0.0.1:4646/v1/jobs?prefix=$(JOB_NAME)" 2>/dev/null | \
		python3 -c "import sys,json; [print(j['ID']) for j in json.load(sys.stdin)]" 2>/dev/null); \
	if [ -n "$$EXISTING" ]; then \
		echo "Pre-flight: stopping existing OpenStudio Server jobs..."; \
		for id in $$EXISTING; do \
			echo "  Deregistering $$id..."; \
			curl -sf -X DELETE "http://127.0.0.1:4646/v1/job/$${id}?purge=true" >/dev/null 2>&1 || true; \
		done; \
		echo "  Waiting for containers to be released..."; \
		sleep 5; \
	fi
ifeq ($(OS),Darwin)
	# macOS: Docker Desktop host networking does not expose container ports to the
	# Mac host without enabling a non-default feature flag, and even then Consul
	# health checks can't reach services on the Mac's loopback from inside Docker.
	# Run Consul natively so it shares the Mac's network with Nomad's task containers.
	@if ! command -v consul >/dev/null 2>&1; then \
		echo "Installing Consul via Homebrew..."; \
		brew install consul; \
	fi
	# Stop any Homebrew-managed MongoDB and Redis that would conflict with the
	# static ports (27017, 6379) used by the Nomad-managed containers.
	@if lsof -i :27017 -sTCP:LISTEN >/dev/null 2>&1; then \
		echo "Stopping process(es) on port 27017 (MongoDB)..."; \
		brew services stop mongodb-community 2>/dev/null || brew services stop mongodb 2>/dev/null || true; \
		sleep 1; \
		lsof -ti :27017 -sTCP:LISTEN 2>/dev/null | while read pid; do \
			pname=$$(ps -p $$pid -o comm= 2>/dev/null || echo ""); \
			if echo "$$pname" | grep -qiE 'mongod'; then \
				echo "  Killing mongod (pid $$pid)..."; kill $$pid 2>/dev/null || true; \
			else \
				echo "  Skipping pid $$pid ($$pname) — not a MongoDB process"; \
			fi; \
		done; \
		echo "BREW_MONGODB_WAS_RUNNING=1" >> /tmp/openstudio-dev-state; \
	fi
	@if lsof -i :6379 -sTCP:LISTEN >/dev/null 2>&1; then \
		echo "Stopping process(es) on port 6379 (Redis)..."; \
		brew services stop redis 2>/dev/null || true; \
		sleep 1; \
		lsof -ti :6379 -sTCP:LISTEN 2>/dev/null | while read pid; do \
			pname=$$(ps -p $$pid -o comm= 2>/dev/null || echo ""); \
			if echo "$$pname" | grep -qiE 'redis'; then \
				echo "  Killing redis-server (pid $$pid)..."; kill $$pid 2>/dev/null || true; \
			else \
				echo "  Skipping pid $$pid ($$pname) — not a Redis process"; \
			fi; \
		done; \
		echo "BREW_REDIS_WAS_RUNNING=1" >> /tmp/openstudio-dev-state; \
	fi
	@if ! curl -sf http://127.0.0.1:8500/v1/status/leader >/dev/null 2>&1; then \
		consul agent -dev -client=0.0.0.0 -bind=127.0.0.1 \
			>/tmp/consul-dev.log 2>&1 & \
		echo "$$!" > /tmp/consul-dev.pid; \
		echo "Started native Consul (pid $$(cat /tmp/consul-dev.pid))"; \
	else \
		echo "Consul already running."; \
	fi
	# Start Nomad natively with the macOS config (enables Docker bind mounts).
	# If already running, check whether volumes are enabled; restart if not.
	@NOMAD_VOLUMES_OK=0; \
	if curl -sf http://127.0.0.1:4646/v1/agent/self >/dev/null 2>&1; then \
		CONF=$$(cat /tmp/nomad-macos-dev.pid 2>/dev/null || echo ""); \
		if curl -sf http://127.0.0.1:4646/v1/node/self 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); v=d.get('Attributes',{}).get('driver.docker.volumes.enabled','false'); print('ok' if v=='1' or v=='true' else 'no')" 2>/dev/null | grep -q ok; then \
			echo "Nomad already running with volumes enabled."; NOMAD_VOLUMES_OK=1; \
		else \
			echo "Nomad running but volumes NOT enabled — restarting with macOS config..."; \
			NPID=$$(cat /tmp/nomad-macos-dev.pid 2>/dev/null); \
			[ -n "$$NPID" ] && kill $$NPID 2>/dev/null && echo "  Stopped Nomad (pid $$NPID)" || \
				(kill $$(pgrep -f 'nomad agent' | head -1) 2>/dev/null && echo "  Stopped existing Nomad"); \
			sleep 3; \
		fi; \
	fi; \
	if [ "$$NOMAD_VOLUMES_OK" = "0" ]; then \
		mkdir -p /tmp/nomad-macos-dev/data; \
		NOMAD_CONF=$$(realpath docker/nomad-macos.hcl 2>/dev/null || echo "$$(pwd)/docker/nomad-macos.hcl"); \
		nomad agent -dev -config=$$NOMAD_CONF -log-level=WARN \
			>/tmp/nomad-macos-dev.log 2>&1 & \
		echo "$$!" > /tmp/nomad-macos-dev.pid; \
		echo "Started native Nomad (pid $$(cat /tmp/nomad-macos-dev.pid)) with volumes enabled"; \
	fi
else
	docker compose -f $(COMPOSE_FILE) up -d
endif
	@echo "Waiting for Nomad to be ready..."
	@for i in $$(seq 1 30); do \
		if curl -sf http://127.0.0.1:4646/v1/agent/self >/dev/null 2>&1; then \
			echo "Nomad ready."; break; \
		fi; \
		sleep 2; \
	done
	@echo "Waiting for Consul to be ready..."
	@for i in $$(seq 1 15); do \
		if curl -sf http://127.0.0.1:8500/v1/status/leader >/dev/null 2>&1; then \
			echo "Consul ready."; break; \
		fi; \
		sleep 2; \
	done
	@echo "Creating Docker named volume openstudio-osdata-dev (avoids VirtioFS corruption on macOS)..."
	@docker volume create openstudio-osdata-dev 2>/dev/null || true
	@echo ""
	@echo "  Nomad:  http://localhost:4646"
	@echo "  Consul: http://localhost:8500"
	@echo ""

.PHONY: down
down: stop ## Stop all jobs + remove all containers + volumes
ifeq ($(OS),Darwin)
	@if [ -f /tmp/nomad-macos-dev.pid ]; then \
		PID=$$(cat /tmp/nomad-macos-dev.pid); \
		kill $$PID 2>/dev/null && echo "Stopped native Nomad (pid $$PID)" || true; \
		rm -f /tmp/nomad-macos-dev.pid; \
	fi
	@if [ -f /tmp/consul-dev.pid ]; then \
		PID=$$(cat /tmp/consul-dev.pid); \
		kill $$PID 2>/dev/null && echo "Stopped native Consul (pid $$PID)" || true; \
		rm -f /tmp/consul-dev.pid; \
	fi
	# Restore any Homebrew services that were stopped by 'make up'.
	@if [ -f /tmp/openstudio-dev-state ]; then \
		if grep -q "BREW_MONGODB_WAS_RUNNING=1" /tmp/openstudio-dev-state 2>/dev/null; then \
			echo "Restarting Homebrew MongoDB..."; \
			brew services start mongodb-community 2>/dev/null || brew services start mongodb 2>/dev/null || true; \
		fi; \
		if grep -q "BREW_REDIS_WAS_RUNNING=1" /tmp/openstudio-dev-state 2>/dev/null; then \
			echo "Restarting Homebrew Redis..."; \
			brew services start redis 2>/dev/null || true; \
		fi; \
		rm -f /tmp/openstudio-dev-state; \
	fi
else
	docker compose -f $(COMPOSE_FILE) down -v
endif

.PHONY: restart
restart: down up ## Full restart (clean infra)

# ── Pack Deployment ──────────────────────────────────────────────────────────

.PHONY: deploy
deploy: check-infra ## Deploy OpenStudio Server with minimal-dev config
	@echo "Rendering and deploying jobs..."
	@rm -rf /tmp/nomad-pack-render && mkdir /tmp/nomad-pack-render
	@NOMAD_ADDR=http://127.0.0.1:4646 nomad-pack render --var-file $(VAR_FILE) \
		--to-dir /tmp/nomad-pack-render $(PACK_DIR) >/dev/null 2>&1
	@for f in /tmp/nomad-pack-render/openstudio-server/*.nomad; do \
		job=$$(basename "$$f" .hcl); \
		echo "  Submitting $$job..."; \
		NOMAD_ADDR=http://127.0.0.1:4646 nomad job run -detach "$$f" >/dev/null 2>&1 || \
		echo "    (warning: submit returned non-zero, may already be running)"; \
	done
	@rm -rf /tmp/nomad-pack-render
	@echo ""
	@echo "Deploying... waiting for services (up to 2 min)..."
	@echo "Run 'make status' to check progress."

.PHONY: stop
stop: ## Stop and purge all OpenStudio Server jobs via API
	@echo "Stopping all jobs with prefix $(JOB_NAME)..."
	@IDS=$$(curl -sf "http://127.0.0.1:4646/v1/jobs?prefix=$(JOB_NAME)" 2>/dev/null | python3 -c "import sys,json; [print(j['ID']) for j in json.load(sys.stdin)]" 2>/dev/null); \
	if [ -n "$$IDS" ]; then \
		for id in $$IDS; do \
			echo "  Stopping $$id..."; \
			curl -sf -X DELETE "http://127.0.0.1:4646/v1/job/$${id}?purge=true" >/dev/null 2>&1 || true; \
		done; \
	else \
		echo "(no jobs found with prefix $(JOB_NAME))"; \
	fi

.PHONY: redeploy
redeploy: stop deploy ## Re-deploy (stop + deploy)

# ── Monitoring ────────────────────────────────────────────────────────────────

.PHONY: status
status: ## Show deployment status (jobs + nodes + services) via API
	@echo "=== Nomad Jobs (prefix: $(JOB_NAME)) ==="
	@curl -sf "http://127.0.0.1:4646/v1/jobs?prefix=$(JOB_NAME)" 2>/dev/null | python3 -c "import sys,json; [print(f\"  {j['ID']:40s} Status: {j.get('Status','?'):10s} Type: {j.get('Type','?'):10s} Priority: {j.get('Priority','?')}\") for j in json.load(sys.stdin)]" 2>/dev/null || echo "  (no jobs found)"
	@echo ""
	@echo "=== Nomad Nodes ==="
	@curl -sf http://127.0.0.1:4646/v1/nodes 2>/dev/null | python3 -c "import sys,json; nodes=json.load(sys.stdin); [print(f\"  {n['ID'][:8]}  {n['Datacenter']}  {n['Name']}  Status:{n['Status']}  Eligible:{n.get('SchedulingEligibility','?')}\") for n in nodes]" 2>/dev/null || echo "(none)"
	@echo ""
	@echo "=== Consul Services ==="
	@curl -sf http://127.0.0.1:8500/v1/catalog/services 2>/dev/null | python3 -c "import sys,json; svcs=json.load(sys.stdin); [print(f'  {s}') for s in sorted(svcs.keys()) if 'openstudio' in s]" 2>/dev/null || echo "(none or not running)"

.PHONY: logs
logs: ## Tail Nomad agent logs (Docker only; native Nomad logs to stderr)
	docker compose -f $(COMPOSE_FILE) logs -f nomad

.PHONY: logs-consul
logs-consul: ## Tail Consul agent logs (Docker) or /tmp/consul-dev.log (macOS native)
ifeq ($(OS),Darwin)
	tail -f /tmp/consul-dev.log
else
	docker compose -f $(COMPOSE_FILE) logs -f consul
endif

.PHONY: web
web: ## Show web allocation logs
	@nomad alloc logs -job $(JOB_NAME)-web web 2>/dev/null || echo "Job not yet deployed or alloc logs unavailable"

.PHONY: open
open: ## Open the web UI in browser
	@echo "Opening http://localhost:$(WEB_PORT) ..."
	@open http://localhost:$(WEB_PORT) 2>/dev/null || \
		xdg-open http://localhost:$(WEB_PORT) 2>/dev/null || \
		echo "Open http://localhost:$(WEB_PORT) in your browser."

# ── Utilities ─────────────────────────────────────────────────────────────────

.PHONY: shell-nomad
shell-nomad: ## Open a shell in the Nomad container (Linux/Docker only)
	docker compose -f $(COMPOSE_FILE) exec nomad sh

.PHONY: shell-consul
shell-consul: ## Open a shell in the Consul container (Linux/Docker only)
	docker compose -f $(COMPOSE_FILE) exec consul sh

.PHONY: ps
ps: ## Show running containers
	docker compose -f $(COMPOSE_FILE) ps

.PHONY: check
check: ## Verify prerequisites are installed
	@echo "Checking prerequisites..."
	@command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found. Install Docker Desktop."; exit 1; }
	@command -v nomad-pack >/dev/null 2>&1 || { echo "ERROR: nomad-pack not found. Install: brew install hashicorp/tap/nomad-pack"; exit 1; }
	@echo "  docker:     $$(docker --version)"
	@echo "  nomad-pack: $$(nomad-pack --version 2>&1 | head -1)"
	@echo "  docker compose: $$(docker compose version 2>&1 || echo '(Docker Compose v2 required)')"
	@docker info >/dev/null 2>&1 || { echo "ERROR: Docker daemon not running."; exit 1; }
ifeq ($(OS),Darwin)
	@command -v nomad >/dev/null 2>&1 || { echo "ERROR: nomad not found. Install: brew install hashicorp/tap/nomad"; exit 1; }
	@echo "  nomad:      $$(nomad version 2>&1 | head -1)"
endif
	@echo ""

.PHONY: check-infra
check-infra:
	@curl -sf http://127.0.0.1:4646/v1/agent/self >/dev/null 2>&1 || { echo "ERROR: Nomad not reachable at http://127.0.0.1:4646. Run 'make up' first."; exit 1; }
	@curl -sf http://127.0.0.1:8500/v1/status/leader >/dev/null 2>&1 || { echo "ERROR: Consul not reachable at http://127.0.0.1:8500. Run 'make up' first."; exit 1; }
	@echo "Infrastructure is running."

# ── OpenStack Cluster ─────────────────────────────────────────────────────────
# All os-* targets delegate to scripts/deploy-openstack.sh.
# Env overrides: SSH_KEY, OS_VAR_FILE, OS_JOB_NAME

OS_SCRIPT = bash scripts/deploy-openstack.sh

.PHONY: os-run
os-run: ## [OpenStack] Full bootstrap + deploy: Consul → infra-setup → pack
	$(OS_SCRIPT)

.PHONY: os-bootstrap
os-bootstrap: ## [OpenStack] Install Consul + configure all Nomad clients (no pack deploy)
	$(OS_SCRIPT) --bootstrap

.PHONY: os-deploy
os-deploy: ## [OpenStack] Deploy the nomad-pack only (bootstrap must be done first)
	$(OS_SCRIPT) --deploy

.PHONY: os-redeploy
os-redeploy: ## [OpenStack] Stop + redeploy the pack
	$(OS_SCRIPT) --redeploy

.PHONY: os-status
os-status: ## [OpenStack] Show job, node, and Consul service status
	$(OS_SCRIPT) --status

.PHONY: os-ingress-check
os-ingress-check: ## [OpenStack] Validate Traefik route + external ingress response
	$(OS_SCRIPT) --ingress-check

.PHONY: os-traefik-reconcile
os-traefik-reconcile: ## [OpenStack] Reconcile jump-host Traefik config, restart, and validate ingress
	$(OS_SCRIPT) --traefik-reconcile

.PHONY: os-conformance-audit
os-conformance-audit: ## [OpenStack] Audit critical job node-role constraints and placements
	$(OS_SCRIPT) --conformance-audit

.PHONY: os-disk-audit
os-disk-audit: ## [OpenStack] Audit client root disk free-space risk (no mutations)
	$(OS_SCRIPT) --disk-audit

.PHONY: os-legacy-job-audit
os-legacy-job-audit: ## [OpenStack] Audit legacy/orphan pack jobs (dry-run)
	bash scripts/audit-legacy-pack-jobs.sh --job-name $(or $(OS_JOB_NAME),openstudio-server) --namespace $(or $(NOMAD_NAMESPACE),default)

.PHONY: os-periodic-forensics
os-periodic-forensics: ## [OpenStack] Capture queue-sweeper/watchdog periodic alloc forensics
	bash scripts/capture-periodic-forensics.sh --job-name $(or $(OS_JOB_NAME),openstudio-server) --namespace $(or $(NOMAD_NAMESPACE),default)

.PHONY: os-consul-transient-check
os-consul-transient-check: ## [OpenStack] Check recent queue-sweeper/watchdog Consul transient rate
	bash scripts/check-queue-sweeper-consul-transient-rate.sh --job-name $(or $(OS_JOB_NAME),openstudio-server) --namespace $(or $(NOMAD_NAMESPACE),default)

.PHONY: os-alerts-check
os-alerts-check: ## [OpenStack] Verify required OpenStudio alert rules are loaded in Prometheus
	bash scripts/check-prometheus-openstudio-rules.sh --prometheus-url $(or $(PROMETHEUS_URL),http://localhost:9090)

.PHONY: os-logs
os-logs: ## [OpenStack] Tail web job logs (override: make os-logs JOB=worker)
	$(OS_SCRIPT) --logs $(or $(JOB),web)

.PHONY: os-ui
os-ui: ## [OpenStack] Open SSH tunnels and launch Nomad + Consul UIs
	$(OS_SCRIPT) --ui

.PHONY: os-tunnel
os-tunnel: ## [OpenStack] Open SSH tunnels only (foreground — keep terminal open)
	$(OS_SCRIPT) --tunnel

.PHONY: os-stop
os-stop: ## [OpenStack] Stop all pack jobs
	$(OS_SCRIPT) --stop

.PHONY: os-teardown
os-teardown: ## [OpenStack] Stop pack jobs + infra-setup system job
	$(OS_SCRIPT) --teardown

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
