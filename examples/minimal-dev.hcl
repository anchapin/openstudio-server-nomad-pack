# Minimal variable overrides for CI / local dev testing.
# Disables the Vector sidecar to reduce resource usage and image-pull time.
# Keep worker_count effectively zero by using this file; add a worker group
# variable to variables.hcl when the worker task group is introduced.

job_name                 = "openstudio-server-ci"
enable_vector_collection = false
