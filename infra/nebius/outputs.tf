output "cluster_id" {
  description = "Managed Kubernetes cluster ID. Used by `make kubeconfig`."
  value       = nebius_mk8s_v1_cluster.this.id
}

output "gpu_node_group" {
  value = {
    id       = nebius_mk8s_v1_node_group.gpu.id
    platform = var.gpu_platform
    preset   = var.gpu_preset
    count    = var.gpu_node_count
  }
}

output "system_node_count" {
  value = var.cpu_node_count
}
