#!/usr/bin/env bash

if [[ "${KUBEVIRT_RELEASE}" =~ 0.34 ]]; then
    echo "Skipping scaling down the hco-operator pod due to older version"
    exit 0
fi

set -euxo pipefail

echo "scale down hco-operator, as it's still using the config map for KubeVirt"
oc patch deployment hco-operator -n "${TARGET_NAMESPACE}" --patch '{"spec":{"replicas":0}}'

echo "waiting for hco-operator pod to be scaled down"
while [ "$(oc get pods --no-headers -l name=hyperconverged-cluster-operator -n openshift-cnv | wc -l)" -gt 0 ]; do
    sleep 5
done

echo "deleting kubevirt configmap"
if [ "$(oc get configmap kubevirt-config -n "${TARGET_NAMESPACE}" --no-headers | wc -l)" -gt 0 ]; then
    oc delete configmap kubevirt-config -n "${TARGET_NAMESPACE}"
fi
