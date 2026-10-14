#!/usr/bin/env python3
"""All-reduce bandwidth check across every GPU in the job.

Run it before a multi-node training job: a slow or broken interconnect shows up here in
seconds instead of as a training run that is mysteriously 5x slower. Reports algorithm
and bus bandwidth the same way nccl-tests does (busbw = algbw * 2(n-1)/n).

  srun ... torchrun ... training/nccl_check.py          # on Slurm: slurm/nccl-check.sbatch
  torchrun --nproc_per_node 2 training/nccl_check.py --cpu   # local gloo smoke test
"""

from __future__ import annotations

import argparse
import os
import time

import torch
import torch.distributed as dist


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--sizes-mb", default="1,16,128,512,1024")
    p.add_argument("--iters", type=int, default=20)
    p.add_argument("--warmup", type=int, default=5)
    p.add_argument("--cpu", action="store_true", help="gloo on CPU, for smoke tests")
    args = p.parse_args()

    backend = "gloo" if args.cpu else "nccl"
    dist.init_process_group(backend=backend)
    rank, world = dist.get_rank(), dist.get_world_size()
    if args.cpu:
        device = torch.device("cpu")
    else:
        local = int(os.environ.get("LOCAL_RANK", "0"))
        torch.cuda.set_device(local)
        device = torch.device("cuda", local)

    if rank == 0:
        print(f"backend={backend} world_size={world} nodes={os.environ.get('SLURM_NNODES', '1')}")
        print(f"{'size':>10} {'time_ms':>10} {'algbw_GB/s':>12} {'busbw_GB/s':>12}")

    for mb in (int(s) for s in args.sizes_mb.split(",")):
        n = mb * 1024 * 1024 // 4
        t = torch.ones(n, dtype=torch.float32, device=device)
        for _ in range(args.warmup):
            dist.all_reduce(t)
        if not args.cpu:
            torch.cuda.synchronize()
        start = time.perf_counter()
        for _ in range(args.iters):
            dist.all_reduce(t)
        if not args.cpu:
            torch.cuda.synchronize()
        elapsed = (time.perf_counter() - start) / args.iters
        algbw = (n * 4) / elapsed / 1e9
        busbw = algbw * 2 * (world - 1) / world if world > 1 else algbw
        if rank == 0:
            print(f"{mb:>8}MB {elapsed * 1e3:>10.2f} {algbw:>12.2f} {busbw:>12.2f}")

    dist.destroy_process_group()


if __name__ == "__main__":
    main()
