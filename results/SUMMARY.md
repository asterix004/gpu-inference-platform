## Peak throughput and cost

| Run | Model | Peak output tok/s | At concurrency | $/GPU-hour | $ per 1M output tokens |
|---|---|---:|---:|---:|---:|
| nebius L40S eu-north1 | qwen2.5-1.5b | 6228 | 64 | 1.55 | 0.0691 |

### nebius L40S eu-north1

Input ~512 tokens, output 256 tokens per request.

| Concurrency | OK/Total | Output tok/s | TTFT p50 (ms) | TTFT p95 (ms) | E2E p95 (s) | $ / 1M out |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 16/16 | 188 | 23 | 24 | 1.36 | 2.2856 |
| 4 | 16/16 | 682 | 47 | 55 | 1.51 | 0.6317 |
| 16 | 64/64 | 2529 | 90 | 172 | 1.65 | 0.1702 |
| 32 | 128/128 | 4111 | 190 | 296 | 2.02 | 0.1047 |
| 64 | 256/256 | 6228 | 359 | 586 | 2.72 | 0.0691 |
