#!/usr/bin/env bash

set -euo pipefail

#
echo "waiting for operator pods to be created"
while [ "$(oc get pods -n "${TARGET_NAMESPACE}" --no-headers | wc -l)" -lt 5 ]; do
    sleep 5
done

counter=3
for i in $(seq 1 $counter); do
    echo "waiting for operator pods to be ready (try $i)"
    oc wait pods -n "${TARGET_NAMESPACE}" --all --for condition=Ready --timeout=10m && break
    sleep 5
done

echo "waiting for hco-operator and hco-webhook to be ready"
oc wait deployment hco-operator hco-webhook --for condition=Available -n "${TARGET_NAMESPACE}" --timeout="20m"

# Wait a few more seconds for the hco-webhook Service and Endpoints objects
# to be updated and propagated through the system, to prevent connection errors to the webhook.
sleep 20s

echo "waiting for HyperConverged operator CRD to be created"
while [ "$(oc get crd -n "${TARGET_NAMESPACE}" hyperconvergeds.hco.kubevirt.io --no-headers | wc -l)" -eq 0 ]; do
    sleep 5
done

echo "checking if HyperConverged operator CR already exists"
if [ "$(oc get HyperConverged kubevirt-hyperconverged -n "${TARGET_NAMESPACE}" --no-headers | wc -l)" -eq 0 ]; then

	echo "creating HyperConverged operator CR"
	
	oc create -f - <<EOF
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: "${TARGET_NAMESPACE}"
spec:
  BareMetalPlatform: true
EOF

fi

if [[ "${KUBEVIRT_RELEASE}" =~ 0.34 ]]; then
  echo "checking KubeVirt config map already exists"
  if [ "$(oc get ConfigMap kubevirt-config -n "${TARGET_NAMESPACE}" --no-headers | wc -l)" -eq 0 ]; then
    echo "creating KubeVirt config map"
    oc create -n "${TARGET_NAMESPACE}" -f "https://storage.googleapis.com/kubevirt-prow/devel/release/kubevirt/kubevirt/v0.34.2/manifests/testing/kubevirt-config.yaml"
  fi
fi

echo "waiting for HyperConverged operator to be available"
oc wait -n "${TARGET_NAMESPACE}" HyperConverged kubevirt-hyperconverged --for condition=Available --timeout=20m
