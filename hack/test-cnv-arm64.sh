#!/usr/bin/env bash

set -euxo pipefail

PRODUCTION_RELEASE=${PRODUCTION_RELEASE:-false}
KUBEVIRT_TESTING_CONFIGURATION_FILE=${KUBEVIRT_TESTING_CONFIGURATION_FILE:-'kubevirt-testing-configuration.json'}

echo "get matching kubevirt release from the build"
VIRT_OPERATOR_IMAGE=$(oc get deployment virt-operator -n ${TARGET_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].image}')

if [ "$PRODUCTION_RELEASE" = "false" ]; then
  # In case of a pre-release build, use the brew registry for the virt-operator image pullspec
  VIRT_OPERATOR_IMAGE=${VIRT_OPERATOR_IMAGE//registry.redhat.io\/container-native-virtualization\//brew.registry.redhat.io\/rh-osbs\/container-native-virtualization-}
fi
KUBEVIRT_TAG=$(oc image info -a /tmp/authfile.new ${VIRT_OPERATOR_IMAGE} -o json --filter-by-os=linux/amd64 | jq '.config.config.Labels["upstream-version"]')
KUBEVIRT_RELEASE=v$(echo ${KUBEVIRT_TAG} | awk -F '-' '{print $1}' | tr -d '"')
if [[ ${KUBEVIRT_TAG} == *"rc"* ]] || [[ ${KUBEVIRT_TAG} == *"alpha"* ]] || [[ ${KUBEVIRT_TAG} == *"beta"* ]]; then
  KUBEVIRT_TESTS_URL=https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_RELEASE}/tests.test
  if ! curl --output /dev/null --silent --head --fail "${KUBEVIRT_TESTS_URL}"; then
    # First checking if the official release exists (without "rc", "alpha" or "beta"). If not - use the release candidate version.
    KUBEVIRT_RELEASE=v$(echo ${KUBEVIRT_TAG} | awk -F '-' '{print $1"-"$2}' | tr -d '"')
  fi
fi

function cleanup() {
    rv=$?
    if [ "x$rv" != "x0" ]; then
        echo "Error during tests: exit status: $rv"
        make dump-state
        echo "*** CNV tests failed ***"
    fi
    rm -rf "/tmp/authfile*"
    exit $rv
}

trap "cleanup" INT TERM EXIT

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
oc wait pods -l "kubevirt.io=disks-images-provider" -n "${TARGET_NAMESPACE}" --for condition=Ready --timeout=20m

skip_tests+=('\[QUARANTINE\]')

# Skipping a few unreliable tests
skip_tests+=('rfe_id:273')
skip_tests+=('test_id:1651')
skip_tests+=('with cpu pinning enabled')


skip_regex=$(printf '(%s)|' "${skip_tests[@]}")
skip_arg=$(printf -- '--ginkgo.skip=%s' "${skip_regex:0:-1}")


mkdir -p "${ARTIFACT_DIR}"

echo "Starting tests 🧪"
${TESTS_BINARY} \
    -cdi-namespace="$TARGET_NAMESPACE" \
    -config="./manifests/testing/${KUBEVIRT_TESTING_CONFIGURATION_FILE}" \
    -installed-namespace="$TARGET_NAMESPACE" \
    -junit-output="${ARTIFACT_DIR}/junit.functest.xml" \
    -kubeconfig="$KUBECONFIG" \
    -ginkgo.flake-attempts=3 \
    -ginkgo.label-filter='(wg-arm64 && !(ACPI,requires-two-schedulable-nodes,cpumodel))' \
    -ginkgo.no-color \
    -ginkgo.seed=0 \
    -ginkgo.v \
    -ginkgo.trace \
    -kubectl-path="$(which oc)" \
    -utility-container-prefix=quay.io/kubevirt \
    -test.timeout=3h \
    -test.v \
    -utility-container-tag="${UTILITY_CONTAINER_TAG:-v1.5.0}" \
    "${skip_arg}"
