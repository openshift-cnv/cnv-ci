#!/usr/bin/env bash

set -euxo pipefail

PRODUCTION_RELEASE=${PRODUCTION_RELEASE:-false}

echo "get matching kubevirt release from the build"
VIRT_OPERATOR_IMAGE=$(oc get deployment virt-operator -n ${TARGET_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].image}' |
  sed 's|registry.redhat.io/container-native-virtualization/|brew.registry.redhat.io/rh-osbs/container-native-virtualization-|')
KUBEVIRT_TAG=$(oc image info -a /tmp/authfile.new ${VIRT_OPERATOR_IMAGE} -o json | jq '.config.config.Labels["upstream-version"]')
KUBEVIRT_RELEASE=v$(echo ${KUBEVIRT_TAG} | awk -F '-' '{print $1}' | tr -d '"')
if [[ ${KUBEVIRT_TAG} == *"rc"* ]]; then
  KUBEVIRT_TESTS_URL=https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_RELEASE}/tests.test
  if ! curl --output /dev/null --silent --head --fail "${KUBEVIRT_TESTS_URL}"; then
    # First checking if the official release exists (without "rc"). If not - use the release candidate version.
    KUBEVIRT_RELEASE=v$(echo ${KUBEVIRT_TAG} | awk -F '-' '{print $1"-"$2}' | tr -d '"')
  fi
fi

trap 'rm -rf /tmp/authfile*' EXIT SIGINT SIGTERM

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

skip_tests+=('\[QUARANTINE]')
skip_tests+=('Slirp Networking')
skip_tests+=('with CPU spec')
skip_tests+=('with TX offload disabled')
skip_tests+=('with cni flannel and ptp plugin interface')
skip_tests+=('with ovs-cni plugin')
skip_tests+=('SRIOV')
skip_tests+=('with EFI')
skip_tests+=('Operator')
skip_tests+=('GPU')
skip_tests+=('DataVolume Integration')
skip_tests+=('test_id:3468')
skip_tests+=('test_id:3466')
skip_tests+=('test_id:1015')
skip_tests+=('rfe_id:393')
skip_tests+=('test_id:4659')

# Skipping VM Rename tests, which are failing due to a bug in KMP.
skip_tests+=('test_id:4646')
skip_tests+=('test_id:4647')
skip_tests+=('test_id:4654')
skip_tests+=('test_id:4655')
skip_tests+=('test_id:4656')
skip_tests+=('test_id:4657')
skip_tests+=('test_id:4658')
skip_tests+=('test_id:4659')

# Skipping "Delete a VirtualMachineInstance with ACPI and 0 grace period seconds" due to a bug
skip_tests+=('test_id:1652')

if [ "$PRODUCTION_RELEASE" = "true" ]; then
  # Skipping flaky test for OCP Informing Jobs.
  skip_tests+=('test_id:1530')
fi

skip_regex=$(printf '(%s)|' "${skip_tests[@]}")
skip_arg=$(printf -- '--ginkgo.skip=%s' "${skip_regex:0:-1}")


mkdir -p "${ARTIFACT_DIR}"

echo "starting tests"
${TESTS_BINARY} \
    -cdi-namespace="$TARGET_NAMESPACE" \
    -config=./manifests/testing/kubevirt-testing-configuration.json \
    -installed-namespace="$TARGET_NAMESPACE" \
    -junit-output="${ARTIFACT_DIR}/junit.functest.xml" \
    -kubeconfig="$KUBECONFIG" \
    -ginkgo.focus='(rfe_id:1177)|(rfe_id:273)|(rfe_id:151)' \
    -ginkgo.noColor \
    -ginkgo.seed=0 \
    -ginkgo.slowSpecThreshold=60 \
    -ginkgo.succinct \
    -oc-path="$(which oc)" \
    -kubectl-path="$(which oc)" \
    -utility-container-prefix=quay.io/kubevirt \
    -test.timeout=2h \
    "${skip_arg}"
