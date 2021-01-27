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
$SCRIPT_DIR/wait_for_hco.sh

#=======================================
# Upgrade HCO to latest build from brew
#=======================================

OLD_CSV=$(oc get subscription kubevirt-hyperconverged -n $TARGET_NAMESPACE -o jsonpath="{.status.installedCSV}")

while [ $(oc get ClusterServiceVersion $OLD_CSV -n $TARGET_NAMESPACE -o jsonpath="{.status.phase}") != "Succeeded" ]; do
	echo "waiting for the previous CSV installation to complete"
	sleep 10
done

echo "setting up brew catalog source"
$SCRIPT_DIR/create_brew_catalogsource.sh

echo "patching the subscription to switch to the brew catalog source"
oc patch subscription kubevirt-hyperconverged -n $TARGET_NAMESPACE --type=merge --patch='{"spec": {"source": "brew-catalog-source"}}'

echo "waiting for the new CSV installation to commence"
sleep 60

echo "waiting for the subscription's currentCSV to move to the new catalog source"
while true; do
  CURRENT_CSV=$(oc get subscription kubevirt-hyperconverged -n $TARGET_NAMESPACE -o jsonpath="{.status.currentCSV}")
  if [ "$CURRENT_CSV" != "$OLD_CSV"]; then
    NEW_CSV=$CURRENT_CSV
    break
  fi

  echo "waiting for the subscription's currentCSV to move to the new catalog source"
  sleep 10
done

echo "waiting for HyperConverged operator to become ready"
$SCRIPT_DIR/wait_for_hco.sh

echo "waiting for the subscription's installedCSV to move to the new catalog source"
while true; do
  INSTALLED_CSV=$(oc get subscription kubevirt-hyperconverged -n $TARGET_NAMESPACE -o jsonpath="{.status.installedCSV}")
  if [ "$INSTALLED_CSV" = "$CURRENT_CSV" ]; then
    break
  fi

  echo "waiting for the subscription's installedCSV to move to the new catalog source"
  sleep 30
done

echo "HyperConverged operator upgrade successfully completed"
