VERSION := $(shell git describe --tags --dirty=-modified --always)
REVISION := $(shell git rev-parse HEAD)

LDFLAGS_EXTRA ?= -s -w # default to building stripped executables
LDFLAGS := ${LDFLAGS_EXTRA} -X github.com/skupperproject/skupper/pkg/version.Version=${VERSION}
TESTFLAGS := -v -race -short
GOBUILD_CGO := 0
GOBUILD := CGO_ENABLED=${GOBUILD_CGO} go build -ldflags="${LDFLAGS}" -trimpath
BUILD_DIR := .

CONTAINER_PLATFORMS := linux/amd64 linux/arm64
DISTBUILD_CONTAINER_PLATFORMS := $(subst /,-,$(CONTAINER_PLATFORMS))
DISTBUILD_CLI_PLATFORMS := linux-amd64 linux-arm64 linux-s390x darwin-amd64 darwin-arm64 windows-amd64
DISTBUILD_WEB_PLATFORM ?= true
ifeq (${DISTBUILD_WEB_PLATFORM},true)
DISTBUILD_TARGETS = web-dist
endif

REGISTRY := quay.io/skupper
IMAGE_TAG := v2-latest
CONTAINERFILES := Dockerfile.bootstrap Dockerfile.config-sync Dockerfile.controller Dockerfile.network-console-collector
CONTAINER_BASE_IMAGE = registry.access.redhat.com/ubi9/ubi-minimal:9.4-1227.1726694542
SHARED_IMAGE_LABELS = \
    --label "org.opencontainers.image.created=$(shell TZ=GMT date --iso-8601=seconds)" \
	--label "org.opencontainers.image.url=https://skupper.io/" \
	--label "org.opencontainers.image.documentation=https://skupper.io/" \
	--label "org.opencontainers.image.source=https://github.com/skupperproject/skupper" \
	--label "org.opencontainers.image.version=${VERSION}" \
	--label "org.opencontainers.image.revision=${REVISION}" \
	--label "org.opencontainers.image.licenses=Apache-2.0"
SHARED_BUILD_ARGS = \
	--build-arg BASE_IMAGE=${CONTAINER_BASE_IMAGE} \
	--build-arg BUILD_DIR=${BUILD_DIR}



DOCKER := docker
SKOPEO := skopeo
PODMAN := podman

# build all skupper executables
build: build-cli build-config-sync build-controller build-bootstrap build-network-console-collector

build-cli:
	${GOBUILD} -o ${BUILD_DIR}/skupper ./cmd/skupper
	@if [ "$${GOOS}" = "windows" ]; then mv ${BUILD_DIR}/skupper ${BUILD_DIR}/skupper.exe; fi

build-bootstrap:
	${GOBUILD} -o ${BUILD_DIR}/bootstrap ./cmd/bootstrap

build-controller:
	${GOBUILD} -o ${BUILD_DIR}/controller ./cmd/controller

build-config-sync:
	${GOBUILD} -o ${BUILD_DIR}/config-sync ./cmd/config-sync

build-network-console-collector:
	${GOBUILD} -o ${BUILD_DIR}/network-console-collector ./cmd/network-console-collector

build-manifest:
	${GOBUILD} -o ${BUILD_DIR}/manifest ./cmd/manifest

build-doc-generator:
	${GOBUILD} -o ${BUILD_DIR}/generate-doc ./internal/cmd/generate-doc

web-dist:
	@mkdir -p ./dist/web
	${DOCKER} build --output type=local,dest=./dist/web -f Dockerfile.console-builder .

## native/default container image builds
docker-build: dist-web
docker-build: $(patsubst Dockerfile.%,docker-build-%,$(CONTAINERFILES))
docker-build-%: Dockerfile.% build-%
	${DOCKER} build $(SHARED_IMAGE_LABELS) $(SHARED_BUILD_ARGS) -t "${REGISTRY}/$*:${IMAGE_TAG}" -f $< ${BUILD_DIR}

podman-build: web-dist
podman-build: $(patsubst Dockerfile.%,podman-build-%,$(CONTAINERFILES))
podman-build-%: Dockerfile.% build-%
	${PODMAN} build $(SHARED_IMAGE_LABELS) $(SHARED_BUILD_ARGS) -t "${REGISTRY}/$*:${IMAGE_TAG}" -f $< ${BUILD_DIR}

