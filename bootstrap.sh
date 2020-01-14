#!/usr/bin/env bash

echo "Bootstrapping"

HCO_REGISTRY_IMAGE='quay.io/openshift-cnv-dev/container-native-virtualization-hco-bundle-registry:v2.2.0-185'
HCO_VERSION='2.2.0'
HCO_CHANNEL='2.2'
TARGET_NAMESPACE='openshift-cnv'
CMD='oc'
unset NAMESPACE

function status(){
    sleep 300
    "$CMD" get hco -n "$TARGET_NAMESPACE" -o yaml || true
    "$CMD" get pods -n "$TARGET_NAMESPACE" || true
    "$CMD" get hco hyperconverged-cluster -n "$TARGET_NAMESPACE" -o=jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.message}{"\n"}{end}' || true
    # Get logs of all the pods
    for PNAME in $( $CMD get pods -n $TARGET_NAMESPACE --field-selector=status.phase!=Running -o custom-columns=:metadata.name )
    do
      echo -e "\n--- $PNAME ---"
      $CMD describe pod -n $TARGET_NAMESPACE $PNAME || true
    done
}

curl https://raw.githubusercontent.com/kubevirt/hyperconverged-cluster-operator/master/deploy/deploy_imageregistry.sh | \
HCO_REGISTRY_IMAGE=$HCO_REGISTRY_IMAGE \
HCO_VERSION=$HCO_VERSION \
HCO_CHANNEL=$HCO_CHANNEL \
TARGET_NAMESPACE=$TARGET_NAMESPACE \
KVM_EMULATION=true \
bash -x

trap status EXIT
