terraform {
  required_version = ">= 1.6"

  required_providers {
    nebius = {
      source  = "nebius/nebius"
      version = ">= 0.6.23"
    }
  }
}

# Authenticates with the active Nebius CLI profile (`nebius profile create`),
# so no long-lived token or key is stored in this repo or in tfvars.
provider "nebius" {
  domain            = "api.nebius.cloud"
  timeout           = "10m"
  per_retry_timeout = "1m"
  retries           = 10
  profile           = {}
}
