# GPU Inference Platform: Nebius AI Cloud ⇄ GKE

A reproducible reference architecture for serving open LLMs on Kubernetes GPUs, with GPU-level observability and a **cost-per-token** benchmark. The same Helm charts, dashboards and benchmark run on **Nebius Managed Kubernetes** and **Google Kubernetes Engine**. Only the Terraform module changes.

It answers the questions a team asks before moving inference to a GPU cloud:

1. How long does it take to stand up a production-shaped GPU cluster, and can it be torn down cleanly?
2. What throughput and latency does one GPU deliver for my model, and at what concurrency does it saturate?
3. **What does a million output tokens cost** on each GPU class and each cloud?

> **Status:** first benchmark run on Nebius (1 x L40S, eu-north1) on 2026-10-12. GKE run pending. Raw results and the full table are in [`results/`](results/).

## Results

Qwen2.5-1.5B-Instruct on vLLM v0.31.0. Each request has a ~512-token prompt and generates exactly 256 output tokens. Cost uses the Nebius on-demand L40S price of **$1.55/GPU-hour**.

| Concurrency | Output tok/s | TTFT p50 | TTFT p95 | E2E p95 | $ per 1M output tokens |
|---:|---:|---:|---:|---:|---:|
| 1 | 188 | 23 ms | 24 ms | 1.36 s | $2.29 |
| 4 | 682 | 47 ms | 55 ms | 1.51 s | $0.63 |
| 16 | 2,529 | 90 ms | 172 ms | 1.65 s | $0.17 |
| 32 | 4,111 | 190 ms | 296 ms | 2.02 s | $0.10 |
| 64 | 6,228 | 359 ms | 586 ms | 2.72 s | **$0.069** |

All 480 requests succeeded. Throughput was still climbing at concurrency 64, so the L40S was not saturated by this 1.5B model. Cost per token falls 33x between a single user and 64 concurrent users, which is why batching is the main cost lever for self-hosted inference. The p95 time-to-first-token stays under 600 ms at that load.

Cost covers the GPU node only. The control plane and the 4-vCPU system node are excluded.

### Screenshots

**vLLM serving metrics during the benchmark (Grafana).** The spike at 16:36 is the five concurrency steps run back to back, and latency rises with concurrency. The small bump at 16:30 is the first run, which was rejected (see below).

![Grafana: vLLM token throughput and latency during the benchmark](docs/images/grafana-vllm-benchmark.png)

The same panels over 30 minutes, with the benchmark in context of the idle cluster:

![Grafana: vLLM panels over the last 30 minutes](docs/images/nebius-grafana-gpu-inference-15-min-graph.png)

**Kubernetes API server health (kube-prometheus-stack).** The control plane stayed above 99.9% availability while the platform was installed and the benchmark ran.

![Grafana: Kubernetes API server SLO dashboard](docs/images/nebius-k8s-api-server.png)

**Cluster on Nebius: one CPU system node and one L40S GPU node.**

![Nebius console: gpu-inference node groups](docs/images/nebius-gpu-inference-node-groups.png)

![Nebius console: the two Kubernetes nodes as virtual machines](docs/images/nebius-node-groups.png)

![Nebius console: the L40S node in the GPU node group](docs/images/nebius-nvidia-l40s.png)

![Nebius console: system node group, 4 vCPU AMD Epyc Genoa](docs/images/nebius-gpu-inference-system.png)

**GPU node during startup.** CPU and disk activity at 16:18–16:25 is the ~10 GB vLLM image pull and model load, before the benchmark ran.

![Nebius console: GPU node metrics during image pull and model load](docs/images/nebius-gpu-node-metrics.png)

**Teardown.** `make down` in progress: the system node is already gone and the GPU node is deleting.

![Nebius console: cluster overview during teardown](docs/images/nebius-k8s-gpu-inference-overview.png)

### What the first run taught us

- **Instance quota, not GPU quota, was the binding limit.** The tenant had 8 L40S GPUs but only 2 compute instances, so the system pool runs 1 node instead of 2 (`-var cpu_node_count=1`).
- **The Service name `vllm` breaks vLLM.** Kubernetes injects `VLLM_PORT=tcp://...` for a Service named `vllm`, and vLLM reads it as its own setting and exits. The chart now sets `enableServiceLinks: false`.
- **Synthetic filler tokens are expensive.** Strings like `context12_34` cost ~7 tokens each, so the first prompts were ~3,800 tokens and every request was rejected. The benchmark now uses common English words, measured at 516 tokens with vLLM's `/tokenize` endpoint.
- **DCGM GPU metrics on Nebius are an open issue.** Nebius labels GPU nodes `nvidia.com/gpu.deploy.operands=false` and runs its own device plugin and host-side GPU profiling. The operator's DCGM exporter conflicts with that profiling ("third-party Profiling module returned an unrecoverable error"). The fix is a custom counters file without profiling fields (1001–1012), which is not done yet. GPU utilisation for this run is visible in the Nebius console instead.

