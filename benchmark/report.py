#!/usr/bin/env python3
"""Render benchmark JSON files (from `make bench`) as a Markdown comparison table.

Usage: python benchmark/report.py results/*.json > results/SUMMARY.md
Standard library only, so it runs on any laptop.
"""
import json
import sys


def main(paths: list[str]) -> None:
    runs = []
    for path in paths:
        with open(path) as fh:
            runs.append(json.load(fh))
    if not runs:
        sys.exit("no result files given")

    print("## Peak throughput and cost\n")
    print("| Run | Model | Peak output tok/s | At concurrency | $/GPU-hour | $ per 1M output tokens |")
    print("|---|---|---:|---:|---:|---:|")
    for r in runs:
        cost = r.get("best_usd_per_1m_output_tokens")
        print(
            f"| {r['label'] or r['timestamp_utc']} | {r['model']} | {r['peak_output_tok_per_s']:.0f} "
            f"| {r['peak_at_concurrency']} | {r['gpu_hourly_usd']:.2f} | {cost if cost is not None else 'n/a'} |"
        )

    for r in runs:
        print(f"\n### {r['label'] or r['timestamp_utc']}\n")
        print(f"Input ~{r['input_tokens']} tokens, output {r['output_tokens']} tokens per request.\n")
        print("| Concurrency | OK/Total | Output tok/s | TTFT p50 (ms) | TTFT p95 (ms) | E2E p95 (s) | $ / 1M out |")
        print("|---:|---:|---:|---:|---:|---:|---:|")
        for lv in r["levels"]:
            print(
                f"| {lv['concurrency']} | {lv['succeeded']}/{lv['requests']} | {lv['output_tok_per_s']:.0f} "
                f"| {lv['ttft_p50_ms']:.0f} | {lv['ttft_p95_ms']:.0f} | {lv['latency_p95_s']:.2f} "
                f"| {lv['usd_per_1m_output_tokens'] if lv['usd_per_1m_output_tokens'] is not None else 'n/a'} |"
            )


if __name__ == "__main__":
    main(sys.argv[1:])
