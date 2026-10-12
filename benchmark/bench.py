#!/usr/bin/env python3
"""Concurrency sweep against an OpenAI-compatible endpoint (vLLM).

For each concurrency level it sends a fixed number of streaming chat requests
with a fixed output length and reports:
  - output tokens/sec (aggregate throughput)
  - time to first token (TTFT) p50/p95
  - end-to-end latency p50/p95
  - cost per 1M output tokens at the supplied GPU hourly price

Runs in-cluster (benchmark/job.yaml) so network latency to the laptop does not
distort TTFT. Prints one JSON document between RESULT markers for `make bench`.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from dataclasses import dataclass

import httpx

RESULT_BEGIN = "=====RESULT-BEGIN====="
RESULT_END = "=====RESULT-END====="


@dataclass
class RequestResult:
    ok: bool
    ttft_s: float
    latency_s: float
    output_tokens: int
    error: str = ""


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    k = (len(ordered) - 1) * pct / 100
    lo, hi = int(k), min(int(k) + 1, len(ordered) - 1)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (k - lo)


def make_prompt(approx_tokens: int, seed: int) -> str:
    # ~0.75 words per token for English; vary the text so prefix caching does
    # not make every request after the first artificially cheap.
    words = max(8, int(approx_tokens * 0.75))
    base = f"Request {seed}. Summarise the trade-offs of running inference on GPUs in the cloud. "
    filler = " ".join(f"context{seed}_{i}" for i in range(words))
    return base + filler


async def one_request(client: httpx.AsyncClient, args, seed: int) -> RequestResult:
    payload = {
        "model": args.model,
        "messages": [{"role": "user", "content": make_prompt(args.input_tokens, seed)}],
        "max_tokens": args.output_tokens,
        "temperature": 0.0,
        "stream": True,
        "stream_options": {"include_usage": True},
        # vLLM extension: generate exactly max_tokens so every run does equal work.
        "ignore_eos": True,
    }
    start = time.perf_counter()
    ttft = None
    output_tokens = 0
    try:
        async with client.stream("POST", f"{args.base_url}/v1/chat/completions", json=payload) as resp:
            if resp.status_code != 200:
                body = await resp.aread()
                return RequestResult(False, 0, 0, 0, f"HTTP {resp.status_code}: {body[:200]!r}")
            async for line in resp.aiter_lines():
                if not line.startswith("data: "):
                    continue
                data = line[6:]
                if data.strip() == "[DONE]":
                    break
                chunk = json.loads(data)
                if ttft is None and chunk.get("choices") and chunk["choices"][0].get("delta", {}).get("content"):
                    ttft = time.perf_counter() - start
                usage = chunk.get("usage")
                if usage:
                    output_tokens = usage.get("completion_tokens", output_tokens)
    except (TimeoutError, httpx.HTTPError, json.JSONDecodeError) as exc:
        return RequestResult(False, 0, 0, 0, repr(exc))
    latency = time.perf_counter() - start
    return RequestResult(True, ttft if ttft is not None else latency, latency, output_tokens)


async def run_level(args, concurrency: int) -> dict:
    total = max(concurrency * args.requests_per_slot, args.min_requests)
    sem = asyncio.Semaphore(concurrency)
    limits = httpx.Limits(max_connections=concurrency, max_keepalive_connections=concurrency)
    async with httpx.AsyncClient(timeout=httpx.Timeout(args.timeout), limits=limits) as client:

        async def bounded(i: int) -> RequestResult:
            async with sem:
                return await one_request(client, args, seed=concurrency * 100000 + i)

        wall_start = time.perf_counter()
        results = await asyncio.gather(*(bounded(i) for i in range(total)))
        wall = time.perf_counter() - wall_start

    ok = [r for r in results if r.ok]
    errors = [r.error for r in results if not r.ok]
    out_tokens = sum(r.output_tokens for r in ok)
    tok_per_s = out_tokens / wall if wall > 0 else 0.0
    cost_per_m = (args.gpu_hourly_usd / (tok_per_s * 3600) * 1e6) if tok_per_s > 0 and args.gpu_hourly_usd else None
    level = {
        "concurrency": concurrency,
        "requests": total,
        "succeeded": len(ok),
        "failed": len(errors),
        "wall_s": round(wall, 2),
        "output_tokens": out_tokens,
        "output_tok_per_s": round(tok_per_s, 1),
        "ttft_p50_ms": round(percentile([r.ttft_s for r in ok], 50) * 1000, 1),
        "ttft_p95_ms": round(percentile([r.ttft_s for r in ok], 95) * 1000, 1),
        "latency_p50_s": round(percentile([r.latency_s for r in ok], 50), 2),
        "latency_p95_s": round(percentile([r.latency_s for r in ok], 95), 2),
        "usd_per_1m_output_tokens": round(cost_per_m, 4) if cost_per_m is not None else None,
        "sample_errors": errors[:3],
    }
    print(
        f"c={concurrency:>4}  ok={len(ok):>4}/{total:<4}  {tok_per_s:8.1f} tok/s  "
        f"TTFT p50={level['ttft_p50_ms']:7.1f} ms p95={level['ttft_p95_ms']:7.1f} ms  "
        f"E2E p95={level['latency_p95_s']:6.2f} s",
        flush=True,
    )
    return level


async def wait_ready(args) -> None:
    async with httpx.AsyncClient(timeout=5) as client:
        for _ in range(120):
            try:
                if (await client.get(f"{args.base_url}/health")).status_code == 200:
                    return
            except httpx.HTTPError:
                pass
            await asyncio.sleep(5)
    sys.exit(f"{args.base_url} not healthy after 10 minutes")


async def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base-url", default="http://vllm:8000")
    p.add_argument("--model", default="qwen2.5-1.5b")
    p.add_argument("--concurrency", default="1,4,16,32,64", help="comma-separated levels")
    p.add_argument("--input-tokens", type=int, default=512)
    p.add_argument("--output-tokens", type=int, default=256)
    p.add_argument("--requests-per-slot", type=int, default=4, help="requests per concurrency slot")
    p.add_argument("--min-requests", type=int, default=16)
    p.add_argument("--timeout", type=float, default=300)
    p.add_argument("--warmup", type=int, default=4)
    p.add_argument("--gpu-hourly-usd", type=float, default=0.0, help="on-demand price of the GPU node")
    p.add_argument("--label", default="", help="free text, e.g. 'nebius L40S eu-north1'")
    args = p.parse_args()

    await wait_ready(args)
    print(f"Warm-up: {args.warmup} requests", flush=True)
    async with httpx.AsyncClient(timeout=httpx.Timeout(args.timeout)) as client:
        await asyncio.gather(*(one_request(client, args, seed=-i - 1) for i in range(args.warmup)))

    levels = [await run_level(args, int(c)) for c in args.concurrency.split(",")]
    best = max(levels, key=lambda lv: lv["output_tok_per_s"])
    report = {
        "label": args.label,
        "model": args.model,
        "input_tokens": args.input_tokens,
        "output_tokens": args.output_tokens,
        "gpu_hourly_usd": args.gpu_hourly_usd,
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "peak_output_tok_per_s": best["output_tok_per_s"],
        "peak_at_concurrency": best["concurrency"],
        "best_usd_per_1m_output_tokens": best["usd_per_1m_output_tokens"],
        "levels": levels,
    }
    print(RESULT_BEGIN)
    print(json.dumps(report, indent=2))
    print(RESULT_END, flush=True)


if __name__ == "__main__":
    asyncio.run(main())
