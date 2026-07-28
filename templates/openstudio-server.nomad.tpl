job "[[ var "job_name" . ]]" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  type        = "service"

  # Placeholder groups mapping to openstudio-server components:
  # web, web-background, worker, db, redis, rserve.
  
  group "db" {
    count = 1
    
    network {
      port "db" {
        to = 27017
      }
    }

    task "mongodb" {
      driver = "docker"

      config {
        image = "[[ var "db_image" . ]]"
        ports = ["db"]
      }

      service {
        name = "openstudio-db"
        port = "db"
        provider = "consul"
        
        check {
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }

  group "redis" {
    count = 1

    network {
      port "redis" {
        to = 6379
      }
    }

    task "redis" {
      driver = "docker"

      config {
        image = "[[ var "redis_image" . ]]"
        ports = ["redis"]
      }

      service {
        name = "openstudio-redis"
        port = "redis"
        provider = "consul"

        check {
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
