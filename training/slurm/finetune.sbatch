#!/usr/bin/env bash
# Multi-node LoRA fine-tune of the served model. One torchrun per node, all GPUs per node.
#   sbatch training/slurm/finetune.sbatch                                  # 2 x L40S nodes
#   sbatch --nodes=4 --gpus-per-node=8 --export=ALL,GPU_HOURLY_USD=... training/slurm/finetune.sbatch
# Output lands on the shared jail: $OUTPUT_ROOT/<job-id>/ (adapter + training-report.json).
#SBATCH --job-name=qwen-lora
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --time=02:00:00
#SBATCH --output=%x-%j.out
set -euo pipefail

VENV="${VENV:-$HOME/.venvs/train}"
REPO_ROOT="${REPO_ROOT:-$SLURM_SUBMIT_DIR}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$HOME/runs}"
GPU_HOURLY_USD="${GPU_HOURLY_USD:-1.55}"   # per node; Nebius L40S node on-demand, 2026-10
GPUS_PER_NODE="${SLURM_GPUS_PER_NODE:-1}"
GPUS_PER_NODE="${GPUS_PER_NODE##*:}"
MASTER_ADDR="$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n1)"
OUT="$OUTPUT_ROOT/$SLURM_JOB_ID"
mkdir -p "$OUT"

export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"   # shared jail: weights download once

echo "nodes=$SLURM_JOB_NODELIST gpus_per_node=$GPUS_PER_NODE out=$OUT"
srun --kill-on-bad-exit=1 "$VENV/bin/torchrun" \
  --nnodes "$SLURM_NNODES" --nproc_per_node "$GPUS_PER_NODE" \
  --rdzv_id "$SLURM_JOB_ID" --rdzv_backend c10d --rdzv_endpoint "$MASTER_ADDR:29500" \
  "$REPO_ROOT/training/finetune.py" \
    --output-dir "$OUT" \
    --gpu-hourly-usd "$GPU_HOURLY_USD" --gpus-per-node "$GPUS_PER_NODE" \
    --label "soperator ${SLURM_NNODES}x${GPUS_PER_NODE} job $SLURM_JOB_ID" \
    "$@"
