#! /usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

readonly CLUSTER=${CLUSTER:-skupper-dev}
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kind-config-$CLUSTER}"
kind_ip=$(docker network inspect -f '{{.IPAM.Config}}' kind | awk '/.*/ { print $2 }')
interface=$(ip -br -4 a | grep "${kind_ip}" | awk '{print $1}')
testdomain="${CLUSTER}.testing"
node_ip=$(docker inspect "${CLUSTER}"-control-plane -f '{{.NetworkSettings.Networks.kind.IPAddress}}')

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

echo "= Starting dnsmasq"

docker pull docker.io/alpine:latest
docker run --rm -it -d --name "${CLUSTER}-dns" \
		-p 53/udp docker.io/alpine:latest \
		sh -c "apk add dnsmasq \
		&& dnsmasq -d -z --expand-hosts --log-queries \
		--local=/${testdomain}/ \
		--domain=${testdomain} \
		--address=/${testdomain}/${node_ip} \
		--address=/nginx-ingress.${testdomain}/${nginx_ip} \
		--address=/gateway.${testdomain}/${gateway_ip}"

until [ "$(docker inspect -f "{{.State.Running}}" "${CLUSTER}-dns")" == "true" ]; do
    sleep 0.1;
done;

port=$(docker port "${CLUSTER}-dns"  | awk -F ":" '{print $2; exit}')

echo "= Waiting for dnsmasq container on ${port}"
until dig "x.$testdomain" @127.0.0.1 -p "$port"; do
		sleep 1;
done;


echo "= Updating local resolver configuration"
sudo resolvectl domain "$interface" ~"$testdomain"
sudo resolvectl dns "$interface" "127.0.0.1:$port"
echo "To rollback: run sudo resolvectl revert $interface"
