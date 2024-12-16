SHELL := /bin/bash

# Current Operator version
VERSION ?= main
CSV_VERSION = $(shell echo $(VERSION) | sed 's/v//')
ifeq ($(VERSION), main)
CSV_VERSION := 0.0.0
endif
ifeq ($(VERSION), dev)
CSV_VERSION := 0.0.0
endif
# Default image repo
REPO ?= quay.io/metallb

# Image URL to use all building/pushing image targets
IMG ?= $(REPO)/metallb-operator:$(VERSION)
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:crdVersions=v1"
#Which dir to use in deploy kustomize build
KUSTOMIZE_DEPLOY_DIR ?= config/default

# Route to operator-sdk binary
OPERATOR_SDK=_cache/operator-sdk

# Default bundle image tag
BUNDLE_IMG ?= $(REPO)/metallb-operator-bundle:$(VERSION)
# Default bundle index image tag
BUNDLE_INDEX_IMG ?= $(REPO)/metallb-operator-bundle-index:$(VERSION)

# Options for 'bundle'
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# Default namespace
NAMESPACE ?= metallb-system

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

OPERATOR_SDK_VERSION ?= v1.34.1
OLM_VERSION ?= v0.18.3
OPM_VERSION ?= v1.23.2
KUSTOMIZE_VERSION ?= v5.0.1
KUSTOMIZE=$(shell pwd)/_cache/kustomize
KIND ?= $(shell pwd)/_cache/kind
KIND_VERSION=v0.22.0
CACHE_PATH=$(shell pwd)/_cache



OPM_TOOL_URL=https://api.github.com/repos/operator-framework/operator-registry/releases

TESTS_REPORTS_PATH ?= /tmp/test_e2e_logs/
VALIDATION_TESTS_REPORTS_PATH ?= /tmp/test_validation_logs/

ENVTEST_ASSETS_DIR=$(shell pwd)/testbin
test: generate fmt vet manifests ## Run unit and integration tests
	mkdir -p ${ENVTEST_ASSETS_DIR}
	test -f ${ENVTEST_ASSETS_DIR}/setup-envtest.sh || curl -sSLo ${ENVTEST_ASSETS_DIR}/setup-envtest.sh https://raw.githubusercontent.com/kubernetes-sigs/controller-runtime/v0.8.3/hack/setup-envtest.sh
	source ${ENVTEST_ASSETS_DIR}/setup-envtest.sh; fetch_envtest_tools $(ENVTEST_ASSETS_DIR); setup_envtest_env $(ENVTEST_ASSETS_DIR); go test -race ./... -coverprofile cover.out

all: manager ## Default make target if no options specified

test-validation: generate fmt vet manifests  ## Run validation tests
	rm -rf ${VALIDATION_TESTS_REPORTS_PATH}
	mkdir -p ${VALIDATION_TESTS_REPORTS_PATH}
	USE_LOCAL_RESOURCES=true go test --tags=validationtests -v ./test/e2e/validation -ginkgo.v -junit $(VALIDATION_TESTS_REPORTS_PATH) -report $(VALIDATION_TESTS_REPORTS_PATH)

SKIP ?= ""
test-functional: generate fmt vet manifests  ## Run e2e tests
	rm -rf ${TESTS_REPORTS_PATH}
	mkdir -p ${TESTS_REPORTS_PATH}
	USE_LOCAL_RESOURCES=true go test --tags=e2etests -v ./test/e2e/functional -ginkgo.v --ginkgo.skip=${SKIP} -junit $(TESTS_REPORTS_PATH) -report $(TESTS_REPORTS_PATH)

test-e2e: generate fmt vet manifests test-validation test-functional  ## Run e2e tests

manager: generate fmt vet  ## Build manager binary
	go build -ldflags "-X main.build=$$(git rev-parse HEAD)" -o bin/manager main.go

run: generate fmt vet manifests  ## Run against the configured cluster
	go run ./main.go

install: manifests kustomize  ## Install CRDs into a cluster
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

uninstall: manifests kustomize  ## Uninstall CRDs from a cluster
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

deploy: export VERSION=dev
deploy: manifests kustomize kind-cluster load-on-kind  ## Deploy controller in the configured cluster
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	cd $(KUSTOMIZE_DEPLOY_DIR) && $(KUSTOMIZE) edit set namespace $(NAMESPACE)
	cd config/metallb_rbac && $(KUSTOMIZE) edit set namespace $(NAMESPACE)
	$(KUSTOMIZE) build $(KUSTOMIZE_DEPLOY_DIR) | kubectl apply -f -
	$(KUSTOMIZE) build config/metallb_rbac | kubectl apply -f -

