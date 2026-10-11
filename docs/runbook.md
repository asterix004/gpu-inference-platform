# Runbook

## Bring-up checks
| Step | Check | If it fails |
|---|---|---|
| `make up` | Node groups reach `RUNNING` in the console | Quota: Administration → Limits (GPU count, non-GPU vCPU, disks). Platform/preset not offered in region: `nebius compute platform list --parent-id <project>` |
| `make kubeconfig` | `kubectl get nodes` shows `noveon.io/pool=system` and `=gpu` | Re-run with `--force`; confirm the active Nebius CLI profile |
| `make platform` | `nvidia.com/gpu` allocatable on the GPU node | `kubectl -n gpu-operator get pods`; device-plugin logs. If the image has no driver, reinstall with `GPU_OPERATOR_MANAGES_DRIVER=true` |
| `make deploy` | vLLM pod `Ready` | `kubectl -n inference logs deploy/vllm`. Typical causes: model download blocked (egress), CUDA/driver mismatch (see ADR 0002), OOM at load (lower `maxModelLen` or `gpuMemoryUtilization`) |
| `make bench` | Job completes, JSON saved | `kubectl -n inference logs job/vllm-bench` |

## Useful queries
```promql
# Is the GPU actually busy during the benchmark?
avg(DCGM_FI_DEV_GPU_UTIL)
# Requests queueing = the server is saturated at this concurrency
sum(vllm:num_requests_waiting)
# Output token throughput
sum(rate(vllm:generation_tokens_total[1m]))
```

## Tear-down
1. `make down` and approve the destroy.
2. `make leftovers` must print empty lists.
3. Check Billing in the console the next day.

## Next steps (deliberately deferred)
- **Autoscaling on queue depth:** KEDA scaler on `vllm:num_requests_waiting`. Deferred because a single-GPU quota makes scale-out untestable.
- **Private control plane:** bastion or WireGuard from the Nebius solution library.
- **Remote state:** S3 backend on Nebius Object Storage with versioning.
- **Model cache:** shared filesystem mounted into the GPU node group to cut cold start.
- **Multi-GPU and tensor parallelism:** rerun the benchmark on a 2- or 8-GPU preset with `--tensor-parallel-size`.
