[[/* openstudio-server.nomad.tpl — split-job architecture marker.
All service components are rendered by dedicated per-component templates:
  web.nomad.tpl → <job_name>-web
  worker.nomad.tpl → <job_name>-worker
  db.nomad.tpl → <job_name>-db (MongoDB)
  redis.nomad.tpl → <job_name>-redis
  rserve.nomad.tpl → <job_name>-rserve
This file intentionally renders nothing (fix #223).
*/]]
