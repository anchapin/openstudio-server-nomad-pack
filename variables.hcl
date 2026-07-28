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

variable "db_image" {
  type        = string
  description = "The MongoDB database image name and tag."
  default     = "mongo:4.2"
}

variable "redis_image" {
  type        = string
  description = "The Redis image name and tag."
  default     = "redis:6.2-alpine"
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
