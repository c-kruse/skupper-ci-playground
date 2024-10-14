#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

DEBUG=${DEBUG:=false}

if [ "${DEBUG}" = "true" ]; then
  set -x
  KIND_LOG_LEVEL="6"
fi

KIND_LOG_LEVEL="1"
export KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-skupper-dev}
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

export REGISTRY="${REGISTRY:-quay.io/skupper}"
export CONTROLLER_IMAGE_REPO="${CONTROLLER_IMAGE_REPO:-quay.io/skupper/controller}"
export CONFIG_SYNC_IMAGE_REPO="${CONFIG_SYNC_IMAGE_REPO:-quay.io/skupper/config-sync}"
export ROUTER_IMAGE_REPO="${ROUTER_IMAGE_REPO:-quay.io/skupper/skupper-router}"
export CONTROLLER_IMAGE_TAG="${CONTROLLER_IMAGE_TAG:-v2-latest}"
export CONFIG_SYNC_IMAGE_TAG="${CONFIG_SYNC_IMAGE_TAG:-v2-latest}"
export ROUTER_IMAGE_TAG="${ROUTER_IMAGE_TAG:-main}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kind-config-$KIND_CLUSTER_NAME}"
SKIP_CLUSTER_CREATION="${SKIP_CLUSTER_CREATION:-false}"
IMAGE_LOAD_STRATEGY="${IMAGE_LOAD_STRATEGY:-docker}"

if ! command -v kind --version &> /dev/null; then
  echo "kind is not installed. Use the package manager or visit the official site https://kind.sigs.k8s.io/"
  exit 1
fi

echo "Running e2e with skupper ${CONTROLLER_IMAGE_REPO}:${CONTROLLER_IMAGE_TAG}"

if [ "${SKIP_CLUSTER_CREATION}" = "false" ]; then
  echo "[dev-env] creating Kubernetes cluster with kind"

  # delete the cluster if it exists
  if kind get clusters | grep "${KIND_CLUSTER_NAME}"; then
    kind delete cluster --name "${KIND_CLUSTER_NAME}"
  fi

  kind create cluster \
    --verbosity="${KIND_LOG_LEVEL}" \
    --name "${KIND_CLUSTER_NAME}"

  echo "Kubernetes cluster:"
  kubectl get nodes -o wide
fi

kind_ip=$(docker network inspect -f '{{.IPAM.Config}}' kind | awk '/.*/ { print $2 }')
start_ip=$(echo "$kind_ip" | cut -f1-2 -d'.').200.100
end_ip=$(echo "$start_ip" | cut -f1-3 -d'.').250
testdomain="${KIND_CLUSTER_NAME}.testing"



# Preload images used in e2e tests


case "$IMAGE_LOAD_STRATEGY" in
docker)
		echo "[dev-env] copying docker images to cluster..."
		kind load docker-image --name="${KIND_CLUSTER_NAME}" \
				"${CONTROLLER_IMAGE_REPO}:${CONTROLLER_IMAGE_TAG}" \
				"${CONFIG_SYNC_IMAGE_REPO}:${CONFIG_SYNC_IMAGE_TAG}" \
				"${ROUTER_IMAGE_REPO}:${ROUTER_IMAGE_TAG}"
    ;;

archive)
		echo "[dev-env] copying archived images to cluster..."
		for archive in "${IMAGE_ARCHIVE_PATH}"/*.gz; do
				kind load image-archive --name="${KIND_CLUSTER_NAME}" "$archive";
		done
    ;;
  *)
    ;;
esac


## Install cluster dependencies
echo "[dev-env] installing dependencies..."

# metallb
helm repo add metallb https://metallb.github.io/metallb
helm upgrade --install metallb metallb/metallb \
		--namespace metallb-system --create-namespace \
		--set speaker.ignoreExcludeLB=true \
		--version 0.14.* \
		--wait



kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
  - ${start_ip}-${end_ip}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
EOF

# contour gateway
kubectl apply -f https://raw.githubusercontent.com/projectcontour/contour/release-1.30/examples/render/contour-gateway-provisioner.yaml
kubectl apply -f "${DIR}/resources/gatewayclass.yaml"


# nginx ingress
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.extraArgs.enable-ssl-passthrough=true

echo "[dev-env] installing skupper controller.."


cat << EOF | helm upgrade --install skupper-controller oci://quay.io/ckruse/skupper-charts/skupper --namespace skupper --create-namespace  --wait --values -
controller:
  repository: "${CONTROLLER_IMAGE_REPO}"
  tag: "${CONTROLLER_IMAGE_TAG}"
  pullPolicy: Never

configSyncImage:
  repository: "${CONFIG_SYNC_IMAGE_REPO}"
  tag: "${CONFIG_SYNC_IMAGE_TAG}"
  pullPolicy: Never

routerImage:
  repository: "${ROUTER_IMAGE_REPO}"
  tag: "${ROUTER_IMAGE_TAG}"
  pullPolicy: Never

access:
  enabledTypes: local,loadbalancer,nodeport,ingress-nginx,contour-http-proxy,gateway
  gateway:
    class: contour
    domain: "gateway.$testdomain"
  nodeport:
    clusterHost: "host.$testdomain"
  nginx:
    domain: "nginx-ingress.$testdomain"
  contour:
    domain: "contour.$testdomain"
EOF
