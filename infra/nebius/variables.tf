variable "project_id" {
  description = "Nebius project ID (project-...). Resources are created in this project's region."
  type        = string
}

variable "subnet_id" {
  description = "Existing VPC subnet ID (the project's default subnet). `make env` looks it up with the Nebius CLI."
  type        = string
}

variable "cluster_name" {
  description = "Base name for the cluster and node groups."
  type        = string
  default     = "gpu-inference"
}

variable "k8s_version" {
  description = "Kubernetes minor version. Null uses the Nebius backend default."
  type        = string
  default     = null
}

variable "etcd_cluster_size" {
  description = "Control-plane etcd members. 1 is fine for a disposable demo cluster; use 3 for anything long-lived."
  type        = number
  default     = 1
}

# ---------- system (CPU) pool ----------
variable "cpu_node_count" {
  description = "Nodes in the system pool (Prometheus, Grafana, operators). Set 0 if non-GPU vCPU quota is not yet approved."
  type        = number
  default     = 2
}

variable "cpu_platform" {
  description = "CPU platform for the system pool."
  type        = string
  default     = "cpu-d3"
}

variable "cpu_preset" {
  description = "CPU preset for the system pool. 2 x 4vcpu-16gb fits a 16 vCPU quota with headroom."
  type        = string
  default     = "4vcpu-16gb"
}

variable "cpu_disk_size_gib" {
  type    = number
  default = 64
}

# ---------- GPU pool ----------
variable "gpu_node_count" {
  description = "GPU nodes. Set 0 to keep the cluster but stop paying for the GPU between benchmark sessions."
  type        = number
  default     = 1
}

variable "gpu_platform" {
  description = "GPU platform. Check what your region offers with: nebius compute platform list --parent-id <project_id>"
  type        = string
  default     = "gpu-l40s-a"
}

variable "gpu_preset" {
  description = "GPU preset (GPU count, vCPU, RAM). The smallest single-GPU preset is enough for a 1-3B model."
  type        = string
  default     = "1gpu-8vcpu-32gb"
}

variable "gpu_disk_size_gib" {
  description = "Boot disk for the GPU node. Holds container images and the model cache (emptyDir)."
  type        = number
  default     = 200
}

variable "gpu_drivers_preset" {
  description = "Use a Nebius driver-included node image with this CUDA preset. Null = plain image, and the GPU Operator must install the driver."
  type        = string
  default     = "cuda13.0"
}
