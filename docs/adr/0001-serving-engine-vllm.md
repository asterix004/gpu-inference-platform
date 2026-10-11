# ADR 0001: vLLM as the serving engine

**Status:** accepted

## Context
The platform needs an inference server that runs open-weight models on a single GPU, exposes an OpenAI-compatible API (so clients and the benchmark need no custom SDK), and publishes Prometheus metrics for throughput, queueing and latency.

## Options
| Option | For | Against |
|---|---|---|
| **vLLM** | Continuous batching and paged KV cache give high throughput per GPU; OpenAI-compatible; native `/metrics`; runs any Hugging Face model directly | Python stack; each release pins specific CUDA/PyTorch versions |
| TensorRT-LLM + Triton | Highest peak throughput on NVIDIA GPUs | Per-model engine build step and per-GPU-type tuning; far slower to iterate |
| Hugging Face TGI | Simple, OpenAI-compatible | Smaller community momentum; fewer tuning knobs exposed |

## Decision
vLLM, pinned to `v0.31.0` in `charts/vllm/values.yaml`.

## Consequences
- Benchmarks are comparable across GPU types and clouds without rebuilding engines.
- For a customer at fixed model and GPU with very high volume, TensorRT-LLM is the natural next comparison; the benchmark harness already works against any OpenAI-compatible endpoint.
