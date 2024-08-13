MAKEFLAGS += --warn-undefined-variables
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:
.SUFFIXES:
.ONESHELL:

# The version which will be reported by the --version argument of each binary
# and which will be used as the Docker image tag
VERSION ?= $(shell git describe --tags)
# The Docker repository name, overridden in CI.
DOCKER_REGISTRY ?= docker-registry.wikimedia.org
DOCKER_IMAGE_NAME ?= cfssl-issuer
# Image URL to use all building/pushing image targets
IMG ?= ${DOCKER_REGISTRY}/${DOCKER_IMAGE_NAME}:${VERSION}

# BIN is the directory where tools will be installed
export BIN ?= ${CURDIR}/bin

# Kind
# https://github.com/kubernetes-sigs/kind/
KIND_VERSION := 0.18.0
KIND := ${BIN}/kind-${KIND_VERSION}
KIND_K8S_VERSION := kindest/node:v1.26.6@sha256:6e2d8b28a5b601defe327b98bd1c2d1930b49e5d8c512e1895099e4504007adb
K8S_CLUSTER_NAME := cfssl-issuer-e2e

# cert-manager
CERT_MANAGER_VERSION ?= 1.11.1

# Controller tools
CONTROLLER_GEN := ${BIN}/controller-gen

INSTALL_YAML ?= build/install.yaml

.PHONY: all
all: manifests manager

.PHONY: all
vendor:
	go mod tidy
	go mod vendor

# Run tests
.PHONY: test
test: generate fmt vet manifests
	go test ./... -coverprofile cover.out
	go tool cover -html=cover.out -o cover.html

# Build manager binary
.PHONY: manager
manager: generate fmt vet vendor
	go build \
		-ldflags="-X=gerrit.wikimedia.org/r/operations/software/cfssl-issuer/internal/version.Version=${VERSION}" \
		-o bin/manager main.go

# Run against the configured Kubernetes cluster in ~/.kube/config
run: export SSL_CERT_FILE = simple-cfssl-ca.pem
run: generate fmt vet manifests
	go run ./main.go --cluster-resource-namespace=cfssl-issuer-system

##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

# Build the docker image
.PHONY: docker-build
docker-build: vendor
	docker build \
		--build-arg VERSION=$(VERSION) \
		--tag ${IMG} \
		--file Dockerfile \
		${CURDIR}

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

##@ E2E testing

# ==================================
# simple-cfssl
# ==================================
docker-build-simple-cfssl:
	cd simple-cfssl
	docker build --tag simple-cfssl .


# ==================================
# E2E testing
# ==================================
.PHONY: kind-cluster
kind-cluster: ${KIND} ## Use Kind to create a Kubernetes cluster for E2E tests
	 ${KIND} get clusters | grep ${K8S_CLUSTER_NAME} || ${KIND} create cluster --name ${K8S_CLUSTER_NAME} --image ${KIND_K8S_VERSION}

.PHONY: kind-load
kind-load: ${KIND} ## Load the Docker image into Kind
	${KIND} load docker-image --name ${K8S_CLUSTER_NAME} ${IMG}
	${KIND} load docker-image --name ${K8S_CLUSTER_NAME} simple-cfssl:latest

.PHONY: kind-export-logs
kind-export-logs: ${KIND} ## Export Kind logs
	${KIND} export logs --name ${K8S_CLUSTER_NAME} ${E2E_ARTIFACTS_DIRECTORY}

.PHONY: deploy-cert-manager
deploy-cert-manager: ## Deploy cert-manager in the configured Kubernetes cluster in ~/.kube/config
	kubectl apply --filename=https://github.com/cert-manager/cert-manager/releases/download/v${CERT_MANAGER_VERSION}/cert-manager.yaml
	kubectl wait --for=condition=Available --timeout=300s apiservice v1.cert-manager.io
	# Wait for the webhook to be up and running
	kubectl wait --for=condition=Ready --timeout=60s -n cert-manager pods -l app=webhook


.PHONY: deploy-simple-cfssl
deploy-simple-cfssl:
	kubectl delete --ignore-not-found=true -f simple-cfssl/simple-cfssl.yaml
	kubectl apply -f simple-cfssl/simple-cfssl.yaml
	kubectl -n simple-cfssl wait --for=condition=Available --timeout=60s deployment simple-cfssl
	kubectl -n simple-cfssl exec -it deployment/simple-cfssl -- cat /cfssl/ca/ca.pem > simple-cfssl-ca.pem

