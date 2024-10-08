VERSION := $(shell git describe --tags --dirty=-modified --always)
REGISTRY := quay.io/skupper
CONTROLLER_IMAGE := ${REGISTRY}/controller:v2-latest
BOOTSTRAP_IMAGE := ${REGISTRY}/bootstrap:v2-latest
CONFIG_SYNC_IMAGE := ${REGISTRY}/config-sync:v2-latest
NETWORK_CONSOLE_COLLECTOR_IMAGE := ${REGISTRY}/network-console-collector:v2-latest
DOCKER := docker
LDFLAGS := -X github.com/skupperproject/skupper/pkg/version.Version=${VERSION}
TESTFLAGS := -v -race -short
PLATFORMS ?= linux/amd64,linux/arm64
GOOS ?= linux
GOARCH ?= amd64

all: build-cmd build-config-sync build-controller build-bootstrap build-manifest build-network-console-collector

build-cmd:
	GOOS=${GOOS} GOARCH=${GOARCH} go build -ldflags="${LDFLAGS}"  -o skupper ./cmd/skupper

build-bootstrap:
	GOOS=${GOOS} GOARCH=${GOARCH} go build -ldflags="${LDFLAGS}"  -o bootstrap ./cmd/bootstrap

build-controller:
	go build -ldflags="${LDFLAGS}"  -o controller cmd/controller/main.go cmd/controller/controller.go

build-config-sync:
	GOOS=${GOOS} GOARCH=${GOARCH} go build -ldflags="${LDFLAGS}"  -o config-sync cmd/config-sync/main.go cmd/config-sync/config_sync.go cmd/config-sync/collector.go

build-network-console-collector:
	GOOS=${GOOS} GOARCH=${GOARCH} go build -ldflags="${LDFLAGS}"  -o network-console-collector ./cmd/network-console-collector

build-manifest:
	go build -ldflags="${LDFLAGS}"  -o manifest ./cmd/manifest

build-doc-generator:
	GOOS=${GOOS} GOARCH=${GOARCH} go build -ldflags="${LDFLAGS}"  -o generate-doc ./internal/cmd/generate-doc

## Multiplatform build with buildx always push
# overwrite REGISTRY
docker-buildx-push: docker-buildx-controller docker-buildx-config-sync docker-buildx-network-console-collector docker-buildx-bootstrap
docker-buildx-controller:
	${DOCKER} buildx build --push --platform ${PLATFORMS} -t ${CONTROLLER_IMAGE} -f Dockerfile.controller .

docker-buildx-config-sync:
	${DOCKER} buildx build --push --platform ${PLATFORMS} -t ${CONFIG_SYNC_IMAGE} -f Dockerfile.config-sync .

docker-buildx-network-console-collector:
	${DOCKER} buildx build --push --platform ${PLATFORMS} -t ${NETWORK_CONSOLE_COLLECTOR_IMAGE} -f Dockerfile.network-console-collector .

docker-buildx-bootstrap:
	${DOCKER} buildx build --push --platform ${PLATFORMS} -t ${BOOTSTRAP_IMAGE} -f Dockerfile.bootstrap .

## Local/native container builds
docker-build: docker-build-controller docker-build-config-sync docker-build-bootstrap docker-build-network-console-collector

docker-build-controller:
	${DOCKER} build -t ${CONTROLLER_IMAGE} -f Dockerfile.controller .

docker-build-config-sync:
	${DOCKER} build -t ${CONFIG_SYNC_IMAGE} -f Dockerfile.config-sync .

docker-build-bootstrap:
	${DOCKER}  build -t ${BOOTSTRAP_IMAGE} -f Dockerfile.bootstrap .

docker-build-network-console-collector:
	${DOCKER} build -t ${NETWORK_CONSOLE_COLLECTOR_IMAGE} -f Dockerfile.network-console-collector .

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

clean:
	rm -rf skupper controller release config-sync manifest bootstrap network-console-collector

package: release/windows.zip release/darwin.zip release/linux.tgz release/s390x.tgz release/arm64.tgz

release/linux.tgz: release/linux/skupper
	tar -czf release/linux.tgz -C release/linux/ skupper

release/linux/skupper: cmd/skupper/skupper.go
	GOOS=linux GOARCH=amd64 go build -ldflags="${LDFLAGS}" -o release/linux/skupper ./cmd/skupper

release/windows/skupper: cmd/skupper/skupper.go
	GOOS=windows GOARCH=amd64 go build -ldflags="${LDFLAGS}" -o release/windows/skupper ./cmd/skupper

release/windows.zip: release/windows/skupper
	zip -j release/windows.zip release/windows/skupper

release/darwin/skupper: cmd/skupper/skupper.go
	GOOS=darwin GOARCH=amd64 go build -ldflags="${LDFLAGS}" -o release/darwin/skupper ./cmd/skupper

release/darwin.zip: release/darwin/skupper
	zip -j release/darwin.zip release/darwin/skupper

generate-manifest: build-manifest
	./manifest

generate-doc: build-doc-generator
	./generate-doc ./doc/cli

release/s390x/skupper: cmd/skupper/skupper.go
	GOOS=linux GOARCH=s390x go build -ldflags="${LDFLAGS}" -o release/s390x/skupper ./cmd/skupper

release/s390x.tgz: release/s390x/skupper
	tar -czf release/s390x.tgz release/s390x/skupper

release/arm64/skupper: cmd/skupper/skupper.go
	GOOS=linux GOARCH=arm64 go build -ldflags="${LDFLAGS}" -o release/arm64/skupper ./cmd/skupper

release/arm64.tgz: release/arm64/skupper
	tar -czf release/arm64.tgz release/arm64/skupper
