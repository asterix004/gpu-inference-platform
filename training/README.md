# Training: LoRA fine-tune on Slurm (Soperator)

The inference side of this repo serves Qwen2.5-1.5B-Instruct on Kubernetes. This module trains it: a LoRA fine-tune that runs as a normal Slurm job, on one node or many, on Nebius's Soperator (Slurm running on Kubernetes). Why Slurm for training and Kubernetes for serving is in [ADR 0004](../docs/adr/0004-inference-on-kubernetes-training-on-slurm.md).

**Status:** built and smoke-tested on CPU (2 processes, tiny model). The GPU run has not happened yet. The smallest Soperator cluster needs 6 VMs and this Nebius tenant allows 2. On 2026-10-13 I requested VMs 2 → 8 (request G287530497, still pending) and non-GPU vCPUs 16 → 24 (declined on 2026-10-14; 16 still fits this layout). The VM request is being followed up with Nebius support with a written justification. The run, about 2 hours and $5–8, goes ahead when it is granted.

## Layout

```
training/
  finetune.py                 LoRA SFT with transformers + peft; torchrun DDP; writes adapter + training-report.json
  nccl_check.py               All-reduce bandwidth across all GPUs in the job (pre-flight for multi-node)
  requirements.txt            Pinned torch / transformers / peft / datasets / accelerate
  slurm/setup-venv.sh         One-time venv on the shared jail (visible on every worker)
  slurm/nccl-check.sbatch     sbatch wrapper for nccl_check.py
  slurm/finetune.sbatch       sbatch wrapper for finetune.py: one torchrun per node, c10d rendezvous
  soperator/noveon-l40s.auto.tfvars.example   Overrides for the Nebius Soperator Terraform recipe: 2 x L40S
```

## What the job does

- **Model and data:** LoRA (r=16, all linear layers) on `Qwen/Qwen2.5-1.5B-Instruct`, the model `charts/vllm` serves. Default data is 20k rows of `yahma/alpaca-cleaned`, formatted with the model's chat template. Loss is computed on the answer tokens only.
- **Distributed:** plain PyTorch DDP via `torchrun`. `finetune.sbatch` starts one `torchrun` per node with `--nproc_per_node` = GPUs per node, and the first node hosts the c10d rendezvous. Nothing is Soperator-specific, so the script runs on any Slurm cluster.
- **Cost report:** rank 0 writes `training-report.json`: steps, final loss, wall time, trained tokens (counted exactly in the data collator and summed across ranks), tokens/s, GPU-hours, and **$ per 1M trained tokens**, the training counterpart of the inference benchmark's $ per 1M output tokens.

## Run it locally (CPU, no cloud)

```bash
make train-smoke PYTHON=python3.12
```

Two processes on gloo: an all-reduce check, then 4 training steps on a tiny random Qwen2 model with synthetic data. It proves the distributed path, the data pipeline, the adapter save and the report, not model quality.

## Run it on Soperator

1. **Quota first.** The only blocker today is `compute.instance.count` (2; the cluster needs 6, request 8). Non-GPU vCPUs (16) fit exactly; GPUs, disks and filesystems already fit. Full table: [runbook, *Quota for the Soperator training cluster*](../docs/runbook.md#quota-for-the-soperator-training-cluster).
2. **Stage the recipe** (downloads the pinned recipe, creates nothing):
   ```bash
   make soperator-recipe
   cd training/soperator/recipe/soperator/installations/noveon
   # set slurm_login_ssh_root_public_keys in noveon-l40s.auto.tfvars; fill .envrc
   source .envrc && terraform init && terraform plan
   ```
   `terraform apply` takes about 40 minutes and starts billing for 6 instances and 2 GPUs. `terraform destroy` removes it.
3. **On the login node** (`./login.sh -k ~/.ssh/<key>` from the installation directory):
   ```bash
   git clone https://github.com/asterix004/gpu-inference-platform.git && cd gpu-inference-platform
   training/slurm/setup-venv.sh
   sbatch training/slurm/nccl-check.sbatch          # bus bandwidth between the two L40S nodes
   sbatch training/slurm/finetune.sbatch            # LoRA run; output in ~/runs/<job-id>/
   squeue; tail -f qwen-lora-<job-id>.out
   ```
   Bigger clusters change only the sbatch flags, e.g. `sbatch --nodes=4 --gpus-per-node=8 training/slurm/finetune.sbatch`.

## Serve the result

The adapter is a few tens of MB. vLLM loads it next to the base model, so serving a fine-tune does not need a new deployment of the weights:

```bash
vllm serve Qwen/Qwen2.5-1.5B-Instruct --enable-lora --lora-modules noveon-sft=/path/to/runs/<job-id>
```

In this repo that means copying the adapter from the jail to object storage and adding those flags through `extraArgs` in `charts/vllm/values.yaml`. Automating that hand-off is the next step after the first GPU run.
