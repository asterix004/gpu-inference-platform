# ADR 0004: Inference on Kubernetes, training on Slurm (Soperator)

**Status:** accepted. The training module is built and smoke-tested on CPU. The GPU run has not happened yet. The smallest Soperator cluster needs 6 VMs and this Nebius tenant allows 2. On 2026-10-13 I requested VMs 2 → 8 (request G287530497, still pending) and non-GPU vCPUs 16 → 24 (declined on 2026-10-14; 16 still fits this layout). The VM request is being followed up with Nebius support with a written justification. The run, about 2 hours and $5–8, goes ahead when it is granted.

## Context
The platform serves a model on Kubernetes: vLLM behind a Service, scaled by KEDA and the Cluster Autoscaler, measured in $ per 1M output tokens. The next workload is training that model: a LoRA fine-tune today, multi-node full fine-tunes later. The two workloads want different things from a scheduler.

| | Inference | Training |
|---|---|---|
| Shape | Long-running service, many small requests | Batch job that needs N GPUs at once and then exits |
| Scheduling need | Autoscale replicas on load; restart failed pods anywhere | Gang scheduling (all N nodes or none), topology awareness, queues, fair share between teams |
| Failure handling | Replace the pod, retry the request | Drain a bad node, resume from checkpoint |
| Who operates it | Platform team, GitOps | Researchers, `sbatch` / `srun` / `squeue` |
| Unit of cost | $ per 1M tokens served | GPU-hours per run, $ per 1M tokens trained |

## Options
| Option | For | Against |
|---|---|---|
| **Kubernetes for both** (Kubeflow Trainer or JobSet, with Kueue for queues and gang admission) | One scheduler, one GitOps path, one set of dashboards | Researchers lose the Slurm interface they already script against; fair share, accounting and preemption have to be assembled from several projects |
| **Slurm on VMs for training, Kubernetes for inference** | Each workload gets its native scheduler | Two fleets, two node images, two driver stacks; GPUs cannot move between them without reprovisioning |
| **Soperator: Slurm running on Kubernetes** | Researchers get real Slurm (sbatch, srun, partitions, accounting); the platform keeps one substrate: same node groups, GPU Operator, DCGM metrics, Terraform and Kubernetes health checks; GPUs can move between training and inference | Two schedulers to understand; a shared "jail" filesystem to size and pay for; larger minimum footprint than a single VM |

## Decision
Train with **Slurm on Soperator**, keep serving on Kubernetes.

- **Reference build:** the Nebius Terraform recipe (`nebius-solution-library`, pinned tag `soperator-v4.1.13-2`, Soperator 4.1.13) with this repo's overrides in `training/soperator/noveon-l40s.auto.tfvars.example`: 2 × L40S workers, no InfiniBand, smallest system and controller nodes the recipe allows.
- **In production on Nebius:** Managed Soperator, which needs a capacity block group (reserved GPUs) for GPU workers. The same capacity block can back the inference cluster.
- **The job is plain Slurm.** `training/slurm/finetune.sbatch` runs one `torchrun` per node with the c10d rendezvous on the first node, so the same script runs on any Slurm cluster, not just Soperator.

## Why
1. **The interface is the product for researchers.** `sbatch --nodes=4 --gpus-per-node=8 finetune.sbatch` is how training teams already work. Soperator keeps that interface while the platform team runs Kubernetes underneath.
2. **One GPU substrate.** Training and inference nodes use the same driver-included images (ADR 0002), the same GPU Operator and DCGM metrics (the Nebius DCGM fix applies to both), and the same Terraform provider. Lessons learned once apply twice.
3. **GPUs can move to where the demand is.** Soperator's ephemeral nodes (`scontrol power down asap worker-[3,4]`) return reserved GPUs to the capacity block, and an inference node group on the same block picks them up. The reverse works when a training run needs them back. That turns "how many GPUs for training versus inference" from a provisioning decision into an operational one.
4. **Gang scheduling and health checks are built in.** Slurm starts a multi-node job only when every node is available. Soperator's active checks run GPU, storage and network probes and drain bad nodes, which is the failure mode that wastes the most GPU-hours in training.

## Consequences
- **Minimum footprint.** The recipe enforces at least 3 system nodes plus a controller: 6 instances, 16 non-GPU vCPUs and 2 GPUs for the smallest useful cluster, plus a 512 GiB jail and a 128 GiB spool filesystem. This tenant's quota of 2 compute instances blocks it; the same quota already forced the inference cluster down to one system node.
- **No InfiniBand on L40S.** NCCL runs over TCP, so `training/nccl_check.py` must run before any multi-node job; its bus bandwidth bounds how far data-parallel training scales. On H100/B200/B300 with an InfiniBand fabric the same script should show an order of magnitude more.
- **Shared filesystem is the hand-off.** The jail holds the venv, the Hugging Face cache and run outputs, so weights download once per cluster. Adapters leave the jail for object storage; vLLM serves them with `--enable-lora`. Automating that hand-off is the next step.
- **Two schedulers to operate.** Kubernetes and Slurm each have their own failure modes and observability. Soperator exports Slurm metrics to the same Prometheus, which keeps one place to look.
- **Cost is reported in the same units.** `finetune.py` writes GPU-hours and $ per 1M trained tokens to `training-report.json`, alongside the inference benchmark's $ per 1M output tokens.

## Not chosen, and when to revisit
- **Kubernetes-only training** (Kubeflow Trainer + Kueue) fits a platform team that owns training too and prefers one GitOps path. Revisit if training stays single-node LoRA, where gang scheduling and fair share add little.
- **Managed Soperator vs the recipe:** the recipe is for a reference build that someone can read and reproduce; Managed Soperator is the default once a capacity block exists.