---

## Architecture

```mermaid
flowchart LR
  subgraph TF["Terraform (infra/nebius or infra/gke)"]
    CP[Managed K8s control plane]
    SYS["System pool<br/>noveon.io/pool=system"]
    GPU["GPU pool<br/>noveon.io/pool=gpu<br/>1 x L40S / H100 / L4"]
  end
  subgraph PLAT["platform/install.sh (cloud-agnostic)"]
    KPS["kube-prometheus-stack<br/>Prometheus + Grafana"]
    GO["NVIDIA GPU Operator<br/>device plugin · GFD · DCGM exporter"]
  end
  subgraph APP["charts/vllm"]
    V["vLLM OpenAI server<br/>Qwen2.5-1.5B-Instruct"]
  end
  B["benchmark/ Job<br/>concurrency sweep"] -->|HTTP /v1/chat/completions| V
  KPS -->|scrape /metrics| V
  KPS -->|scrape| GO
  SYS --- KPS
  GPU --- V
  GPU --- GO
  B -->|tok/s · TTFT · $/1M tokens| R[(results/*.json)]
```

| Layer | Nebius | GKE |
|---|---|---|
| Cluster | `nebius_mk8s_v1_cluster`, public API endpoint | Zonal `google_container_cluster`, Workload Identity |
| System pool | 2 × `cpu-d3` `4vcpu-16gb` | 1 × `e2-standard-4` |
| GPU pool | 1 × `gpu-l40s-a` `1gpu-8vcpu-32gb` (driver-included image) | 1 × `g2-standard-8` (L4, GKE-managed driver) |
| GPU metrics | GPU Operator DCGM exporter → Prometheus | GKE managed DCGM → Managed Prometheus |
| Serving | `charts/vllm` (identical) | `charts/vllm` (identical) |

Design decisions are recorded in [`docs/adr/`](docs/adr/).

## Repository layout

```
infra/nebius/        Terraform: Managed Kubernetes, system + GPU node groups
infra/gke/           Terraform: the same shape on GKE
platform/            install.sh + Helm values (Prometheus/Grafana, GPU Operator)
charts/vllm/         Helm chart: vLLM server, Service, ServiceMonitor
benchmark/           bench.py (async load generator), job.yaml, report.py
dashboards/          Grafana dashboard: vLLM serving + DCGM GPU panels
docs/                ADRs and runbook
results/             Benchmark outputs and SUMMARY.md
```

## Quick start (Nebius)

Prerequisites: Nebius CLI with an authenticated profile (`nebius profile create`), Terraform ≥ 1.6, `kubectl`, `helm`, `jq`. Quotas in the target region: ≥ 1 GPU of the chosen type, ≥ 8 non-GPU vCPUs, ≥ 4 disks.

```bash
make env                 # shows the project and subnet Terraform will use
make init
make plan
make up                  # ~10-15 min: control plane + node groups
make kubeconfig
make platform            # Prometheus/Grafana, GPU Operator, dashboards
make deploy              # vLLM; first start downloads the model
make bench GPU_HOURLY_USD=<on-demand price> LABEL="nebius L40S eu-north1"
make grafana             # http://localhost:3000, dashboard "GPU Inference"
make down                # destroy, then list anything still billable
```

Between sessions, `make gpu-off` scales the GPU pool to zero and keeps the cluster. `make down` removes everything.

**GKE:** the same flow with `CLOUD=gke` after copying `infra/gke/terraform.tfvars.example` to `terraform.tfvars`.

## What the benchmark measures

`benchmark/bench.py` runs **inside the cluster**, so laptop-to-region latency does not distort time-to-first-token. For each concurrency level (default 1, 4, 16, 32, 64) it sends streaming chat requests with ~512 input tokens and exactly 256 output tokens (`ignore_eos`), then records:

- aggregate **output tokens/sec**
- **TTFT** and **end-to-end latency** at p50 and p95
- **$ per 1M output tokens** = GPU hourly price ÷ (tokens/sec × 3600) × 1,000,000

Prompts differ per request so vLLM's prefix cache cannot make later requests artificially cheap. `make report` turns every run into a comparison table in `results/SUMMARY.md`.

## Cost controls

- One GPU node; system components are pinned to cheap CPU nodes.
- `make gpu-off` / `make down`; `make leftovers` lists any instance, disk or cluster still in the project.
- A tenant-wide budget with 25/50/75/100% alerts is set in the Nebius console before any `apply`.

## Not in scope (yet)

Multi-node training, InfiniBand, autoscaling on queue depth (KEDA or Prometheus Adapter), a private API endpoint behind a bastion, and remote Terraform state. Each is listed in [`docs/runbook.md`](docs/runbook.md) as a next step, with the reason it was deferred.
