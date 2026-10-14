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

## Quota for the Soperator training cluster

Smallest layout from `training/soperator/noveon-l40s.auto.tfvars.example`: 3 system + 1 controller (cpu-d3 4vcpu-16gb) + 2 L40S workers (gpu-l40s-a 1gpu-8vcpu-32gb), login pod on the system nodes, no NFS server, no accounting. Checked against this tenant's eu-north1 compute quotas on 2026-10-14 (Administration → Limits → Quotas):

| Quota | Needed | Tenant limit | Status |
|---|---|---|---|
| `compute.instance.count` (virtual machines) | 6 | 2 | **Blocker: request 8** (6 + headroom for a rolling node replacement) |
| `compute.instance.non-gpu.vcpu` | 16 (4 × 4 vCPU) | 16 | Fits exactly. A request for 24 (headroom for replacing a system node) was declined on 2026-10-14, so keep CPU nodes at 4 vCPU and avoid rolling node updates during a run |
| `compute.instance.gpu.l40s` | 2 | 8 | OK |
| `compute.disk.count` | 6 boot disks | 12 | OK (raised from 4) |
| `compute.disk.size.network-ssd` | 1.5 TiB (3 × 128 + 128 + 2 × 512 GiB) | 4 TiB | OK |
| `compute.filesystem.count` | 2 (jail, controller spool) | 32 | OK |
| `compute.filesystem.size.network-ssd` | 640 GiB (512 + 128) | 4 TiB | OK |
| `compute.gpucluster.count` | 0 (L40S has no InfiniBand) | 5 | Not used |

Also check the Managed Kubernetes quotas (clusters, node groups) in the same view; the recipe creates one cluster and several node groups. Approved requests can take a day, so file them before the session, not during it.

Expected cost while up: 2 × L40S at $1.55/h plus 4 small CPU nodes and the two filesystems, roughly $3.50–4/h. `terraform destroy` from the installation directory, then `make leftovers`.

## Next steps (deliberately deferred)
- **First GPU training run on Soperator:** `training/` is smoke-tested on CPU. Raise `compute.instance.count` first (see *Quota for the Soperator training cluster*), then `make soperator-recipe` → `terraform apply` (~40 min) → `sbatch training/slurm/nccl-check.sbatch` and `finetune.sbatch`. Record `training-report.json` in `results/training/`.
- **Adapter hand-off to serving:** copy the LoRA adapter from the jail to object storage and serve it with vLLM `--enable-lora --lora-modules` via `extraArgs`.
- **Pre-pulled vLLM image:** node scale-out takes <1 min, but the 10 GB image pull plus model load takes ~8 min. That is the main scale-out cost.
- **Private control plane:** bastion or WireGuard from the Nebius solution library.
- **Remote state:** S3 backend on Nebius Object Storage with versioning.
- **Model cache:** shared filesystem mounted into the GPU node group to cut cold start.
- **Multi-GPU and tensor parallelism:** rerun the benchmark on a 2- or 8-GPU preset with `--tensor-parallel-size`.
