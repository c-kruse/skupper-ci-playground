VERSION := $(shell git describe --tags --dirty=-modified --always)

LDFLAGS_EXTRA ?= -s -w # default to building stripped executables
LDFLAGS := ${LDFLAGS_EXTRA} -X github.com/skupperproject/skupper/pkg/version.Version=${VERSION}
TESTFLAGS := -v -race -short
GOOS ?= linux
GOARCH ?= amd64

REGISTRY := quay.io/skupper
IMAGE_TAG := v2-latest
PLATFORMS ?= linux/amd64,linux/arm64
CONTAINERFILES := Dockerfile.bootstrap Dockerfile.config-sync Dockerfile.controller Dockerfile.network-console-collector

DOCKER := docker
SKOPEO := skopeo
PODMAN := podman

all: build-cmd build-config-sync build-controller build-bootstrap build-manifest build-network-console-collector update-helm-crd

build-cmd:
	GOOS=${GOOS} GOARCH=${GOARCH} go build -ldflags="${LDFLAGS}"  -o skupper ./cmd/skupper

build-bootstrap:
	GOOS=${GOOS} GOARCH=${GOARCH} go build -ldflags="${LDFLAGS}"  -o bootstrap ./cmd/bootstrap

build-controller:
	GOOS=${GOOS} GOARCH=${GOARCH} go build -ldflags="${LDFLAGS}"  -o controller ./cmd/controller

build-config-sync:
	GOOS=${GOOS} GOARCH=${GOARCH} go build -ldflags="${LDFLAGS}"  -o config-sync ./cmd/config-sync

build-network-console-collector:
	GOOS=${GOOS} GOARCH=${GOARCH} go build -ldflags="${LDFLAGS}"  -o network-console-collector ./cmd/network-console-collector

build-manifest:
	go build -ldflags="${LDFLAGS}"  -o manifest ./cmd/manifest

build-doc-generator:
	GOOS=${GOOS} GOARCH=${GOARCH} go build -ldflags="${LDFLAGS}"  -o generate-doc ./internal/cmd/generate-doc

## native/default container image builds
docker-build: $(patsubst Dockerfile.%,docker-build-%,$(CONTAINERFILES))
docker-build-%: Dockerfile.%
	${DOCKER} build -t "${REGISTRY}/$*:${IMAGE_TAG}" -f $< .

podman-build: $(patsubst Dockerfile.%,podman-build-%,$(CONTAINERFILES))
podman-build-%: Dockerfile.%
	${PODMAN} build -t "${REGISTRY}/$*:${IMAGE_TAG}" -f $< .


## multi-platform container images built in docker buildkit builder and
# exported to oci archive format.
multiarch-oci: $(patsubst Dockerfile.%,multiarch-oci-%,$(CONTAINERFILES))
multiarch-oci-%: Dockerfile.% oci-archives
	${DOCKER} buildx build \
		"--output=type=oci,dest=$(shell pwd)/oci-archives/$*.tar" \
		-t "${REGISTRY}/$*:${IMAGE_TAG}" \
		--platform ${PLATFORMS} \
		-f $< .

## push multiarch-oci images to a registry using skopeo
push-multiarch-oci: $(patsubst Dockerfile.%,push-multiarch-oci-%,$(CONTAINERFILES))
push-multiarch-oci-%: ./oci-archives/%.tar
	${SKOPEO} copy --multi-arch all \
		oci-archive:$< \
		"docker://${REGISTRY}/$*:${IMAGE_TAG}"

## Load images from oci-archive into local image storage
docker-load-oci:
	for archive in ./oci-archives/*.tar; do ${DOCKER} load < "$archive"; done
podman-load-oci:
	for archive in ./oci-archives/*.tar; do ${PODMAN} load < "$$archive"; done

## Print fully qualified image names by arch
describe-multiarch-oci:
	@scripts/oci-index-archive-info.sh amd64 arm64

oci-archives:
	mkdir -p oci-archives

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
	rm -rf skupper controller config-sync manifest \
		bootstrap network-console-collector generate-doc \
		cover.out oci-archives
