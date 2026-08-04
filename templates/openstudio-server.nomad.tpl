[[/* openstudio-server.nomad.tpl — consolidated architecture marker.
Service components are rendered by consolidated per-tier templates:
  web.nomad.tpl → <job_name>-web (task groups: web, web-background, worker)
  db.nomad.tpl → <job_name>-db (MongoDB)
  redis.nomad.tpl → <job_name>-redis
  rserve.nomad.tpl → <job_name>-rserve
  queue-sweeper.nomad.tpl → <job_name>-queue-sweeper (task groups: queue-sweeper, stall-watchdog)
This file intentionally renders nothing (fix #223, #405).

Pack invariant assertions — fail fast before any job HCL is emitted.
*/]]
[[/* Invariant: web_count must be exactly 1.
     Multiple web replicas cause split-brain because the web process writes
     artefacts to local container filesystem with no distributed file-locking.
     See AGENTS.md §'web_count constraint' and docs/infrastructure/storage.md for details. */]]
[[- if ne (var "web_count" .) 1 -]]
[[ fail (print "INVARIANT VIOLATION: web_count must be exactly 1 (got " (var "web_count" .) "). Multiple web replicas cause split-brain file corruption. See docs/infrastructure/storage.md for details.") ]]
[[- end -]]
[[/* Invariant: web_priority must be strictly greater than worker_priority.
     Inverting them causes the scheduler to evict the web UI first under
     resource contention. Mirrors Kubernetes high-priority vs low-priority
     PriorityClass relationship in the Helm chart. */]]
[[- if le (var "web_priority" .) (var "worker_priority" .) -]]
[[ fail (print "INVARIANT VIOLATION: web_priority (" (var "web_priority" .) ") must be strictly greater than worker_priority (" (var "worker_priority" .) "). Inverting them causes the scheduler to evict the web UI first under resource contention.") ]]
[[- end -]]
