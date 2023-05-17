#!/usr/bin/env bash

set -euxo pipefail

PRODUCTION_RELEASE=${PRODUCTION_RELEASE:-false}
PRODSOURCE=${PRODSOURCE:-redhat-operators}
VMS_NAMESPACE=vmsns

function cleanup() {
    rv=$?
    if [ "x$rv" != "x0" ]; then
        echo "Error during upgrade: exit status: $rv"
        make dump-state
        echo "*** Upgrade test failed ***"
    fi
    exit $rv
}

trap "cleanup" INT TERM EXIT

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "OCP_VERSION: $OCP_VERSION"


if [ "$PRODUCTION_RELEASE" = "true" ]; then
    oc get secret/pull-secret -n openshift-config --template='{{index .data ".dockerconfigjson" | base64decode}}' > config.json
    oc image extract --confirm  "$(oc get catalogsource -n openshift-marketplace "$PRODSOURCE" -o jsonpath='{.spec.image}')" --path database/index.db:. --registry-config=config.json
    CNVVERSIONS=$(sqlite3 -list index.db 'select operatorbundle.name, operatorbundle.replaces from package, channel, operatorbundle where package.name="kubevirt-hyperconverged" and package.name=channel.package_name and channel.name=package.default_channel and head_operatorbundle_name=operatorbundle.name;')
    OLD_CSV=${CNVVERSIONS/*|}
    NEW_CSV=${CNVVERSIONS/|*}
    STARTINGCSV="  startingCSV: ${OLD_CSV}"
else
    eval "$(jq -r '."'"$OCP_VERSION"'" | to_entries[] | .key+"="+.value' version-mapping.json)"
    # These variables are set when the eval above is executed
    # shellcheck disable=SC2154
    echo "Using index_image: $index_image"
    # shellcheck disable=SC2154
    echo "Using bundle_version: $bundle_version"
    oc image extract -a /tmp/authfile.new $index_image --confirm --path configs/kubevirt-hyperconverged/catalog.json:. --path database/index.db:.
    NEW_CSV_VERSION=${bundle_version%-*}
    NEW_CSV_VERSION=${NEW_CSV_VERSION/.rhel9/}
    NEW_CSV="kubevirt-hyperconverged-operator.${NEW_CSV_VERSION}"
    if [[ -f "catalog.json" ]]; then
      echo "FBC based Index Image"
      OLD_CSV=$(cat catalog.json | jq -r ". | select(.schema==\"olm.channel\" and .name==\"stable\") | .entries[] | select(.name==\"${NEW_CSV}\").replaces")
    else
      echo "DB based Index Image"
      OLD_CSV=$(sqlite3 -list index.db "select operatorbundle.replaces from operatorbundle where operatorbundle.name=\"${NEW_CSV}\";")
    fi
    STARTINGCSV="  startingCSV: ${OLD_CSV}"
    echo "Upgrading from ${OLD_CSV} to ${NEW_CSV}"
fi

#===================
# Deploy initial HCO
#===================

echo "creating $TARGET_NAMESPACE namespace"
oc create ns "$TARGET_NAMESPACE"

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

if [ "$PRODUCTION_RELEASE" = "true" ]; then
    echo "installing kubevirt-hyperconverged using the version replaced by the head of the stable channel: ${OLD_CSV}"
    INITIALSOURCE=${PRODSOURCE}
else
    echo "installing ${OLD_CSV} from brew registry"
    
    echo "setting up brew catalog source"
    "$SCRIPT_DIR"/create-brew-catalogsource.sh

    INITIALSOURCE=brew-catalog-source
fi

echo "creating subscription"
oc create -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: ${TARGET_NAMESPACE}
  labels:
    operators.coreos.com/kubevirt-hyperconverged.openshift-cnv: ''
spec:
  channel: stable
  installPlanApproval: Manual
  name: kubevirt-hyperconverged
  source: ${INITIALSOURCE}
  sourceNamespace: openshift-marketplace
${STARTINGCSV}
EOF

HCO_SUBSCRIPTION=$(oc get subscription -n "${TARGET_NAMESPACE}" -o name)

echo "Wait up to 5 minutes for the new installPlan to appear, and approve it to begin install"
INSTALL_PLAN_APPROVED=false
for _ in $(seq 1 60); do
    INSTALL_PLAN=$(oc -n "${TARGET_NAMESPACE}" get "${HCO_SUBSCRIPTION}" -o jsonpath='{.status.installplan.name}' || true)
    if [[ -n "${INSTALL_PLAN}" ]]; then
      oc -n "${TARGET_NAMESPACE}" patch installPlan "${INSTALL_PLAN}" --type merge --patch '{"spec":{"approved":true}}'
      INSTALL_PLAN_APPROVED=true
      break
    fi
    sleep 5
done

[[ "${INSTALL_PLAN_APPROVED}" = true ]]

echo "check the package manifest"
oc describe packagemanifest kubevirt-hyperconverged || true

echo "waiting for HyperConverged operator to become ready"
"$SCRIPT_DIR"/wait-for-hco.sh

echo "----- Get virtctl"

# TODO: avoid fetching the upstream virtctl once the downstream one will
# be packaged for the disconnected use case
OPERATOR_VERSION=$(oc get kubevirt.kubevirt.io/kubevirt-kubevirt-hyperconverged -n "${TARGET_NAMESPACE}" -o=jsonpath="{.status.operatorVersion}")
UPSTREAM_KV_VERSION="${OPERATOR_VERSION%%-*}"
ARCH=$(uname -s | tr "[:upper:]" "[:lower:]")-$(uname -m | sed 's/x86_64/amd64/') || windows-amd64.exe
echo "${ARCH}"
### TODO: remove this once we can consume only kubevirt >= v0.55.0
# --local-ssh-opts needed to bypass host check is available only starting with kubevirt v0.55.0
if [[ "$OCP_VERSION" == "4.10" || "$OCP_VERSION" == "4.11" ]];
then
   UPSTREAM_KV_VERSION=v0.55.0
fi
###
curl -L -o ~/virtctl https://github.com/kubevirt/kubevirt/releases/download/"${UPSTREAM_KV_VERSION}"/virtctl-"${UPSTREAM_KV_VERSION}"-"${ARCH}"
chmod +x ~/virtctl


echo "----- Create a simple VM on the previous version cluster, before the upgrade"
oc create namespace ${VMS_NAMESPACE}
ssh-keygen -f ./hack/test_ssh -q -N ""
cat << END > ./hack/cloud-init.sh
#!/bin/sh
export NEW_USER="cirros"
export SSH_PUB_KEY="$(cat ./hack/test_ssh.pub)"
sudo mkdir /home/\${NEW_USER}/.ssh
sudo echo "\${SSH_PUB_KEY}" > /home/\${NEW_USER}/.ssh/authorized_keys
sudo chown -R \${NEW_USER}: /home/\${NEW_USER}/.ssh
sudo chmod 600 /home/\${NEW_USER}/.ssh/authorized_keys
END

oc create secret -n ${VMS_NAMESPACE} generic testvm-secret --from-file=userdata=./hack/cloud-init.sh
oc apply -n ${VMS_NAMESPACE} -f ./hack/vm.yaml
oc get vm -n ${VMS_NAMESPACE} -o yaml testvm
~/virtctl start testvm -n ${VMS_NAMESPACE}
"$SCRIPT_DIR"/retry.sh 30 10 "oc get vmi -n ${VMS_NAMESPACE} testvm -o jsonpath='{ .status.phase }' | grep 'Running'"
oc get vmi -n ${VMS_NAMESPACE} -o yaml testvm

source ./hack/check-uptime.sh
sleep 5
INITIAL_BOOTTIME=$(check_uptime 10 60)

#=======================================
# Upgrade HCO to latest build from brew
#=======================================

echo "waiting for the previous CSV installation to complete"
"$SCRIPT_DIR"/retry.sh 60 10 "oc get ClusterServiceVersion $OLD_CSV -n \"$TARGET_NAMESPACE\" -o jsonpath='{.status.phase}' | grep 'Succeeded'"

OLD_INSTALL_PLAN=$(oc get installplan -n "${TARGET_NAMESPACE}" | grep "${OLD_CSV}" | cut -d" " -f1)
NEW_INSTALL_PLAN=$(oc get installplan -n "${TARGET_NAMESPACE}" | grep "${NEW_CSV}" | cut -d" " -f1)

oc get -n "${TARGET_NAMESPACE}" installplans

echo "Wait up to 5 minutes for the new installPlan to appear, and approve it to begin upgrade"
INSTALL_PLAN_APPROVED=false
for _ in $(seq 1 60); do
    INSTALL_PLAN=$(oc -n "${TARGET_NAMESPACE}" get "${HCO_SUBSCRIPTION}" -o jsonpath='{.status.installplan.name}' || true)
    if [[ "${INSTALL_PLAN}" != "${OLD_INSTALL_PLAN}" ]]; then
      oc -n "${TARGET_NAMESPACE}" patch installPlan "${INSTALL_PLAN}" --type merge --patch '{"spec":{"approved":true}}'
      INSTALL_PLAN_APPROVED=true
      break
    fi
    sleep 5
done

[[ "${INSTALL_PLAN_APPROVED}" = true ]]

echo "waiting for HyperConverged operator to become ready"
"$SCRIPT_DIR"/wait-for-hco.sh

echo "waiting for the subscription's installedCSV to move to the new catalog source"
"$SCRIPT_DIR"/retry.sh 60 10 "oc get subscription kubevirt-hyperconverged -n \"$TARGET_NAMESPACE\" -o jsonpath='{.status.currentCSV}' | grep \"$NEW_CSV\""

# oc currently fails if the resource doesn't exist while the command is executed;
# this will be resolved in kubectl v1.21: https://github.com/kubernetes/kubernetes/pull/96702
# till then, we manually test for 404 in the output string (both with v1.20 and pre-v.120 formats)
echo "waiting for the previous CSV to be completely removed"
WAIT_CSV_OUTPUT=$(oc wait ClusterServiceVersion "$OLD_CSV" -n "$TARGET_NAMESPACE" --for delete --timeout=20m 2>&1)
# shellcheck disable=SC2181
if [ $? -ne 0 ] && ! grep -qE "NotFound|(no matching resources found)" <(echo "$WAIT_CSV_OUTPUT"); then
  echo "$WAIT_CSV_OUTPUT"
  exit 1
fi
echo "$WAIT_CSV_OUTPUT"

echo "----- Make sure that the VM is still running, after the upgrade"
oc get vm -n "${VMS_NAMESPACE}" -o yaml testvm
oc get vmi -n "${VMS_NAMESPACE}" -o yaml testvm
oc get vmi -n "${VMS_NAMESPACE}" testvm -o jsonpath='{ .status.phase }' | grep 'Running'

CURRENT_BOOTTIME=$(check_uptime 10 60)

if ((INITIAL_BOOTTIME - CURRENT_BOOTTIME > 3)) || ((CURRENT_BOOTTIME - INITIAL_BOOTTIME > 3)); then
    echo "ERROR: The test VM got restarted during the upgrade process."
    exit 1
else
    echo "The test VM survived the upgrade process."
fi

~/virtctl stop testvm -n "${VMS_NAMESPACE}"
oc delete vm -n "${VMS_NAMESPACE}" testvm
oc delete ns "${VMS_NAMESPACE}"

# The previous CSV get deleted with "background deletion" propagation
# policy, i.e. before its owned resources are completely removed.
# Therefore, we wait for a few more minutes to let these resources be
# completely deleted, to avoid any conflicts in the subsequent test execution.
echo "waiting for residual resources to complete deletion"
sleep 10m

echo "HyperConverged operator upgrade successfully completed"
