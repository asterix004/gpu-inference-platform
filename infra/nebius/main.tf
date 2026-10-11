locals {
  subnet_id = var.subnet_id
  labels = {
    "managed-by" = "terraform"
    "solution"   = "gpu-inference-platform"
  }
}

# ---------------------------------------------------------------------------
# Control plane
# ---------------------------------------------------------------------------
resource "nebius_mk8s_v1_cluster" "this" {
  parent_id = var.project_id
  name      = var.cluster_name
  labels    = local.labels

  control_plane = {
    endpoints = {
      # Public API endpoint so kubectl/helm work from a laptop.
      # For production, put the API behind a bastion or VPN instead.
      public_endpoint = {}
    }
    etcd_cluster_size = var.etcd_cluster_size
    subnet_id         = local.subnet_id
    version           = var.k8s_version
  }
}

# ---------------------------------------------------------------------------
# System pool: monitoring and operators live here, never on the GPU node.
# ---------------------------------------------------------------------------
resource "nebius_mk8s_v1_node_group" "system" {
  count = var.cpu_node_count > 0 ? 1 : 0

  parent_id        = nebius_mk8s_v1_cluster.this.id
  name             = "${var.cluster_name}-system"
  labels           = local.labels
  version          = var.k8s_version
  fixed_node_count = var.cpu_node_count

  template = {
    metadata = {
      labels = { "noveon.io/pool" = "system" }
    }
    boot_disk = {
      size_gibibytes = var.cpu_disk_size_gib
      type           = "NETWORK_SSD"
    }
    network_interfaces = [
      {
        subnet_id         = local.subnet_id
        public_ip_address = null
      }
    ]
    resources = {
      platform = var.cpu_platform
      preset   = var.cpu_preset
    }
  }
}

# ---------------------------------------------------------------------------
# GPU pool: one L40S node by default. Scale to 0 between sessions.
# ---------------------------------------------------------------------------
resource "nebius_mk8s_v1_node_group" "gpu" {
  parent_id        = nebius_mk8s_v1_cluster.this.id
  name             = "${var.cluster_name}-gpu"
  labels           = local.labels
  version          = var.k8s_version
  fixed_node_count = var.gpu_node_count

  template = {
    metadata = {
      labels = { "noveon.io/pool" = "gpu" }
    }
    boot_disk = {
      size_gibibytes = var.gpu_disk_size_gib
      type           = "NETWORK_SSD"
    }
    network_interfaces = [
      {
        subnet_id         = local.subnet_id
        public_ip_address = null
      }
    ]
    resources = {
      platform = var.gpu_platform
      preset   = var.gpu_preset
    }
    gpu_settings = var.gpu_drivers_preset == null ? null : {
      drivers_preset = var.gpu_drivers_preset
    }
  }
}
