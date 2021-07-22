#!/usr/bin/env bash

set -euxo pipefail

function cleanup() {
    rv=$?
    if [ "x$rv" != "x0" ]; then
        echo "Error during deployment: exit status: $rv"
        make dump-state
        echo "*** CNV deployment failed ***"
    fi
    exit $rv
}

trap "cleanup" INT TERM EXIT

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "OCP_VERSION: $OCP_VERSION"

eval "$(jq -r '."'"$OCP_VERSION"'" | to_entries[] | .key+"="+.value' version-mapping.json)"

# These variables are set when the eval above is executed
# shellcheck disable=SC2154
echo "Using index_image: $index_image"
# shellcheck disable=SC2154
echo "Using bundle_version: $bundle_version"

echo "setting up brew catalog source"
$SCRIPT_DIR/create-brew-catalogsource.sh

oc create ns "${TARGET_NAMESPACE}"

STARTING_CSV=${bundle_version%-*}
echo "creating subscription"
oc create -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: "${TARGET_NAMESPACE}"
  labels:
    operators.coreos.com/kubevirt-hyperconverged.openshift-cnv: ''
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: brew-catalog-source
  sourceNamespace: openshift-marketplace
  startingCSV: kubevirt-hyperconverged-operator.${STARTING_CSV}
EOF

echo "creating operator group"
oc create -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "openshift-cnv-group"
  namespace: "${TARGET_NAMESPACE}"
spec:
  targetNamespaces:
  - "${TARGET_NAMESPACE}"
EOF

echo "waiting for HyperConverged operator to become ready"
$SCRIPT_DIR/wait-for-hco.sh
