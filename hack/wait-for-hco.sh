#!/usr/bin/env bash

set -euxo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "waiting for hco-operator deployment to be created"
$SCRIPT_DIR/retry.sh 30 10 "oc get deployment hco-operator -n $TARGET_NAMESPACE"

echo "waiting for hco-webhook deployment to be created"
$SCRIPT_DIR/retry.sh 30 10 "oc get deployment hco-webhook -n $TARGET_NAMESPACE"

echo "waiting for hco-operator and hco-webhook to be ready"
oc wait deployment hco-operator hco-webhook -n $TARGET_NAMESPACE --for condition=Available --timeout=30m

# Wait a few more seconds for the hco-webhook Service and Endpoints objects
# to be updated and propagated through the system, to prevent connection errors to the webhook.
sleep 20s

echo "waiting for HyperConverged operator CRD to be created"
$SCRIPT_DIR/retry.sh 30 10 "oc get crd hyperconvergeds.hco.kubevirt.io"

echo "checking if HyperConverged operator CR already exists"
if [ "$(oc get HyperConverged kubevirt-hyperconverged -n $TARGET_NAMESPACE --no-headers | wc -l)" -eq 0 ]; then

	echo "creating HyperConverged operator CR"
	
	oc create -f - <<EOF
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: $TARGET_NAMESPACE
spec:
  BareMetalPlatform: true
EOF

fi

if [[ "$KUBEVIRT_RELEASE" =~ 0.34 ]]; then
  echo "checking KubeVirt config map already exists"
  if [ "$(oc get ConfigMap kubevirt-config -n $TARGET_NAMESPACE --no-headers | wc -l)" -eq 0 ]; then
    echo "creating KubeVirt config map"

    KUBEVIRT_CONFIG_FILE="kubevirt-config.yaml"
    curl -Lo $KUBEVIRT_CONFIG_FILE "https://storage.googleapis.com/kubevirt-prow/devel/release/kubevirt/kubevirt/$KUBEVIRT_RELEASE/manifests/testing/kubevirt-config.yaml"
    sed -i "s/namespace: kubevirt/namespace: $TARGET_NAMESPACE/" $KUBEVIRT_CONFIG_FILE

    oc create -f $KUBEVIRT_CONFIG_FILE
  fi
fi

echo "waiting for HyperConverged operator to be available"
oc wait HyperConverged kubevirt-hyperconverged -n $TARGET_NAMESPACE --for condition=Available --timeout=30m
