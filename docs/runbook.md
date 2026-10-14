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

## Autoscaling test (KEDA + Cluster Autoscaler)
```bash
make up TF_EXTRA="-var cpu_node_count=0 -var gpu_node_count=1 -var gpu_max_node_count=2"
make kubeconfig && make platform && make keda
make deploy HELM_EXTRA="--set autoscaling.enabled=true"
make load LABEL="nebius L40S keda" LOAD_MINUTES=25 LOAD_CONCURRENCY=96
make down TF_EXTRA="-var cpu_node_count=0 -var gpu_node_count=1 -var gpu_max_node_count=2"
```
- The pool starts at `max_node_count`. To see a scale-up, cordon one node before `make platform` and move any `kube-system` Deployment pods off it, then wait ~10–20 min for the autoscaler to remove it.
- Nodes added by the autoscaler come up with `nvidia.com/gpu.deploy.operands=false`. Run `kubectl label nodes -l noveon.io/pool=gpu nvidia.com/gpu.deploy.operands=true --overwrite` to get DCGM metrics from them.
- Watch: `kubectl -n inference get hpa keda-hpa-vllm -w` and `kubectl -n kube-system get cm cluster-autoscaler-status -o yaml`.

## Next steps (deliberately deferred)
- **First GPU training run on Soperator:** `training/` is smoke-tested on CPU. Needs instance quota ≥ 6 (3 system + 1 controller + 2 L40S workers), then `make soperator-recipe` → `terraform apply` (~40 min) → `sbatch training/slurm/nccl-check.sbatch` and `finetune.sbatch`. Record `training-report.json` in `results/training/`.
- **Adapter hand-off to serving:** copy the LoRA adapter from the jail to object storage and serve it with vLLM `--enable-lora --lora-modules` via `extraArgs`.
- **Pre-pulled vLLM image:** node scale-out takes <1 min, but the 10 GB image pull plus model load takes ~8 min. That is the main scale-out cost.
- **Private control plane:** bastion or WireGuard from the Nebius solution library.
- **Remote state:** S3 backend on Nebius Object Storage with versioning.
- **Model cache:** shared filesystem mounted into the GPU node group to cut cold start.
- **Multi-GPU and tensor parallelism:** rerun the benchmark on a 2- or 8-GPU preset with `--tensor-parallel-size`.
