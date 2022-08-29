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
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true"

# BIN is the directory where tools will be installed
export BIN ?= ${CURDIR}/bin

OS := $(shell go env GOOS)
ARCH := $(shell go env GOARCH)

# Kind
# https://github.com/kubernetes-sigs/kind/
KIND_VERSION := 0.12.0
KIND := ${BIN}/kind-${KIND_VERSION}
# v1.19.11 was the oldest version actually working on my machine with kind
KIND_K8S_VERSION := kindest/node:v1.19.11@sha256:7664f21f9cb6ba2264437de0eb3fe99f201db7a3ac72329547ec4373ba5f5911
K8S_CLUSTER_NAME := cfssl-issuer-e2e

# cert-manager
CERT_MANAGER_VERSION ?= 1.8.0

# Controller tools
CONTROLLER_GEN_VERSION := 0.6.2
CONTROLLER_GEN := ${BIN}/controller-gen-${CONTROLLER_GEN_VERSION}

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

# Install CRDs into a cluster
.PHONY: install
install: manifests
	kustomize build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
.PHONY: uninstall
uninstall: manifests
	kustomize build config/crd | kubectl delete -f -

# TODO(wallrj): .PHONY ensures that the install file is always regenerated,
# because I this really depends on the checksum of the Docker image and all the
# base Kustomize files.
.PHONY: ${INSTALL_YAML}
${INSTALL_YAML}:
	mkdir -p $(dir $@)
	rm -rf build/kustomize
	mkdir -p build/kustomize
	cd build/kustomize
	kustomize create --resources ../../config/default
	kustomize edit set image controller=${IMG}
	cd ${CURDIR}
	kustomize build build/kustomize > $@

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
.PHONY: deploy
deploy: ${INSTALL_YAML}
	 kubectl apply -f ${INSTALL_YAML}

# Generate manifests e.g. CRD, RBAC etc.
.PHONY: manifests
manifests: ${CONTROLLER_GEN}
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases

# Run go fmt against code
.PHONY: fmt
fmt:
	go fmt ./...

# Run go vet against code
.PHONY: vet
vet:
	go vet ./...

# Generate code
generate: ${CONTROLLER_GEN}
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

# Build the docker image
.PHONY: docker-build
docker-build: vendor
	docker build \
		--build-arg VERSION=$(VERSION) \
		--tag ${IMG} \
		--file Dockerfile \
		${CURDIR}

# Push the docker image
.PHONY: docker-push
docker-push:
	docker push ${IMG}

${CONTROLLER_GEN}: | ${BIN}
	CONTROLLER_GEN_TMP_DIR=$$(mktemp -d)
	trap "rm -rf $${CONTROLLER_GEN_TMP_DIR}" EXIT
	cd $${CONTROLLER_GEN_TMP_DIR}
	go mod init tmp
	GOBIN=$${CONTROLLER_GEN_TMP_DIR} go get sigs.k8s.io/controller-tools/cmd/controller-gen@v${CONTROLLER_GEN_VERSION}
	mv $${CONTROLLER_GEN_TMP_DIR}/controller-gen ${CONTROLLER_GEN}


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
kind-load: ## Load the Docker image into Kind
	${KIND} load docker-image --name ${K8S_CLUSTER_NAME} ${IMG}
	${KIND} load docker-image --name ${K8S_CLUSTER_NAME} simple-cfssl:latest

.PHONY: kind-export-logs
kind-export-logs:
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

# ==================================
# Download: tools in ${BIN}
# ==================================
${BIN}:
	mkdir -p ${BIN}

${KIND}: ${BIN}
	curl -fsSL -o ${KIND} https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-${OS}-${ARCH}
	chmod +x ${KIND}
