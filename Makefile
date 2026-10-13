# GPU inference platform: provision -> platform -> deploy -> benchmark -> tear down.
# CLOUD=nebius (default) or CLOUD=gke selects the Terraform module under infra/.

CLOUD          ?= nebius
TF             := terraform -chdir=infra/$(CLOUD)
NS             := inference
GPU_HOURLY_USD ?=
LABEL          ?= $(CLOUD)
TF_EXTRA       ?=
HELM_EXTRA     ?=
KEDA_VERSION   ?= 2.20.2
LOAD_MINUTES   ?= 25
LOAD_CONCURRENCY ?= 96
LOAD_SECONDS   = $(shell echo $$(( $(LOAD_MINUTES) * 60 )))

ifeq ($(CLOUD),nebius)
PROJECT_ID ?= $(shell nebius config list 2>/dev/null | awk '/^parent-id:/{print $$2}')
SUBNET_ID  ?= $(shell nebius vpc subnet list --parent-id $(PROJECT_ID) --format json 2>/dev/null | jq -r '.items[0].metadata.id')
TF_VARS    := -var project_id=$(PROJECT_ID) -var subnet_id=$(SUBNET_ID) $(TF_EXTRA)
else
TF_VARS    := $(TF_EXTRA)
endif

.PHONY: help env init plan up kubeconfig platform deploy bench report grafana gpu-off gpu-on down leftovers keda load

help: ## Show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

env: ## Show the project/subnet Terraform will use
	@echo "CLOUD=$(CLOUD)"
	@echo "PROJECT_ID=$(PROJECT_ID)"
	@echo "SUBNET_ID=$(SUBNET_ID)"

init: ## terraform init
	$(TF) init

plan: ## terraform plan
	$(TF) plan $(TF_VARS)

up: ## Create cluster + node groups (prompts for approval)
	$(TF) apply $(TF_VARS)

kubeconfig: ## Point kubectl at the new cluster
ifeq ($(CLOUD),nebius)
	nebius mk8s cluster get-credentials --id $$($(TF) output -raw cluster_id) --external --force
else
	gcloud container clusters get-credentials $$($(TF) output -raw cluster_name) --zone $$($(TF) output -raw zone)
endif
	kubectl get nodes -L noveon.io/pool

platform: ## Install Prometheus/Grafana, GPU Operator, dashboards
	CLOUD=$(CLOUD) ./platform/install.sh

deploy: ## Deploy vLLM (first start downloads the model; allow ~10 min)
	helm upgrade --install vllm charts/vllm --namespace $(NS) --create-namespace $(HELM_EXTRA) --wait --timeout 25m
	kubectl -n $(NS) get pods -o wide

bench: ## Run the in-cluster benchmark: make bench GPU_HOURLY_USD=<price> LABEL="nebius L40S"
	@test -n "$(GPU_HOURLY_USD)" || (echo "Set GPU_HOURLY_USD to the node's on-demand hourly price"; exit 1)
	@mkdir -p results
	kubectl -n $(NS) create configmap bench-script --from-file=benchmark/bench.py --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n $(NS) delete job vllm-bench --ignore-not-found
	sed -e 's|__GPU_HOURLY_USD__|$(GPU_HOURLY_USD)|' -e 's|__LABEL__|$(LABEL)|' -e 's|__EXTRA_ARGS__||' benchmark/job.yaml | kubectl -n $(NS) apply -f -
	kubectl -n $(NS) wait --for=condition=complete job/vllm-bench --timeout=45m
	@out=results/$$(echo "$(LABEL)" | tr ' A-Z' '-a-z')-$$(date -u +%Y%m%dT%H%M%SZ).json; \
	  kubectl -n $(NS) logs job/vllm-bench | sed -n '/=====RESULT-BEGIN=====/,/=====RESULT-END=====/p' | sed '1d;$$d' > $$out; \
	  echo "Saved $$out"
	$(MAKE) report

keda: ## Install KEDA (for the vLLM autoscaling test)
	helm repo add kedacore https://kedacore.github.io/charts >/dev/null
	helm repo update kedacore >/dev/null
	helm upgrade --install keda kedacore/keda --version $(KEDA_VERSION) --namespace keda --create-namespace --wait --timeout 10m

load: ## Hold LOAD_CONCURRENCY requests for LOAD_MINUTES (autoscaling test): make load LABEL="nebius keda"
	@mkdir -p results/autoscaling
	kubectl -n $(NS) create configmap bench-script --from-file=benchmark/bench.py --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n $(NS) delete job vllm-bench --ignore-not-found
	sed -e 's|__GPU_HOURLY_USD__|0|' -e 's|__LABEL__|$(LABEL)|' \
	  -e 's|__EXTRA_ARGS__|--concurrency $(LOAD_CONCURRENCY) --duration-s $(LOAD_SECONDS)|' \
	  benchmark/job.yaml | kubectl -n $(NS) apply -f -
	kubectl -n $(NS) wait --for=condition=complete job/vllm-bench --timeout=$$(( $(LOAD_MINUTES) + 15 ))m
	@out=results/autoscaling/$$(echo "$(LABEL)" | tr ' A-Z' '-a-z')-$$(date -u +%Y%m%dT%H%M%SZ).json; \
	  kubectl -n $(NS) logs job/vllm-bench | sed -n '/=====RESULT-BEGIN=====/,/=====RESULT-END=====/p' | sed '1d;$$d' > $$out; \
	  echo "Saved $$out"

report: ## Rebuild results/SUMMARY.md from all result files
	python3 benchmark/report.py results/*.json > results/SUMMARY.md
	@cat results/SUMMARY.md

grafana: ## Port-forward Grafana to http://localhost:3000
	@echo "user: admin  password: $$(kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 --decode)"
	kubectl -n monitoring port-forward svc/kps-grafana 3000:80

gpu-off: ## Scale the GPU pool to 0 (keeps the cluster; stops GPU billing)
	$(TF) apply $(TF_VARS) -var gpu_node_count=0

gpu-on: ## Scale the GPU pool back to 1
	$(TF) apply $(TF_VARS) -var gpu_node_count=1

down: ## Destroy everything Terraform created (prompts for approval)
	$(TF) destroy $(TF_VARS)
	$(MAKE) leftovers

leftovers: ## List anything still billable in the project
ifeq ($(CLOUD),nebius)
	@echo "Instances:";  nebius compute instance list --parent-id $(PROJECT_ID) --format json | jq -r '.items[]?.metadata.name' || true
	@echo "Disks:";      nebius compute disk list --parent-id $(PROJECT_ID) --format json | jq -r '.items[]?.metadata.name' || true
	@echo "Clusters:";   nebius mk8s cluster list --parent-id $(PROJECT_ID) --format json | jq -r '.items[]?.metadata.name' || true
else
	gcloud container clusters list
	gcloud compute disks list
endif
