#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

DEBUG=${DEBUG:=false}

if [ "${DEBUG}" = "true" ]; then
  set -x
fi

cat << EOF > site_vet_resources.yaml
---
apiVersion: skupper.io/v1alpha1
kind: AccessGrant
metadata:
  name: vet-grant
spec:
  redemptionsAllowed: 5
  expirationWindow: 10m
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: vet-service
  name: vet-service
spec:
  selector:
    matchLabels:
      app: vet-service
  template:
    metadata:
      labels:
        app: vet-service
    spec:
      containers:
      - image: quay.io/skupper/hello-world-backend
        name: hello-world-backend
---
apiVersion: skupper.io/v1alpha1
kind: Connector
metadata:
  name: vet-service
spec:
  port: 8080
  routingKey: vet-svc
  selector: app=vet-service
  type: tcp

EOF

kubectl apply -f site_vet_resources.yaml

kubectl wait --for=condition=ready accessgrant/vet-grant 

tmpdir=$(mktemp -d)
pushd "$tmpdir"
kubectl get accessgrant vet-grant -o yaml > tmpfile
URL=$(yq '.status.url' < tmpfile)
CODE=$(yq '.status.code' < tmpfile)
cat >site.yaml <<EOF
---
apiVersion: skupper.io/v1alpha1
kind: Site
metadata:
  name: vet-site
spec:
---
apiVersion: skupper.io/v1alpha1
kind: Listener
metadata:
  name: vet-svc
spec:
  routingKey: vet-svc
  port: 9678
  host: 127.0.0.1
---
apiVersion: skupper.io/v1alpha1
kind: AccessToken
metadata:
  name: vet-token
spec:
  url: ${URL}
  code: ${CODE}
  ca: |
EOF
cat tmpfile | yq '.status.ca' | awk '{ print "    " $0 }' >> site.yaml
rm tmpfile

curl -fsSL -o bootstrap.sh https://raw.githubusercontent.com/skupperproject/skupper/refs/heads/v2/cmd/bootstrap/bootstrap.sh
chmod 700 bootstrap.sh
curl -fsSL -o remove.sh https://raw.githubusercontent.com/skupperproject/skupper/refs/heads/v2/cmd/bootstrap/remove.sh
chmod 700 remove.sh
echo "Waiting for vet service deployment ready in Site"
kubectl wait --for=condition=ready pod -l app=vet-service
expected_pod=$(kubectl get pod -l app=vet-service --no-headers -o custom-columns=":metadata.name")
echo "Bootstrapping local site"
./bootstrap.sh -p "$(pwd)" -n vetns

echo "Waiting for local site to serve vet service"
until curl -s -f -o /dev/null "http://127.0.0.1:9678/api/hello"
do
  echo -n '.'
  sleep 1
done
echo
actual=$(curl -s http://127.0.0.1:9678/api/hello | sed -n 's/.*(\([^()]*\)).*/\1/p')
if [ "$actual" = "$expected_pod" ]; then
		echo "vet passed: got resposne from $expected_pod"
else
		echo "vet failed: got resposne from unexpected $actual"
fi

./remove.sh vetns
popd


kubectl delete -f site_vet_resources.yaml
rm site_vet_resources.yaml
