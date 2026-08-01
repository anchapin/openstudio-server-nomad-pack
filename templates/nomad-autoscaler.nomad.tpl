[[ if var "nomad_autoscaler_enabled" . ]]
job "[[ var "job_name" . ]]-autoscaler" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "service"

  group "autoscaler" {
    count = 1
    [[ template "constraints" (var "autoscaler_constraints" .) ]]
    [[ template "affinities" (var "autoscaler_affinities" .) ]]
    [[ template "spreads" (var "autoscaler_spreads" .) ]]

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
        ulimit {
          nofile = "[[ var "docker_ulimit_nofile" . ]]"
        }
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

[[ if var "worker_autoscaling_queue_enabled" . ]]
apm "prometheus" {
  driver = "prometheus"
  config = {
    address = "{{ with service "openstudio-prometheus" }}http://{{ (index . 0).Address }}:{{ (index . 0).Port }}{{ else }}[[ var "autoscaler_prometheus_address" . ]]{{ end }}"
  }
}
[[ end ]]

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
