#!/usr/bin/env bash
# Pre-flight: all-reduce bandwidth across every GPU the training job will use.
#   sbatch training/slurm/nccl-check.sbatch            # 2 nodes x 1 GPU (L40S)
#   sbatch --nodes=2 --gpus-per-node=8 training/slurm/nccl-check.sbatch
#SBATCH --job-name=nccl-check
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --time=00:10:00
#SBATCH --output=%x-%j.out
set -euo pipefail

VENV="${VENV:-$HOME/.venvs/train}"
REPO_ROOT="${REPO_ROOT:-$SLURM_SUBMIT_DIR}"
GPUS_PER_NODE="${SLURM_GPUS_PER_NODE:-1}"
GPUS_PER_NODE="${GPUS_PER_NODE##*:}"   # "l40s:1" -> "1"
MASTER_ADDR="$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n1)"
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"

srun --kill-on-bad-exit=1 "$VENV/bin/torchrun" \
  --nnodes "$SLURM_NNODES" --nproc_per_node "$GPUS_PER_NODE" \
  --rdzv_id "$SLURM_JOB_ID" --rdzv_backend c10d --rdzv_endpoint "$MASTER_ADDR:29500" \
  "$REPO_ROOT/training/nccl_check.py"
