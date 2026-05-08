#
# Front door for the most common local commands. Each target shells out
# to the matching script under scripts/ -- run those directly for the
# full flag surface (--help on each).
#

REPO_ROOT := $(shell pwd)
ENV       ?= dev
IMAGE     ?= wm-microservice:dev
PACKAGE   ?=

include versions.env
export

.DEFAULT_GOAL := help

.PHONY: help build lint test integration-test contract-test image deploy validate-config clean

help: ## Show this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build dist/<pkg>-<ver>.zip for every packages/<P>/.
	./scripts/build-packages.sh

lint: ## Run wm-mcp lint over packages/.
	./scripts/lint-packages.sh

test: ## Run unit tests (UTF in container) and enforce coverage gate.
	./scripts/test-unit.sh $(if $(PACKAGE),--package $(PACKAGE),)

integration-test: ## Run integration suite against docker-compose sidecars.
	./scripts/test-integration.sh

contract-test: ## Run REST/SOAP contract diffs against fixtures.
	./scripts/test-contracts.sh

validate-config: ## Validate config/ against schemas/config.schema.json.
	./scripts/validate-config.sh

image: build ## Build the per-service Docker image (tag: $(IMAGE)).
	docker build \
	    -f docker/service/Dockerfile \
	    -t $(IMAGE) \
	    .

deploy: ## Apply config/base + config/$(ENV) to a running MSR. ENV=dev|test|prod
	./scripts/apply-config.sh --env $(ENV)

clean: ## Remove build artifacts.
	rm -rf dist/ reports/
