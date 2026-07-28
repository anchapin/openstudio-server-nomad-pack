variable "job_name" {
  type        = string
  description = "The name of the Nomad job."
  default     = "openstudio-server"
}

variable "app_version" {
  type        = string
  description = "Application version tag used for OpenStudio Server component images."
  default     = "latest"
}

variable "mongodb_storage_type" {
  type        = string
  description = "Nomad volume type for MongoDB persistence (for example, host or csi). Use ephemeral to disable persistent volume wiring."
  default     = "host"
}

variable "mongodb_volume_source" {
  type        = string
  description = "Nomad volume source name for MongoDB persistent storage."
  default     = "openstudio-mongodb"
}

variable "worker_min_replicas" {
  type        = number
  description = "Minimum number of worker replicas."
  default     = 1
}

variable "worker_max_replicas" {
  type        = number
  description = "Maximum number of worker replicas."
  default     = 3
}

variable "vault_integration_enabled" {
  type        = bool
  description = "Enable Nomad Vault integration stanzas for tasks."
  default     = false
}

variable "ingress_domain" {
  type        = string
  description = "Ingress domain used when constructing service hostnames."
  default     = "service.consul"
}

variable "region" {
  type        = string
  description = "The Nomad region where the job will be deployed."
  default     = "global"
}

variable "datacenters" {
  type        = list(string)
  description = "A list of datacenters in the region which are eligible for task placement."
  default     = ["dc1"]
}

# Image versions / repositories
variable "web_image" {
  type        = string
  description = "The image name and tag for the OpenStudio Server web container."
  default     = "nrel/openstudio-server:latest"
}

variable "worker_image" {
  type        = string
  description = "The image name and tag for the OpenStudio Server worker container."
  default     = "nrel/openstudio-server:latest"
}

variable "worker_count" {
  type        = number
  description = "The number of worker task group allocations."
  default     = 1
}

variable "worker_priority" {
  type        = number
  description = "Nomad job priority for calculation workers."
  default     = 40
}

variable "worker_queues" {
  type        = string
  description = "Comma-separated queue list processed by worker tasks."
  default     = "requeued,simulations"
}

variable "worker_process_count" {
  type        = string
  description = "COUNT environment variable passed to worker containers."
  default     = "1"
}

variable "db_image" {
  type        = string
  description = "The MongoDB database image name and tag."
  default     = "mongo:4.2"
}

variable "mongodb_storage_type" {
  type        = string
  description = "MongoDB storage type: ephemeral, host, or csi."
  default     = "ephemeral"
}

variable "mongodb_host_volume" {
  type        = string
  description = "Nomad client host_volume name for MongoDB when mongodb_storage_type is host."
  default     = "openstudio-mongodb"
}

variable "mongodb_csi_volume" {
  type        = string
  description = "Nomad CSI volume ID for MongoDB when mongodb_storage_type is csi."
  default     = "openstudio-mongodb"
}

variable "redis_image" {
  type        = string
  description = "The Redis image name and tag."
  default     = "redis:6.2-alpine"
}

variable "redis_storage_type" {
  type        = string
  description = "Redis storage type: ephemeral, host, or csi."
  default     = "ephemeral"
}

variable "redis_host_volume" {
  type        = string
  description = "Nomad client host_volume name for Redis when redis_storage_type is host."
  default     = "openstudio-redis"
}

variable "redis_csi_volume" {
  type        = string
  description = "Nomad CSI volume ID for Redis when redis_storage_type is csi."
  default     = "openstudio-redis"
}

variable "rserve_image" {
  type        = string
  description = "The Rserve image name and tag."
  default     = "nrel/rserve:latest"
}

variable "enable_consul_connect" {
  type        = bool
  description = "Enable Consul Connect sidecar proxies for mTLS service-to-service communication."
  default     = true
}

# Logging configuration variables
variable "log_driver_type" {
  type        = string
  description = "The logging driver to use for the containers."
  default     = "json-file"
}

