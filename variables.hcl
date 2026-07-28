variable "job_name" {
  type        = string
  description = "The name of the Nomad job."
  default     = "openstudio-server"
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
