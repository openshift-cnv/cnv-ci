#!/usr/bin/env bash

set -euxo pipefail

CNV_CATALOG_IMAGE=${1:?Missing catalog image for the catalog source}
CNV_CATALOG_SOURCE='cnv-catalog-source'

echo "creating CNV catalog source"
oc create -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CNV_CATALOG_SOURCE}
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${CNV_CATALOG_IMAGE}
  displayName: CNV Catalog Source
  publisher: grpc
EOF

while [ "$(oc get pods -n "openshift-marketplace" -l olm.catalogSource="${CNV_CATALOG_SOURCE}" --no-headers | wc -l)" -ne 1 ]; do
    echo "waiting for catalog source pod to be created"
    sleep 5
done

echo "waiting for the CNV catalog source to become ready"
CATALOG_SOURCE_READY=false
for i in $(seq 1 60); do
  if [ "$(oc get catsrc "${CNV_CATALOG_SOURCE}" -n "openshift-marketplace" -o jsonpath='{.status.connectionState.lastObservedState}')" == "READY" ]
  then
    CATALOG_SOURCE_READY=true
    echo "the brew catalog source is ready."
    break
  else
    echo "Retry #$i"
    sleep 5
  fi
done

if [ ${CATALOG_SOURCE_READY} != "true" ]
then
  echo "Timeout when waiting the catalog source to become ready. Job aborted."
  exit 1
fi