## multi platform container images built with podman manifest and exported to
# an oci archive format. Depends on podman and a system configured to run
# multi-arch builds for the target platforms.
podman-build-multiarch: $(patsubst Dockerfile.%,podman-build-multiarch-%,$(CONTAINERFILES))
podman-build-multiarch-%: SHELL := /bin/bash
podman-build-multiarch-%: Dockerfile.%
	mkdir -p ./oci-archives
	${PODMAN} manifest rm "${REGISTRY}/$*:${IMAGE_TAG}-index" || true
	${PODMAN} manifest create "${REGISTRY}/$*:${IMAGE_TAG}-index"
	for platform in ${CONTAINER_PLATFORMS}; do \
		${PODMAN} build --platform "$$platform" \
			$(SHARED_IMAGE_LABELS) $(SHARED_BUILD_ARGS) \
			--build-arg BASE_IMAGE=${CONTAINER_BASE_IMAGE} \
			--build-arg BUILD_DIR=./dist/$${platform/\//-}/ \
			--manifest "${REGISTRY}/$*:${IMAGE_TAG}-index" \
			-f $< .; \
	done
	${PODMAN} manifest push \
		"${REGISTRY}/$*:${IMAGE_TAG}-index" \
		oci-archive:./oci-archives/$*.tar

## Print fully qualified image names by arch
describe-multiarch-oci:
	@scripts/oci-index-archive-info.sh amd64 arm64

## push multiarch-oci images to a registry using skopeo
push-multiarch-oci: $(patsubst Dockerfile.%,push-multiarch-oci-%,$(CONTAINERFILES))
push-multiarch-oci-%: ./oci-archives/%.tar
	${SKOPEO} copy --all \
		oci-archive:$< \
		"docker://${REGISTRY}/$*:${IMAGE_TAG}"

## Load images from oci-archive into local image storage
podman-load-oci:
	for archive in ./oci-archives/*.tar; do ${PODMAN} load < "$$archive"; done

## Has unfortunate podman dependency; docker image load does not load OCI archives, while podman does.
docker-load-oci:
	for archive in ./oci-archives/*.tar; do \
		img=$$(${PODMAN} load -q < "$$archive" | awk -F": " '{print $$2}') \
		&& ${PODMAN} image save "$$img" | ${DOCKER} load; \
	done

.PHONY: dist

# Build all executables for the container platforms
dist: $(patsubst %,dist-%,$(DISTBUILD_CONTAINER_PLATFORMS))
# Build CLI for all CLI platforms not included in the container platforms
dist: $(patsubst %,cli-dist-%,$(filter-out $(DISTBUILD_CONTAINER_PLATFORMS),$(DISTBUILD_CLI_PLATFORMS)))
# Build web content
dist: $(DISTBUILD_TARGETS)

cli-dist: $(patsubst %,cli-dist-%,$(DISTBUILD_CLI_PLATFORMS))
cli-dist-%:
	@mkdir -p ./dist/$*
	$(MAKE) build-cli \
		GOOS=$(word 1, $(subst -, ,$*)) \
		GOARCH=$(word 2, $(subst -, ,$*)) \
		BUILD_DIR=./dist/$*

dist-%:
	@mkdir -p ./dist/$*
	$(MAKE) build \
		GOOS=$(word 1, $(subst -, ,$*)) \
		GOARCH=$(word 2, $(subst -, ,$*)) \
		BUILD_DIR=./dist/$*

.PHONY: archives
archives: $(patsubst linux-%,archives-linux-%,$(filter linux-%,$(DISTBUILD_CLI_PLATFORMS)))
archives: $(patsubst darwin-%,archives-darwin-%,$(filter darwin-%,$(DISTBUILD_CLI_PLATFORMS)))
archives: $(patsubst windows-%,archives-windows-%,$(filter windows-%,$(DISTBUILD_CLI_PLATFORMS)))
archives-linux-%:
	@mkdir -p ./archives
	tar -zcf "./archives/skupper-cli-${VERSION}-linux-$*.tgz" \
		-C ./dist/linux-$* skupper

archives-darwin-%:
	@mkdir -p ./archives
	tar -zcf "./archives/skupper-cli-${VERSION}-mac-$*.tgz" \
		-C ./dist/darwin-$* skupper

archives-windows-%:
	@mkdir -p ./archives
	base=$(shell pwd); \
		 cd ./dist/windows-$*; \
		 zip -q "$$base/archives/skupper-cli-${VERSION}-windows-$*.zip" skupper.exe \
		 cd ../..

format:
	go fmt ./...

generate-client:
	./scripts/update-codegen.sh

force-generate-client:
	FORCE=true ./scripts/update-codegen.sh

vet:
	go vet ./...

.PHONY: test
test:
	go test ${TESTFLAGS} ./...

.PHONY: cover
cover:
	go test ${TESTFLAGS} \
		-cover \
		-coverprofile cover.out \
		./...

generate-manifest: build-manifest
	./manifest

generate-doc: build-doc-generator
	./generate-doc ./doc/cli

update-helm-crd:
	./scripts/update-helm-crds.sh

clean:
	@rm -rvf skupper skupper.exe controller config-sync manifest \
		bootstrap network-console-collector generate-doc \
		cover.out oci-archives dist archives
