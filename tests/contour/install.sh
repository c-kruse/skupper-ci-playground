#!/usr/bin/env bash

kind create cluster -n contour --wait 60s

helm repo add metallb https://metallb.github.io/metallb

helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace -f metallb-values.yaml --wait
helm upgrade --install lb-config ./_chart/lb-config/ --namespace metallb-system   --set ipAddresses="172.18.255.0/28" --wait

kubectl apply -f https://raw.githubusercontent.com/projectcontour/contour/release-1.30/examples/render/contour-gateway-provisioner.yaml
kubectl apply -f ./resources/gatewayclass.yaml
helm upgrade --install skupper-controller oci://quay.io/ckruse/skupper-charts/skupper --namespace skupper --create-namespace  -f skupper-values.yaml
