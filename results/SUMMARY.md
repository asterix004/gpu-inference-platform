## Peak throughput and cost

| Run | Model | Peak output tok/s | At concurrency | $/GPU-hour | $ per 1M output tokens |
|---|---|---:|---:|---:|---:|
| gke L4 us-central1 | qwen2.5-1.5b | 2181 | 64 | 0.85 | 0.1087 |
| nebius L40S eu-north1 | qwen2.5-1.5b | 6228 | 64 | 1.55 | 0.0691 |

### gke L4 us-central1

Input ~512 tokens, output 256 tokens per request.

| Concurrency | OK/Total | Output tok/s | TTFT p50 (ms) | TTFT p95 (ms) | E2E p95 (s) | $ / 1M out |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 16/16 | 74 | 51 | 54 | 3.48 | 3.2108 |
| 4 | 16/16 | 276 | 160 | 168 | 3.72 | 0.8591 |
| 16 | 64/64 | 934 | 338 | 564 | 4.47 | 0.2538 |
| 32 | 128/128 | 1493 | 517 | 922 | 5.86 | 0.1588 |
| 64 | 256/256 | 2181 | 675 | 1892 | 8.72 | 0.1087 |

### nebius L40S eu-north1

Input ~512 tokens, output 256 tokens per request.

| Concurrency | OK/Total | Output tok/s | TTFT p50 (ms) | TTFT p95 (ms) | E2E p95 (s) | $ / 1M out |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 16/16 | 188 | 23 | 24 | 1.36 | 2.2856 |
| 4 | 16/16 | 682 | 47 | 55 | 1.51 | 0.6317 |
| 16 | 64/64 | 2529 | 90 | 172 | 1.65 | 0.1702 |
| 32 | 128/128 | 4111 | 190 | 296 | 2.02 | 0.1047 |
| 64 | 256/256 | 6228 | 359 | 586 | 2.72 | 0.0691 |
