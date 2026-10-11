# ADR 0002: L40S first, driver-included node images, GPU Operator without driver management

**Status:** accepted

## Context
The workload is a 1–3B parameter model served at batch. Weights plus KV cache fit comfortably in 24–48 GB. Cost per token matters more than peak single-request latency.

## Decision
1. **GPU class:** start on 1 × NVIDIA L40S (48 GB). Run the identical workload on 1 × H100 afterwards to show where the more expensive GPU does and does not pay off.
2. **Drivers:** on Nebius, use the driver-included node image (`gpu_settings.drivers_preset`). The NVIDIA GPU Operator then runs only the device plugin, GPU feature discovery and the DCGM exporter (`driver.enabled=false`, `toolkit.enabled=false`).
3. **GKE:** use GKE-managed driver installation and GKE's managed DCGM metrics instead of the GPU Operator.

## Why
- Driver-included images remove the slowest and most failure-prone step of GPU node bring-up (in-cluster driver compilation), so nodes become schedulable sooner.
- Keeping the GPU Operator for the device plugin and DCGM keeps the observability path identical to a self-managed cluster.
- One switch (`gpu_drivers_preset = null` plus `GPU_OPERATOR_MANAGES_DRIVER=true`) falls back to operator-managed drivers when a custom driver version is needed.

## Consequences
- The CUDA version is set by the Nebius image preset. vLLM's container must be compatible with that driver, which is the first thing to check if a vLLM upgrade fails to start.
