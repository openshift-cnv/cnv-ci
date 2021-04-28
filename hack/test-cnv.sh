#!/usr/bin/env bash

set -euxo pipefail

echo "get matching kubevirt release from the build"
VIRT_OPERATOR_IMAGE=$(oc get deployment virt-operator -n ${TARGET_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].image}' |
  sed 's|registry.redhat.io/container-native-virtualization/|brew.registry.redhat.io/rh-osbs/container-native-virtualization-|')
KUBEVIRT_TAG=$(oc image info -a /tmp/authfile ${VIRT_OPERATOR_IMAGE} -o json | jq '.config.config.Labels["upstream-version"]')
KUBEVIRT_RELEASE=v$(echo ${KUBEVIRT_TAG} | awk -F '-' '{print $1}' | tr -d '"')
if [[ ${KUBEVIRT_TAG} == *"rc"* ]]; then
  KUBEVIRT_TESTS_URL=https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_RELEASE}/tests.test
  if ! curl --output /dev/null --silent --head --fail "${KUBEVIRT_TESTS_URL}"; then
    # First checking if the official release exists (without "rc"). If not - use the release candidate version.
    KUBEVIRT_RELEASE=v$(echo ${KUBEVIRT_TAG} | awk -F '-' '{print $1"-"$2}' | tr -d '"')
  fi
fi

echo "Kubevirt release in use is: ${KUBEVIRT_RELEASE}"

echo "downloading the test binary"
BIN_DIR="$(pwd)/_out" && mkdir -p "${BIN_DIR}"
export BIN_DIR

TESTS_BINARY="$BIN_DIR/tests.test"
curl -Lo "$TESTS_BINARY" "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_RELEASE}/tests.test"
chmod +x "$TESTS_BINARY"

echo "create testing infrastructure"
[ "$(oc get PersistentVolume host-path-disk-alpine)" ] || oc create -n "${TARGET_NAMESPACE}" -f ./manifests/testing/kubevirt-testing-infra.yaml

echo "waiting for testing infrastructure to be ready"
oc wait deployment cdi-http-import-server -n "${TARGET_NAMESPACE}" --for condition=Available --timeout=10m
oc wait pods -l "kubevirt.io=disks-images-provider" -n "${TARGET_NAMESPACE}" --for condition=Ready --timeout=10m

echo "starting tests"
${TESTS_BINARY} \
    -cdi-namespace="$TARGET_NAMESPACE" \
    -config=./manifests/testing/kubevirt-testing-configuration.json \
    -installed-namespace="$TARGET_NAMESPACE" \
    -junit-output="${ARTIFACTS_DIR}/junit.functest.xml" \
    -kubeconfig="$KUBECONFIG" \
    -ginkgo.focus='(rfe_id:1177)|(rfe_id:273)|(rfe_id:151)' \
    -ginkgo.noColor \
    -ginkgo.seed=0 \
    -ginkgo.skip='(Slirp Networking)|(with CPU spec)|(with TX offload disabled)|(with cni flannel and ptp plugin interface)|(with ovs-cni plugin)|(test_id:1752)|(SRIOV)|(with EFI)|(Operator)|(GPU)|(DataVolume Integration)|(test_id:3468)|(test_id:3466)|(test_id:1015)|(rfe_id:393)' \
    -ginkgo.slowSpecThreshold=60 \
    -ginkgo.succinct \
    -oc-path="$(which oc)" \
    -kubectl-path="$(which oc)" \
    -utility-container-prefix=quay.io/kubevirt \
    -test.timeout=2h