set-namespace-openshift:
	sed -i 's/  namespace:.*/  namespace: $(NAMESPACE)/' $(KUSTOMIZE_DEPLOY_DIR)/custom-namespace-transformer.yaml

deploy-openshift: KUSTOMIZE_DEPLOY_DIR=config/openshift
deploy-openshift: set-namespace-openshift deploy ## Deploy controller in the configured OpenShift cluster

undeploy: ## Undeploy the controller from the configured cluster
	$(KUSTOMIZE) build $(KUSTOMIZE_DEPLOY_DIR) | kubectl delete --ignore-not-found=true -f -
	$(KUSTOMIZE) build config/metallb_rbac | kubectl delete --ignore-not-found=true -f -

undeploy-openshift: KUSTOMIZE_DEPLOY_DIR=config/openshift
undeploy-openshift: undeploy ## Undeploy the controller from the configured OpenShift cluster

BIN_FILE ?= "metallb-operator.yaml"
bin: manifests kustomize ## Create manifests
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	cd $(KUSTOMIZE_DEPLOY_DIR) && $(KUSTOMIZE) edit set namespace $(NAMESPACE)
	cd config/metallb_rbac && $(KUSTOMIZE) edit set namespace $(NAMESPACE)
	$(KUSTOMIZE) build $(KUSTOMIZE_DEPLOY_DIR) > bin/$(BIN_FILE)
	echo "---" >> bin/$(BIN_FILE)
	$(KUSTOMIZE) build config/metallb_rbac >> bin/$(BIN_FILE)

manifests: controller-gen generate-metallb-manifests  ## Generate manifests e.g. CRD, RBAC etc.
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=metallb-manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases
	sed -i -e 's/validating-webhook-configuration/metallb-operator-webhook-configuration/g' config/webhook/manifests.yaml
	sed -i -e 's/webhook-service/metallb-operator-webhook-service/g' config/webhook/manifests.yaml

fmt:  ## Run go fmt against code
	[ -z "`gofmt -s -w -l -e .`" ]
	go fmt ./...

vet:  ## Run go vet against code
	go vet ./...

generate: controller-gen  ## Generate code
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

# Build the docker image
docker-build:  ## Build the docker image
	docker buildx build --load --platform linux/amd64 -t ${IMG} --build-arg GIT_COMMIT="$(shell git rev-parse HEAD)" .

docker-push:  ## Push the docker image
	docker push ${IMG}

