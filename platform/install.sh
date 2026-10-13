#!/usr/bin/env bash
# Installs the cloud-agnostic platform layer on the current kubectl context:
#   1. kube-prometheus-stack (Prometheus + Grafana) on the system pool
#   2. NVIDIA GPU Operator (Nebius only; GKE manages drivers and DCGM itself)
#   3. Grafana dashboards from ./dashboards
#
# Usage: CLOUD=nebius|gke platform/install.sh
set -euo pipefail

CLOUD="${CLOUD:-nebius}"
KPS_VERSION="${KPS_VERSION:-92.3.0}"
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v26.7.1}"
GPU_OPERATOR_MANAGES_DRIVER="${GPU_OPERATOR_MANAGES_DRIVER:-false}"
MON_NS=monitoring
GPU_NS=gpu-operator

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { printf '\n==> %s\n' "$*"; }

for bin in kubectl helm; do
  command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }
done

log "Context: $(kubectl config current-context)"
kubectl get nodes -L noveon.io/pool

# Keep platform components off the GPU node when a system pool exists.
# If the system pool is scaled to 0 (vCPU quota pending), everything shares the GPU node.
if [[ -n "$(kubectl get nodes -l noveon.io/pool=system -o name)" ]]; then
  log "System pool found: pinning platform components to noveon.io/pool=system"
  cat >"$TMP/system-pool.yaml" <<'EOF'
prometheusOperator:
  nodeSelector: { noveon.io/pool: system }
  admissionWebhooks:
    patch:
      nodeSelector: { noveon.io/pool: system }
prometheus:
  prometheusSpec:
    nodeSelector: { noveon.io/pool: system }
grafana:
  nodeSelector: { noveon.io/pool: system }
kube-state-metrics:
  nodeSelector: { noveon.io/pool: system }
EOF
  cat >"$TMP/gpu-operator-system-pool.yaml" <<'EOF'
operator:
  nodeSelector: { noveon.io/pool: system }
node-feature-discovery:
  master:
    nodeSelector: { noveon.io/pool: system }
  gc:
    nodeSelector: { noveon.io/pool: system }
EOF
else
  log "No system pool: platform components will share the GPU node"
  : >"$TMP/system-pool.yaml"
  : >"$TMP/gpu-operator-system-pool.yaml"
fi

log "Installing kube-prometheus-stack $KPS_VERSION"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null
helm repo update >/dev/null

helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --version "$KPS_VERSION" \
  --namespace "$MON_NS" --create-namespace \
  -f "$ROOT/platform/values/kube-prometheus-stack.yaml" \
  -f "$TMP/system-pool.yaml" \
  --wait --timeout 15m

if [[ "$CLOUD" == "nebius" ]]; then
  log "Installing NVIDIA GPU Operator $GPU_OPERATOR_VERSION (manages driver: $GPU_OPERATOR_MANAGES_DRIVER)"
  # Nebius labels GPU nodes gpu.deploy.operands=false (it runs its own device plugin),
  # which stops the operator from deploying anything there, DCGM exporter included.
  # Opt the GPU nodes back in; the operator's own device plugin stays disabled.
  # Nodes added later (autoscaling) need the same label: re-run this script or label them.
  kubectl label nodes -l noveon.io/pool=gpu nvidia.com/gpu.deploy.operands=true --overwrite
  kubectl create namespace "$GPU_NS" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$GPU_NS" create configmap dcgm-metrics-nebius \
    --from-file=dcgm-metrics.csv="$ROOT/platform/values/dcgm-metrics-nebius.csv" \
    --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install gpu-operator nvidia/gpu-operator \
    --version "$GPU_OPERATOR_VERSION" \
    --namespace "$GPU_NS" --create-namespace \
    -f "$ROOT/platform/values/gpu-operator-nebius.yaml" \
    -f "$TMP/gpu-operator-system-pool.yaml" \
    --set driver.enabled="$GPU_OPERATOR_MANAGES_DRIVER" \
    --set toolkit.enabled="$GPU_OPERATOR_MANAGES_DRIVER" \
    --wait --timeout 20m
else
  log "GKE: drivers, device plugin and DCGM metrics are managed by GKE; skipping GPU Operator"
  log "GKE: scraping the managed DCGM exporter into in-cluster Prometheus"
  kubectl apply -f "$ROOT/platform/gke-dcgm-podmonitor.yaml"
fi

log "Loading Grafana dashboards"
for f in "$ROOT"/dashboards/*.json; do
  name="dash-$(basename "$f" .json)"
  kubectl -n "$MON_NS" create configmap "$name" --from-file="$(basename "$f")=$f" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$MON_NS" label configmap "$name" grafana_dashboard=1 --overwrite >/dev/null
done

log "Waiting for the GPU to be schedulable (nvidia.com/gpu allocatable)"
for _ in $(seq 1 60); do
  gpus="$(kubectl get nodes -l noveon.io/pool=gpu \
    -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
  if [[ -n "${gpus// /}" && "$gpus" != "0" ]]; then
    echo "GPU allocatable: $gpus"
    break
  fi
  sleep 10
done
[[ -n "${gpus// /}" && "$gpus" != "0" ]] || {
  echo "GPU not allocatable after 10 minutes. Check: kubectl -n $GPU_NS get pods"
  exit 1
}

log "Platform ready. Grafana: make grafana  (user: admin)"
