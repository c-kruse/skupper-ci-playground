VERSION := $(shell git describe --tags --dirty=-modified --always)
REVISION := $(shell git rev-parse HEAD)

LDFLAGS_EXTRA ?= -s -w # default to building stripped executables
LDFLAGS := ${LDFLAGS_EXTRA} -X github.com/skupperproject/skupper/pkg/version.Version=${VERSION}
TESTFLAGS := -v -race -short
GOBUILD_CGO := 0
GOBUILD := CGO_ENABLED=${GOBUILD_CGO} go build -ldflags="${LDFLAGS}" -trimpath
BUILD_DIR := .

REGISTRY := quay.io/skupper
IMAGE_TAG := v2-latest
PLATFORMS ?= linux/amd64 linux/arm64
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

all: build-cmd build-config-sync build-controller build-bootstrap build-network-console-collector

skupper-all: skupper

skupper: skupper-linux-amd64 skupper-linux-arm64 skupper-darwin-amd64 skupper-darwin-arm64 skupper-windows-amd64 skupper-console

skupper-linux-amd64: dist
	$(MAKE) all GOOS=linux GOARCH=amd64 BUILD_DIR=./dist/linux-amd64
skupper-linux-arm64: dist
	$(MAKE) all GOOS=linux GOARCH=arm64 BUILD_DIR=./dist/linux-arm64
skupper-darwin-amd64: dist
	$(MAKE) build-cmd GOOS=darwin GOARCH=amd64 BUILD_DIR=./dist/darwin-amd64
skupper-darwin-arm64: dist
	$(MAKE) build-cmd GOOS=darwin GOARCH=arm64 BUILD_DIR=./dist/darwin-arm64
skupper-windows-amd64: dist
	$(MAKE) build-cmd GOOS=windows GOARCH=amd64 BUILD_DIR=./dist/windows-amd64
	mv ./dist/windows-amd64/skupper ./dist/windows-amd64/skupper.exe
skupper-console: dist
	${DOCKER} build --output type=local,dest=./dist/web -f Dockerfile.console-builder .

.PHONY: archives
archives: SHELL := /bin/bash
archives:
	mkdir -p archives
	archiveDir=$(shell pwd)/archives; \
	for d in ./dist/*; do \
		if [[ -d "$$d" ]]; then \
			pushd "$$d"; \
			p="$${d/#*dist\/}"; \
            if [[ "$$d" =~ (linux|darwin) ]]; then \
            	tar -zcf "$$archiveDir/skupper-cli-${VERSION}-$$p.tgz" skupper; \
            fi; \
            if [[ "$$d" =~ windows ]]; then \
            	zip -q "$$archiveDir/skupper-cli-${VERSION}-$$p.zip" skupper.exe; \
            fi; \
			popd; \
		fi; \
	done;

ex:


build-cmd:
	${GOBUILD} -o ${BUILD_DIR}/skupper ./cmd/skupper

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

dist:
	mkdir -p \
		dist/web \
		dist/linux-amd64 \
		dist/linux-arm64 \
		dist/darwin-amd64 \
		dist/darwin-arm64 \
		dist/windows-amd64;

## native/default container image builds
docker-build: $(patsubst Dockerfile.%,docker-build-%,$(CONTAINERFILES))
docker-build-%: Dockerfile.% build-%
	${DOCKER} build $(SHARED_IMAGE_LABELS) $(SHARED_BUILD_ARGS) -t "${REGISTRY}/$*:${IMAGE_TAG}" -f $< ${BUILD_DIR}

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
	for platform in ${PLATFORMS}; do \
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
