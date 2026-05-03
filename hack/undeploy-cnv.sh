#!/usr/bin/env bash

set -euxo pipefail

HCO_KIND="hyperconvergeds.v1beta1.hco.kubevirt.io"

oc delete "${HCO_KIND}" -n "${TARGET_NAMESPACE}" kubevirt-hyperconverged
oc delete OperatorGroup -n "${TARGET_NAMESPACE}" openshift-cnv-group
oc delete Subscription -n "${TARGET_NAMESPACE}" kubevirt-hyperconverged
oc delete ns "${TARGET_NAMESPACE}"
oc delete CatalogSource -n "openshift-marketplace" cnv-catalog-source
