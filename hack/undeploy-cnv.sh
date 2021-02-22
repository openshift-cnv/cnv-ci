#!/usr/bin/env bash

set -euxo pipefail

oc delete HyperConverged -n "${TARGET_NAMESPACE}" kubevirt-hyperconverged
oc delete OperatorGroup -n "${TARGET_NAMESPACE}" openshift-cnv-group
oc delete Subscription -n "${TARGET_NAMESPACE}" kubevirt-hyperconverged
oc delete ns "${TARGET_NAMESPACE}"
oc delete CatalogSource -n "openshift-marketplace" brew-catalog-source
