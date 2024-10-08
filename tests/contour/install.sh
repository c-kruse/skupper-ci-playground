#!/usr/bin/env bash

kind create cluster -n contour --wait 60s

helm repo add metallb https://metallb.github.io/metallb

helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace -f metallb-values.yaml --wait

cluster=1
kind_ip=$(docker network inspect -f '{{.IPAM.Config}}' kind | awk '/.*/ { print $2 }')
start_ip=$(echo "$kind_ip" | cut -f1-2 -d'.')."${cluster_number[$cluster]}".100
end_ip=$(echo "$start_ip" | cut -f1-3 -d'.').250

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

kubectl apply -f https://raw.githubusercontent.com/projectcontour/contour/release-1.30/examples/render/contour-gateway-provisioner.yaml
kubectl apply -f ./resources/gatewayclass.yaml
helm upgrade --install skupper-controller oci://quay.io/ckruse/skupper-charts/skupper --namespace skupper --create-namespace  -f skupper-values.yaml
