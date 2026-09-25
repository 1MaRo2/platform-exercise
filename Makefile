IMAGE   ?= platform-exercise
VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
PORT    ?= 8080
TF_DIR  := infra

.DEFAULT_GOAL := help
.PHONY: help test lint build run smoke scan scan-image scan-fs scan-iac tf-fmt tf-validate tf-plan kind-test clean

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

test: ## Run unit tests with race detector
	cd app && go test -race -cover ./...

lint: ## gofmt, go vet, hadolint
	cd app && test -z "$$(gofmt -l .)" && go vet ./...
	hadolint Dockerfile

build: ## Build the container image
	docker build --build-arg VERSION=$(VERSION) -t $(IMAGE):$(VERSION) .
	@docker image ls $(IMAGE):$(VERSION) --format 'image size: {{.Size}}'

run: build ## Run the container locally on $(PORT)
	docker run --rm -p $(PORT):8080 --read-only --cap-drop ALL $(IMAGE):$(VERSION)

smoke: ## Curl /health on a running instance
	curl -fsS http://localhost:$(PORT)/health && echo

scan: scan-fs scan-image scan-iac ## Run all Trivy scans

scan-fs: ## Dependency (SCA) + secret scan of the repo
	trivy fs --scanners vuln,secret --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 .

scan-image: build ## Vulnerability scan of the built image
	trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 $(IMAGE):$(VERSION)

scan-iac: ## Misconfiguration scan of Terraform and k8s manifests
	trivy config --severity HIGH,CRITICAL --exit-code 1 infra/ k8s/

tf-fmt: ## Check Terraform formatting
	terraform fmt -check -recursive $(TF_DIR)

tf-validate: ## Validate Terraform without a backend
	terraform -chdir=$(TF_DIR) init -backend=false -input=false
	terraform -chdir=$(TF_DIR) validate

tf-plan: ## Plan against the dev environment (needs az login + backend config)
	terraform -chdir=$(TF_DIR) init -input=false -backend-config=envs/dev.backend.hcl
	terraform -chdir=$(TF_DIR) plan -var-file=envs/dev.tfvars -var="image=$(IMAGE_REF)"

kind-test: build ## Deploy to a local kind cluster and wait for rollout
	kind create cluster --name platex || true
	kind load docker-image $(IMAGE):$(VERSION) --name platex
	sed 's|IMAGE_PLACEHOLDER|$(IMAGE):$(VERSION)|' k8s/deployment.yaml | kubectl apply -f -
	kubectl apply -f k8s/service.yaml -f k8s/pdb.yaml -f k8s/networkpolicy.yaml
	kubectl rollout status deployment/platform-exercise --timeout=120s

clean: ## Remove local image and kind cluster
	-docker rmi $(IMAGE):$(VERSION)
	-kind delete cluster --name platex
