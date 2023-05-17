#!/usr/bin/env bash

set -euxo pipefail

PRODUCTION_RELEASE=${PRODUCTION_RELEASE:-false}

echo "get matching kubevirt release from the build"
VIRT_OPERATOR_IMAGE=$(oc get deployment virt-operator -n ${TARGET_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].image}')

if [ "$PRODUCTION_RELEASE" = "false" ]; then
  # In case of a pre-release build, use the brew registry for the virt-operator image pullspec
  VIRT_OPERATOR_IMAGE=${VIRT_OPERATOR_IMAGE//registry.redhat.io\/container-native-virtualization\//brew.registry.redhat.io\/rh-osbs\/container-native-virtualization-}
fi
KUBEVIRT_TAG=$(oc image info -a /tmp/authfile.new ${VIRT_OPERATOR_IMAGE} -o json --filter-by-os=linux/amd64 | jq '.config.config.Labels["upstream-version"]')
KUBEVIRT_RELEASE=v$(echo ${KUBEVIRT_TAG} | awk -F '-' '{print $1}' | tr -d '"')
if [[ ${KUBEVIRT_TAG} == *"rc"* ]] || [[ ${KUBEVIRT_TAG} == *"alpha"* ]]; then
  KUBEVIRT_TESTS_URL=https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_RELEASE}/tests.test
  if ! curl --output /dev/null --silent --head --fail "${KUBEVIRT_TESTS_URL}"; then
    # First checking if the official release exists (without "rc" or "alpha"). If not - use the release candidate version.
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
######
# hack to run a fixed version of Kubevirt tests
# please remove this hack once
# - https://github.com/kubevirt/kubevirt/pull/9683
# - https://github.com/kubevirt/kubevirt/pull/9684
# are properly consumed
#curl -Lo "$TESTS_BINARY" "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_RELEASE}/tests.test"
if [[ "$KUBEVIRT_RELEASE" == "v1.0.0-alpha.0" ]]; then
    echo "Using a fixed version of kubevirt tests"
    curl -Lo "$TESTS_BINARY" "https://github.com/tiraboschi/kubevirt/releases/download/v1.0.0-alpha.0-fix/tests.test"
else
    curl -Lo "$TESTS_BINARY" "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_RELEASE}/tests.test"
fi
######
chmod +x "$TESTS_BINARY"

echo "create testing infrastructure"
[ "$(oc get PersistentVolume host-path-disk-alpine)" ] || oc create -n "${TARGET_NAMESPACE}" -f ./manifests/testing/kubevirt-testing-infra.yaml

echo "waiting for testing infrastructure to be ready"
oc wait deployment cdi-http-import-server -n "${TARGET_NAMESPACE}" --for condition=Available --timeout=10m
oc wait pods -l "kubevirt.io=disks-images-provider" -n "${TARGET_NAMESPACE}" --for condition=Ready --timeout=20m

skip_tests+=('\[QUARANTINE\]')
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

# Skipping a few unrealiable tests
skip_tests+=('rfe_id:273')
skip_tests+=('test_id:1304')
skip_tests+=('test_id:1615')
skip_tests+=('test_id:1616')
skip_tests+=('test_id:1617')
skip_tests+=('test_id:1618')
skip_tests+=('test_id:1626')
skip_tests+=('test_id:1651')
skip_tests+=('test_id:1657')
skip_tests+=('test_id:2188')
skip_tests+=('test_id:2190')
skip_tests+=('test_id:3007')
skip_tests+=('test_id:3178')
skip_tests+=('test_id:3180')
skip_tests+=('test_id:3182')
skip_tests+=('test_id:3184')
skip_tests+=('test_id:3185')
skip_tests+=('test_id:3199')
skip_tests+=('test_id:3312')
skip_tests+=('test_id:4119')
skip_tests+=('test_id:4136')
skip_tests+=('test_id:4622')
skip_tests+=('test_id:6993')
skip_tests+=('test_id:6311')
skip_tests+=('test_id:7164')
skip_tests+=('test_id:7679')
skip_tests+=('\[Serial\] Should leave a failed VMI')
skip_tests+=('VirtualMachine crash loop backoff should backoff attempting to create a new VMI when')
skip_tests+=('Using expand command')
skip_tests+=('Using virtctl interface')
skip_tests+=('repeately starting vmis')
skip_tests+=('Prometheus Endpoints')


skip_regex=$(printf '(%s)|' "${skip_tests[@]}")
skip_arg=$(printf -- '--ginkgo.skip=%s' "${skip_regex:0:-1}")


mkdir -p "${ARTIFACT_DIR}"

if [[ "$OCP_VERSION" == "4.10" ]];
then
  GINKGO_FLAKE="--ginkgo.flakeAttempts=3"
  GINKGO_NOCOLOR="--ginkgo.noColor"
  GINKGO_SLOW="--ginkgo.slowSpecThreshold=60"
else
  GINKGO_FLAKE="--ginkgo.flake-attempts=3"
  GINKGO_NOCOLOR="--ginkgo.no-color"
  GINKGO_SLOW="--ginkgo.slow-spec-threshold=60s"
fi


if [[ "$OCP_VERSION" != "4.14" ]];
then
  echo "starting tests"
  ${TESTS_BINARY} \
      -cdi-namespace="$TARGET_NAMESPACE" \
      -config=./manifests/testing/kubevirt-testing-configuration.json \
      -installed-namespace="$TARGET_NAMESPACE" \
      -junit-output="${ARTIFACT_DIR}/junit.functest.xml" \
      -kubeconfig="$KUBECONFIG" \
      -ginkgo.focus='(rfe_id:1177)|(rfe_id:273)|(rfe_id:151)' \
      "${GINKGO_NOCOLOR}" \
      -ginkgo.seed=0 \
      "${GINKGO_SLOW}" \
      -ginkgo.v \
      -ginkgo.trace \
      -oc-path="$(which oc)" \
      -kubectl-path="$(which oc)" \
      -utility-container-prefix=quay.io/kubevirt \
      -test.timeout=3h \
      -test.v \
      "${GINKGO_FLAKE}" \
      "${skip_arg}"
else
  # TODO: please remove this once we wiil be able to
  # consume a fix for https://github.com/kubevirt/kubevirt/issues/9725
  echo "skipping tier1 tests on CNV 4.14"
fi