bundle: operator-sdk manifests  ## Generate bundle manifests and metadata, then validate generated files.
	ls -d config/crd/bases/* | grep -v metallb.io_metallbs | xargs -I{} cp {} bundle/manifests/
	rm bundle/manifests/metallb.io_servicel2statuses.yaml # TODO remove when metallb support is added
	$(OPERATOR_SDK) generate kustomize manifests --interactive=false -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/manifests | $(OPERATOR_SDK) generate bundle -q --overwrite --version $(CSV_VERSION) $(BUNDLE_METADATA_OPTS) --extra-service-accounts "controller,speaker,frr-k8s-daemon"
	$(OPERATOR_SDK) bundle validate ./bundle

bundle-release: kustomize bundle bump_versions  ## Generate the bundle manifests for a PR

build-bundle: ## Build the bundle image.
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

.PHONY: kind-cluster
kind-cluster: kind
	KIND_BIN=$(KIND) hack/kind/kind.sh

.PHONY: load-on-kind
load-on-kind: docker-build kind-cluster ## Load the docker image into the kind cluster.
	$(KIND) load docker-image ${IMG}

deploy-with-olm: export VERSION=dev
deploy-with-olm: load-on-kind build-and-push-bundle-images ## deploys the operator with OLM instead of manifests
	sed -i 's|image:.*|image: $(BUNDLE_INDEX_IMG)|' config/olm-install/install-resources.yaml
	sed -i 's#mymetallb#$(NAMESPACE)#g' config/olm-install/install-resources.yaml
	$(KUSTOMIZE) build config/olm-install | kubectl apply -f -
	VERSION=$(CSV_VERSION) NAMESPACE=$(NAMESPACE) hack/wait-for-csv.sh

bundle-index-build: opm  ## Build the bundle index image.
	$(OPM) index add --bundles $(BUNDLE_IMG) --tag $(BUNDLE_INDEX_IMG) -c docker -i quay.io/operator-framework/opm:$(OPM_VERSION)

build-and-push-bundle-images: docker-build docker-push  ## Generate and push bundle image and bundle index image
	$(MAKE) bundle
	$(MAKE) build-bundle
	$(MAKE) docker-push IMG=$(BUNDLE_IMG)
	$(MAKE) bundle-index-build
	$(MAKE) docker-push IMG=$(BUNDLE_INDEX_IMG)

deploy-prometheus:
	hack/deploy_prometheus.sh

# find or download controller-gen
# download controller-gen if necessary
controller-gen:
ifeq (, $(shell which controller-gen))
	go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.14.0
CONTROLLER_GEN=$(GOBIN)/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif

# Get the current operator-sdk binary into the _cache dir.
kustomize:
	mkdir -p _cache
ifeq (,$(findstring $(KUSTOMIZE_VERSION),$(shell _cache/kustomize version)))
	@{ \
	set -e ;\
	curl -s -L https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F$(KUSTOMIZE_VERSION)/kustomize_$(KUSTOMIZE_VERSION)_linux_amd64.tar.gz | tar fxvz - -C _cache ;\
	chmod u+x _cache/kustomize ;\
	}
endif

# Get the current operator-sdk binary into the _cache dir.
operator-sdk:
	mkdir -p _cache
ifeq (,$(findstring $(OPERATOR_SDK_VERSION),$(shell _cache/operator-sdk version)))
	@{ \
	set -e ;\
	curl -Lk  https://github.com/operator-framework/operator-sdk/releases/download/$(OPERATOR_SDK_VERSION)/operator-sdk_linux_amd64 > _cache/operator-sdk ;\
	chmod u+x _cache/operator-sdk ;\
	}
endif

# Get the current opm binary. If there isn't any, we'll use the
# GOBIN path
opm:
ifeq (, $(shell which opm))
	@{ \
	set -e ;\
	curl -Lk https://github.com/operator-framework/operator-registry/releases/download/$(OPM_VERSION)/linux-amd64-opm > $(GOBIN)/opm ;\
	chmod u+x $(GOBIN)/opm ;\
	}
OPM=$(GOBIN)/opm
else
OPM=$(shell which opm)
endif

# Get the current kubectl binary. If there isn't any, we'll use the
# GOBIN path
kubectl:
ifeq (, $(shell which kubectl))
	@{ \
	set -e ;\
	curl -LO https://dl.k8s.io/release/v1.23.0/bin/linux/amd64/kubectl > $(GOBIN)/kubectl ;\
	chmod u+x $(GOBIN)/kubectl ;\
	}
endif

.PHONY: kind
kind: $(KIND) ## Download kind locally if necessary. If wrong version is installed, it will be overwritten.
$(KIND):
	test -s $(KIND) && $(KIND)/kind --version | grep -q $(KIND_VERSION) || \
	GOBIN=$(CACHE_PATH) go install sigs.k8s.io/kind@$(KIND_VERSION)

generate-metallb-manifests: kubectl ## Generate MetalLB manifests
	@echo "Generating MetalLB manifests"
	hack/generate-metallb-manifests.sh

validate-metallb-manifests:  ## Validate MetalLB manifests
	@echo "Comparing newly generated MetalLB manifests to existing ones"
	hack/compare-gen-manifests.sh

lint: ## Run golangci-lint against code
	@echo "Running golangci-lint"
	hack/lint.sh

fetch_metallb_version: ## Updates the versions of metallb under hack/metallb_version with the latest available tag
	@echo "Bumping metallb to latest"
	hack/fetch_latest_metallb.sh

bump_versions: ## Updates the versions of the metallb-operator / metallb image with the content of hack/operator_version / metallb_version
	@echo "Updating the operator version"
	hack/bump_versions.sh



bump_metallb: ## Bumps metallb commit ID and creates manifests. It also validates the changes.
	@echo "Updating the metallb version"
	hack/bump_metallb.sh
	$(MAKE) bin
	$(MAKE) bundle-release
	go test ./pkg/helm/... --update

check_generated: ## Checks if there are any different with the current checkout
	@echo "Checking generated files"
	hack/verify_generated.sh

help:  ## Show this help
	@grep -F -h "##" $(MAKEFILE_LIST) | grep -F -v grep | sed -e 's/\\$$//' \
		| awk -F'[:#]' '{print $$1 = sprintf("%-30s", $$1), $$4}'
