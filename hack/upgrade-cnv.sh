#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "OCP_VERSION: $OCP_VERSION"

eval "$(jq -r '."'"$OCP_VERSION"'" | to_entries[] | .key+"="+.value' version-mapping.json)"

# These variables are set when the eval above is executed
# shellcheck disable=SC2154
echo "Using index_image: $index_image"
# shellcheck disable=SC2154
echo "Using bundle_version: $bundle_version"

#==========================================
# Deploy HCO using latest released version
#==========================================

echo "creating $TARGET_NAMESPACE namespace"
oc create ns $TARGET_NAMESPACE

echo "creating operator group"
oc create -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cnv-group
  namespace: $TARGET_NAMESPACE
spec:
  targetNamespaces:
  - $TARGET_NAMESPACE
EOF

echo "installing kubevirt-hyperconverged using latest stable release"

echo "creating subscription"
oc create -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: $TARGET_NAMESPACE
  labels:
    operators.coreos.com/kubevirt-hyperconverged.openshift-cnv: ''
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "waiting for HyperConverged operator to become ready"
$SCRIPT_DIR/wait-for-hco.sh

#=======================================
# Upgrade HCO to latest build from brew
#=======================================

OLD_CSV=$(oc get subscription kubevirt-hyperconverged -n $TARGET_NAMESPACE -o jsonpath="{.status.installedCSV}")

echo "waiting for the previous CSV installation to complete"
$SCRIPT_DIR/retry.sh 60 10 "oc get ClusterServiceVersion $OLD_CSV -n $TARGET_NAMESPACE -o jsonpath='{.status.phase}' | grep 'Succeeded'"

echo "setting up brew catalog source"
$SCRIPT_DIR/create-brew-catalogsource.sh

echo "patching the subscription to switch to the brew catalog source"
oc patch subscription kubevirt-hyperconverged -n $TARGET_NAMESPACE --type=merge --patch='{"spec": {"source": "brew-catalog-source"}}'

echo "waiting for the subscription's currentCSV to move to the new catalog source"
$SCRIPT_DIR/retry.sh 30 10 "oc get subscription kubevirt-hyperconverged -n $TARGET_NAMESPACE -o jsonpath='{.status.currentCSV}' | grep -v $OLD_CSV"

NEW_CSV=$(oc get subscription kubevirt-hyperconverged -n $TARGET_NAMESPACE -o jsonpath='{.status.currentCSV}')

echo "waiting for HyperConverged operator to become ready"
$SCRIPT_DIR/wait-for-hco.sh

echo "waiting for the subscription's installedCSV to move to the new catalog source"
$SCRIPT_DIR/retry.sh 60 10 "oc get subscription kubevirt-hyperconverged -n $TARGET_NAMESPACE -o jsonpath='{.status.currentCSV}' | grep $NEW_CSV"

# oc currently fails if the resource doesn't exist while the command is executed;
# this will be resolved in kubectl v1.21: https://github.com/kubernetes/kubernetes/pull/96702
# till then, we manually test for 404 in the output string (both with v1.20 and pre-v.120 formats)
echo "waiting for the previous CSV to be completely removed"
WAIT_CSV_OUTPUT=$(oc wait ClusterServiceVersion $OLD_CSV -n $TARGET_NAMESPACE --for delete --timeout=10m 2>&1)
if [ $? -ne 0 ] && ! grep -qE "NotFound|(no matching resources found)" <(echo "$WAIT_CSV_OUTPUT"); then
  echo "$WAIT_CSV_OUTPUT"
  exit 1
fi
echo "$WAIT_CSV_OUTPUT"

# The previous CSV get deleted with "background deletion" propagation
# policy, i.e. before its owned resources are completely removed.
# Therefore, we wait for a few more minutes to let these resources be
# completely deleted, to avoid any conflicts in the subsequent test execution.
echo "waiting for residual resources to complete deletion"
sleep 10m

echo "HyperConverged operator upgrade successfully completed"
