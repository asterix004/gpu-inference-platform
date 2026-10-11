terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  labels = {
    managed-by = "terraform"
    solution   = "gpu-inference-platform"
  }
}

# Zonal cluster: GPU capacity is zonal anyway, and a zonal control plane
# keeps a demo cluster cheap. Same two-pool shape as the Nebius module.
resource "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.zone

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false
  resource_labels          = local.labels

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "DCGM"]
    managed_prometheus {
      enabled = true
    }
  }
}

resource "google_container_node_pool" "system" {
  name       = "system"
  cluster    = google_container_cluster.this.id
  location   = var.zone
  node_count = var.cpu_node_count

  node_config {
    machine_type = var.cpu_machine_type
    disk_size_gb = 64
    labels       = { "noveon.io/pool" = "system" }
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

resource "google_container_node_pool" "gpu" {
  name       = "gpu"
  cluster    = google_container_cluster.this.id
  location   = var.zone
  node_count = var.gpu_node_count

  node_config {
    machine_type = var.gpu_machine_type
    disk_size_gb = 200
    labels       = { "noveon.io/pool" = "gpu" }
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    guest_accelerator {
      type  = var.gpu_type
      count = 1
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  description = "Pick a zone that offers the GPU type: gcloud compute accelerator-types list --filter=name=nvidia-l4"
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  type    = string
  default = "gpu-inference"
}

variable "cpu_node_count" {
  type    = number
  default = 1
}

variable "cpu_machine_type" {
  type    = string
  default = "e2-standard-4"
}

variable "gpu_node_count" {
  type    = number
  default = 1
}

variable "gpu_machine_type" {
  description = "g2-standard-8 = 1 x NVIDIA L4 (24 GB)."
  type        = string
  default     = "g2-standard-8"
}

variable "gpu_type" {
  type    = string
  default = "nvidia-l4"
}

output "cluster_name" {
  value = google_container_cluster.this.name
}

output "zone" {
  value = var.zone
}
