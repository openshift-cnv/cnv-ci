#!/usr/bin/env bash

echo "Boostrapping cluster"
unset NAMESPACE
curl https://raw.githubusercontent.com/kubevirt/hyperconverged-cl
uster-operator/master/deploy/deploy_imageregistry.sh | \
HCO_REGISTRY_IMAGE=quay.io/openshift-cnv-dev/container-native-virtualization-hco-bundle-registry:v2.2.0-185 \
HCO_VERSION=2.2.0 \
HCO_CHANNEL=2.2 \
TARGET_NAMESPACE=openshift-cnv \
bash -x