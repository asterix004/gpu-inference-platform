# ADR 0003: Demo sizing — two node pools, ephemeral storage, local state

**Status:** accepted for the reference build; revisit for production

## Decisions and trade-offs

| Area | Choice here | Production choice |
|---|---|---|
| Node pools | Separate system (CPU) and GPU pools; monitoring pinned to the system pool | Same, plus a taint on GPU nodes so nothing lands there by accident |
| Control plane | etcd size 1, public API endpoint | etcd size 3, private endpoint behind a bastion or VPN |
| Prometheus storage | `emptyDir`, 2-day retention | PVC or remote write to a managed TSDB |
| Model weights | Downloaded to `emptyDir` on every pod start | Shared filesystem or object storage cache so cold start drops from minutes to seconds |
| Terraform state | Local, git-ignored | Remote state in Nebius Object Storage (S3-compatible backend) |
| Grafana | No persistence; dashboards provisioned from Git | Same, dashboards stay as code |

## Why
The cluster is created and destroyed in the same working session to keep GPU spend to a few hours. Every persistent component would add disks against a small default quota and outlive the cluster's usefulness. Everything that matters (dashboards, values, results) lives in Git.
