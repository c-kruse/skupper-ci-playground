#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

export KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-skupper-dev}
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kind-config-$KIND_CLUSTER_NAME}"
kind_ip=$(docker network inspect -f '{{.IPAM.Config}}' kind | awk '/.*/ { print $2 }')
interface=$(ip -br -4 a | grep "${kind_ip}" | awk '{print $1}')
testdomain="${KIND_CLUSTER_NAME}.testing"
node_ip=$(docker inspect "${KIND_CLUSTER_NAME}"-control-plane -f '{{.NetworkSettings.Networks.kind.IPAddress}}')


kube_get_ingress_svc="kubectl --kubeconfig=${KUBECONFIG} get svc -n ingress-nginx ingress-nginx-controller"
kube_gateway_svc="kubectl --kubeconfig=${KUBECONFIG} get svc -n skupper envoy-skupper"
timeout 10s \
		bash -c \
		"until ${kube_get_ingress_svc} --output=jsonpath='{.status.loadBalancer}' | grep ingress; do : ; done"
timeout 10s \
		bash -c \
		"until ${kube_gateway_svc} --output=jsonpath='{.status.loadBalancer}' | grep ingress; do : ; done"

nginx_ip=$(bash -c "$kube_get_ingress_svc -ojsonpath='{.status.loadBalancer.ingress[0].ip}'")
gateway_ip=$(bash -c "$kube_gateway_svc -ojsonpath='{.status.loadBalancer.ingress[0].ip}'")

docker run --rm -it -d --name "${KIND_CLUSTER_NAME}-dns" \
		-p 53/udp docker.io/debian:bookworm \
		bash -c "apt-get update -y && apt-get install -y dnsmasq \
		&& dnsmasq -d -z --expand-hosts --log-queries \
		--local=/${testdomain}/ \
		--domain=${testdomain} \
		--address=/${testdomain}/${node_ip} \
		--address=/nginx-ingress.${testdomain}/${nginx_ip} \
		--address=/gateway.${testdomain}/${gateway_ip}"

port=$(docker port skupper-dev-dns  | awk -F ":" '{print $2; exit}')

dig "x.$testdomain" @127.0.0.1 -p "$port" && \
        sudo resolvectl domain "$interface" ~"$testdomain" && \
        sudo resolvectl dns "$interface" "127.0.0.1:$port"

echo "To rollback: run sudo resolvectl revert $interface"
