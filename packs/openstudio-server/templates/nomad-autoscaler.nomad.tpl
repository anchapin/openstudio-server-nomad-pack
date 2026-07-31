[[ if var "nomad_autoscaler_enabled" . ]]
job "[[ var "job_name" . ]]-autoscaler" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "service"

  group "autoscaler" {
    count = 1

    network {
      port "http" {
        to = 8080
      }
    }

    task "autoscaler" {
      driver = "docker"

      config {
        image        = "[[ var "nomad_autoscaler_image" . ]]"
        command      = "nomad-autoscaler"
        args         = ["agent", "-config", "local/autoscaler.hcl"]
        network_mode = "host"
      }

      template {
        destination = "local/autoscaler.hcl"
        data        = <<EOH
nomad {
  address = "[[ var "autoscaler_nomad_address" . ]]"
}

apm "nomad-apm" {
  driver = "nomad-apm"
}

# Optional Prometheus APM source:
# apm "prometheus" {
#   driver = "prometheus"
#   config = {
#     address = "http://prometheus:9090"
#   }
# }

strategy "target-value" {
  driver = "target-value"
}

# Uncomment the target block matching your cloud provider to enable node-pool autoscaling
# (Helm cluster-autoscaler-autodiscover.yaml parity)
# See: https://developer.hashicorp.com/nomad/tools/autoscaling/plugins/target/aws-asg
#
# target "aws-asg" {
#   driver = "aws-asg"
#   config = {
#     aws_region             = "us-east-1"         # AWS region containing the Auto Scaling Group
#     asg_name               = "nomad-clients"      # Name of the ASG backing Nomad client nodes
#     # access_key_id        = "<AWS_ACCESS_KEY>"   # Omit when using IAM instance roles or IRSA
#     # secret_access_key    = "<AWS_SECRET_KEY>"   # Omit when using IAM instance roles or IRSA
#     # session_token        = "<AWS_SESSION_TOKEN>"
#   }
# }

# See: https://developer.hashicorp.com/nomad/tools/autoscaling/plugins/target/gce-mig
#
# target "gce-mig" {
#   driver = "gce-mig"
#   config = {
#     project          = "my-gcp-project"          # GCP project ID containing the MIG
#     zone             = "us-central1-a"            # Zone of the Managed Instance Group
#     mig_name         = "nomad-clients"            # Name of the MIG backing Nomad client nodes
#     # credentials_path = "/secrets/gcp-sa.json"  # Omit when using Workload Identity
#   }
# }
EOH
      }

      resources {
        cpu    = 200
        memory = 128
      }

      service {
        name     = "nomad-autoscaler"
        port     = "http"
        provider = "consul"

        check {
          name     = "nomad-autoscaler-tcp"
          type     = "tcp"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }
  }
}
[[ end ]]
