#!/usr/bin/env bash

set -euxo pipefail

eval "$(jq -r '."'"$OCP_VERSION"'" | to_entries[] | .key+"="+.value' version-mapping.json)"

echo "creating brew catalog source"
oc create -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: brew-catalog-source
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: $index_image
  displayName: Brew Catalog Source
  publisher: grpc
EOF

while [ "$(oc get pods -n "openshift-marketplace" -l olm.catalogSource="brew-catalog-source" --no-headers | wc -l)" -eq 0 ]; do
    echo "waiting for catalog source pod to be created"
    sleep 5
done

echo "waiting for catalog source pod to be ready"
oc wait pods -n "openshift-marketplace" -l olm.catalogSource="brew-catalog-source" --for condition=Ready --timeout=180s
