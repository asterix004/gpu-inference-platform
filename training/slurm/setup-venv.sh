#!/usr/bin/env bash
# One-time setup on a Soperator login node. The jail is a shared root filesystem, so a venv
# created here is visible on every worker; nothing has to be installed per node.
#
#   git clone https://github.com/asterix004/gpu-inference-platform.git && cd gpu-inference-platform
#   training/slurm/setup-venv.sh
set -euo pipefail

VENV="${VENV:-$HOME/.venvs/train}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$REPO_ROOT/training/requirements.txt"
"$VENV/bin/python" -c 'import torch; print("torch", torch.__version__, "cuda", torch.version.cuda)'
echo "venv ready: $VENV"
