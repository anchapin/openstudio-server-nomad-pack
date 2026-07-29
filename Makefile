# OpenStudio Server Nomad Pack — Quick Dev Environment
#
# Prerequisites: Docker, nomad-pack
#
# Usage:
#   make up       Start Consul + Nomad in Docker
#   make deploy   Deploy OpenStudio Server via nomad-pack
#   make open     Open web UI in browser
#   make down     Stop everything and clean up

COMPOSE_FILE   = docker/docker-compose.yaml
VAR_FILE       = examples/minimal-dev.hcl
JOB_NAME       = openstudio-server-dev

# ── Infrastructure Lifecycle ──────────────────────────────────────────────────

.PHONY: up
up: check ## Start Consul + Nomad in Docker (host networking)
	docker compose -f $(COMPOSE_FILE) up -d
	@echo "Waiting for Nomad to be ready..."
	@for i in $$(seq 1 30); do \
		if curl -sf http://127.0.0.1:4646/v1/agent/self >/dev/null 2>&1; then \
			echo "Nomad ready."; break; \
		fi; \
		sleep 2; \
	done
	@echo ""
	@echo "  Nomad:  http://localhost:4646"
	@echo "  Consul: http://localhost:8500"
	@echo ""

.PHONY: down
down: stop ## Stop all jobs + remove all containers + volumes
	docker compose -f $(COMPOSE_FILE) down -v

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
logs: ## Tail Nomad agent logs
	docker compose -f $(COMPOSE_FILE) logs -f nomad

.PHONY: logs-consul
logs-consul: ## Tail Consul agent logs
	docker compose -f $(COMPOSE_FILE) logs -f consul

.PHONY: web
web: ## Show web allocation logs (via Nomad container)
	@docker compose -f $(COMPOSE_FILE) exec -T nomad nomad alloc logs -job $(JOB_NAME)-web web 2>/dev/null || echo "Job not yet deployed or alloc logs unavailable"

.PHONY: open
open: ## Open the web UI in browser
	@echo "Opening http://localhost:8080 ..."
	@open http://localhost:8080 2>/dev/null || \
		xdg-open http://localhost:8080 2>/dev/null || \
		echo "Open http://localhost:8080 in your browser."

# ── Utilities ─────────────────────────────────────────────────────────────────

.PHONY: shell-nomad
shell-nomad: ## Open a shell in the Nomad container
	docker compose -f $(COMPOSE_FILE) exec nomad sh

.PHONY: shell-consul
shell-consul: ## Open a shell in the Consul container
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
