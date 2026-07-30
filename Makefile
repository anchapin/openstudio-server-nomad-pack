# OpenStudio Server Nomad Pack — Quick Dev Environment
#
# Prerequisites: Docker, nomad-pack
# macOS also needs: consul (auto-installed via brew if missing)
#
# Usage:
#   make up       Start Consul + Nomad
#   make deploy   Deploy OpenStudio Server via nomad-pack
#   make open     Open web UI in browser
#   make down     Stop everything and clean up

COMPOSE_FILE   = docker/docker-compose.yaml
VAR_FILE       = examples/minimal-dev.hcl
JOB_NAME       = openstudio-server-dev

# Derive web port from var file (falls back to the variable default of 80).
WEB_PORT := $(shell grep -E '^\s*web_port\s*=' $(VAR_FILE) 2>/dev/null | grep -o '[0-9]*' | head -1 || echo 80)

OS := $(shell uname -s)

# ── Infrastructure Lifecycle ──────────────────────────────────────────────────

.PHONY: up
up: check ## Start Consul + Nomad
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
		lsof -ti :27017 -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true; \
		echo "BREW_MONGODB_WAS_RUNNING=1" >> /tmp/openstudio-dev-state; \
	fi
	@if lsof -i :6379 -sTCP:LISTEN >/dev/null 2>&1; then \
		echo "Stopping process(es) on port 6379 (Redis)..."; \
		brew services stop redis 2>/dev/null || true; \
		lsof -ti :6379 -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true; \
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
	# Nomad is expected to be running natively (e.g. brew install hashicorp/tap/nomad).
	# Skip the Docker Nomad container on macOS to avoid port 4646 conflicts.
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
	@echo ""
	@echo "  Nomad:  http://localhost:4646"
	@echo "  Consul: http://localhost:8500"
	@echo ""

.PHONY: down
down: stop ## Stop all jobs + remove all containers + volumes
ifeq ($(OS),Darwin)
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
	nomad-pack run -var-file $(VAR_FILE) .
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
			curl -sf -X PUT "http://127.0.0.1:4646/v1/job/$${id}/deregister" >/dev/null 2>&1 || true; \
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

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
