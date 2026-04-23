#!/usr/bin/env bash

set -euxo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

HCO_KIND="HyperConverged"
HCO_CR="kubevirt-hyperconverged"

echo "waiting for hco-operator deployment to be created"
$SCRIPT_DIR/retry.sh 30 10 "oc get deployment hco-operator -n ${TARGET_NAMESPACE}"

echo "waiting for hco-webhook deployment to be created"
$SCRIPT_DIR/retry.sh 30 10 "oc get deployment hco-webhook -n ${TARGET_NAMESPACE}"

echo "waiting for hco-operator and hco-webhook to be ready"
oc wait deployment hco-operator hco-webhook -n ${TARGET_NAMESPACE} --for condition=Available --timeout=30m

# Wait a few more seconds for the hco-webhook Service and Endpoints objects
# to be updated and propagated through the system, to prevent connection errors to the webhook.
sleep 20s

echo "waiting for HyperConverged operator CRD to be created"
$SCRIPT_DIR/retry.sh 30 10 "oc get crd hyperconvergeds.hco.kubevirt.io"

echo "checking if HyperConverged operator CR already exists"
if [ "$(oc get "${HCO_KIND}" "${HCO_CR}" -n ${TARGET_NAMESPACE} --no-headers | wc -l)" -eq 0 ]; then

	echo "creating HyperConverged operator CR"

	oc create -f - <<EOF
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: ${HCO_CR}
  namespace: ${TARGET_NAMESPACE}
spec:
  BareMetalPlatform: true
EOF

fi

echo "waiting for HyperConverged operator to be available"
oc wait "${HCO_KIND}" "${HCO_CR}" -n ${TARGET_NAMESPACE} --for condition=Available --timeout=30m

echo "Enable KubeVirt RebootPolicy feature gate (interop e2e exercises reboot policy specs)."
oc annotate "${HCO_KIND}" "${HCO_CR}" \
  --namespace="${TARGET_NAMESPACE}" \
  --overwrite \
  kubevirt.kubevirt.io/jsonpatch='[
    {"op": "add", "path": "/spec/configuration/developerConfiguration/featureGates/-", "value": "RebootPolicy"}
  ]'

echo "waiting for HyperConverged operator to be available (again)"
oc wait "${HCO_KIND}" "${HCO_CR}" -n "${TARGET_NAMESPACE}" --for=condition=Available --timeout=15m
