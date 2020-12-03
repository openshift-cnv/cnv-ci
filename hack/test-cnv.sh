#!/usr/bin/env bash

set -e

echo "downloading the test binary"
BIN_DIR="$(pwd)/_out" && mkdir -p "${BIN_DIR}"
export BIN_DIR

TESTS_BINARY="$BIN_DIR/tests.test"
curl -Lo "$TESTS_BINARY" "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_RELEASE}/tests.test"
chmod +x "$TESTS_BINARY"

oc create -n "${TARGET_NAMESPACE}" -f ./manifests/testing/kubevirt-testing-infra.yaml

echo "starting tests"
${TESTS_BINARY} \
  -installed-namespace="$TARGET_NAMESPACE" \
  -cdi-namespace="$TARGET_NAMESPACE" \
  -config=./manifests/testing/kubevirt-testing-configuration.json \
  -kubeconfig="$KUBECONFIG" \
  -ginkgo.focus='(rfe_id:1177)|(rfe_id:273)|(rfe_id:151)' \
  -ginkgo.skip='(Slirp Networking)|(with CPU spec)|(with TX offload disabled)|(with cni flannel and ptp plugin interface)|(with ovs-cni plugin)|(test_id:1752)|(SRIOV)|(with EFI)|(Operator)|(GPU)|(DataVolume Integration)|(test_id:3468)|(test_id:3466)|(test_id:1015)|(rfe_id:393)' \
  -junit-output="${ARTIFACTS_DIR}/junit.functest.xml" \
  -ginkgo.seed=0