variable "log_max_size" {
  type        = string
  description = "The maximum size of log files before rotation."
  default     = "10m"
}

variable "log_max_files" {
  type        = number
  description = "The maximum number of log files to keep."
  default     = 3
}

# Vector configuration variables
variable "enable_vector_collection" {
  type        = bool
  description = "Enable Vector sidecar for log collection."
  default     = true
}

variable "vector_image" {
  type        = string
  description = "The Vector image name and tag."
  default     = "timberio/vector:0.30.0-alpine"
}

# Scheduling helper inputs
variable "db_constraints" {
  type        = any
  description = "Placement constraints for the db group."
  default     = []
}

variable "db_affinities" {
  type        = any
  description = "Placement affinities for the db group."
  default     = []
}

variable "db_spreads" {
  type        = any
  description = "Spread rules for the db group."
  default     = []
}

variable "redis_constraints" {
  type        = any
  description = "Placement constraints for the redis group."
  default     = []
}

variable "redis_affinities" {
  type        = any
  description = "Placement affinities for the redis group."
  default     = []
}

variable "redis_spreads" {
  type        = any
  description = "Spread rules for the redis group."
  default     = []
}

variable "rserve_constraints" {
  type        = any
  description = "Placement constraints for the rserve group."
  default     = []
}

variable "rserve_affinities" {
  type        = any
  description = "Placement affinities for the rserve group."
  default     = []
}

variable "rserve_spreads" {
  type        = any
  description = "Spread rules for the rserve group."
  default     = []
}

# Backup and restore jobs
variable "backup_enabled" {
  type        = bool
  description = "Enable the periodic MongoDB and Redis backup batch job."
  default     = true
}

variable "backup_cron" {
  type        = string
  description = "Cron expression for the periodic backup schedule."
  default     = "0 2 * * * *"
}

variable "backup_prohibit_overlap" {
  type        = bool
  description = "Prevent overlapping backup runs."
  default     = true
}

variable "backup_nfs_host_volume" {
  type        = string
  description = "Nomad host volume name backed by an NFS mount for state backups."
  default     = "openstudio-backups"
}

variable "backup_mount_path" {
  type        = string
  description = "Path inside backup tasks where the NFS host volume is mounted."
  default     = "/backups"
}

variable "backup_subdirectory" {
  type        = string
  description = "Subdirectory name under the backup mount where OpenStudio state backups are written."
  default     = "openstudio-state"
}

variable "backup_retention_days" {
  type        = number
  description = "How many days of backup files to retain."
  default     = 14
}

variable "mongodb_backup_uri" {
  type        = string
  description = "MongoDB URI used by backup and restore jobs."
  default     = "mongodb://openstudio-db.service.consul:27017"
}

variable "redis_backup_host" {
  type        = string
  description = "Redis host used by backup and restore jobs."
  default     = "openstudio-redis.service.consul"
}

variable "redis_backup_port" {
  type        = number
  description = "Redis port used by backup and restore jobs."
  default     = 6379
}

variable "restore_enabled" {
  type        = bool
  description = "Enable the on-demand restore batch job definition."
  default     = true
}

# Docker runtime hardening variables
variable "docker_user" {
  type        = string
  description = "UID:GID to run containers as (non-root)."
  default     = "1000:1000"
}

variable "docker_readonly_rootfs" {
  type        = bool
  description = "Enable Docker read-only root filesystem."
  default     = true
}

variable "docker_cap_drop" {
  type        = list(string)
  description = "Linux capabilities to drop from Docker containers."
  default     = ["ALL"]
}

variable "poststop_cleanup_image" {
  type        = string
  description = "The image used for poststop cleanup lifecycle tasks."
  default     = "alpine:3.20"
}

variable "poststop_cleanup_paths" {
  type        = list(string)
  description = "Directories removed by poststop cleanup lifecycle tasks when allocations stop."
  default = [
    "/alloc/tmp/analysis",
    "/alloc/tmp/openstudio/analysis",
  ]
}