.PHONY: e2e
e2e: deploy-cert-manager deploy ## Run e2e on whatever cluster is active in .kube/config
	kubectl apply --filename config/samples

	# Copy the newly created simple-cfssl CA to the cfssl-issuer-system namespace
	kubectl -n cfssl-issuer-system delete --ignore-not-found=true secret simple-cfssl-ca
	kubectl -n cfssl-issuer-system create secret generic simple-cfssl-ca --from-file=ca.pem=simple-cfssl-ca.pem

	kubectl wait --for=condition=Ready --timeout=10s issuers.cfssl-issuer.wikimedia.org issuer-sample
	kubectl wait --for=condition=Ready --timeout=10s certificaterequests.cert-manager.io issuer-sample
	kubectl wait --for=condition=Ready --timeout=10s certificates.cert-manager.io certificate-by-issuer

	kubectl wait --for=condition=Ready --timeout=10s clusterissuers.cfssl-issuer.wikimedia.org clusterissuer-sample
	kubectl wait --for=condition=Ready --timeout=10s certificaterequests.cert-manager.io clusterissuer-sample
	kubectl wait --for=condition=Ready --timeout=10s certificates.cert-manager.io certificate-by-clusterissuer

	kubectl wait --for=condition=Ready --timeout=10s clusterissuers.cfssl-issuer.wikimedia.org bundleissuer-sample
	kubectl wait --for=condition=Ready --timeout=10s certificates.cert-manager.io certificate-by-bundleissuer
	kubectl get secrets certificate-by-bundleissuer -o jsonpath='{.data.ca\.crt}' | grep -q ^

	kubectl delete --filename config/samples
	kubectl delete secrets --field-selector type=kubernetes.io/tls

.PHONY: e2e-full
e2e-full: kind-cluster kind-load deploy-simple-cfssl e2e ## Create local kind cluster and run e2e there

.PHONY: e2e-all
e2e-all: docker-build docker-build-simple-cfssl e2e-full ## Build all docker images and run e2e in local kind cluster

##@ Build

.PHONY: build
build: manifests generate fmt vet ## Build manager binary
	go build -o bin/manager main.go

# Push the docker image
.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	docker push ${IMG}

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/crd | kubectl delete --ignore-not-found=$(ignore-not-found) -f -

# TODO(wallrj): .PHONY ensures that the install file is always regenerated,
# because I this really depends on the checksum of the Docker image and all the
# base Kustomize files.
.PHONY: ${INSTALL_YAML}
${INSTALL_YAML}: manifests kustomize
	mkdir -p $(dir $@)
	rm -rf build/kustomize
	mkdir -p build/kustomize
	cd build/kustomize
	$(KUSTOMIZE) create --resources ../../config/default
	$(KUSTOMIZE) edit set image controller=${IMG}
	cd ${CURDIR}
	$(KUSTOMIZE) build build/kustomize > $@

.PHONY: deploy
deploy: ${INSTALL_YAML}  ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	 kubectl apply -f ${INSTALL_YAML}

.PHONY: undeploy
undeploy: ${INSTALL_YAML} ## Undeploy controller from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	 kubectl delete -f ${INSTALL_YAML}  --ignore-not-found=$(ignore-not-found)

##@ Build Dependencies

LOCAL_OS := $(shell go env GOOS)
LOCAL_ARCH := $(shell go env GOARCH)

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
KUSTOMIZE ?= $(LOCALBIN)/kustomize
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
ENVTEST ?= $(LOCALBIN)/setup-envtest
KIND ?= $(LOCALBIN)/kind

## Tool Versions
KUSTOMIZE_VERSION ?= v3.8.7
CONTROLLER_TOOLS_VERSION ?= v0.15.0

KUSTOMIZE_INSTALL_SCRIPT ?= "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"
.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary. If wrong version is installed, it will be removed before downloading.
$(KUSTOMIZE): $(LOCALBIN)
	@if test -x $(LOCALBIN)/kustomize && ! $(LOCALBIN)/kustomize version | grep -q $(KUSTOMIZE_VERSION); then \
		echo "$(LOCALBIN)/kustomize version is not expected $(KUSTOMIZE_VERSION). Removing it before installing."; \
		rm -rf $(LOCALBIN)/kustomize; \
	fi
	test -s $(LOCALBIN)/kustomize || { curl -Ss $(KUSTOMIZE_INSTALL_SCRIPT) | bash -s -- $(subst v,,$(KUSTOMIZE_VERSION)) $(LOCALBIN); }

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary. If wrong version is installed, it will be overwritten.
$(CONTROLLER_GEN): $(LOCALBIN)
	test -s $(LOCALBIN)/controller-gen && $(LOCALBIN)/controller-gen --version | grep -q $(CONTROLLER_TOOLS_VERSION) || \
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_TOOLS_VERSION)

.PHONY: envtest
envtest: $(ENVTEST) ## Download envtest-setup locally if necessary.
$(ENVTEST): $(LOCALBIN)
	test -s $(LOCALBIN)/setup-envtest || GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest

.PHONY: kind
kind: $(LOCALBIN) ## Download Kind locally if necessary.
	curl -fsSL -o ${KIND} https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-${LOCAL_OS}-${LOCAL_ARCH}
	chmod +x ${KIND}
