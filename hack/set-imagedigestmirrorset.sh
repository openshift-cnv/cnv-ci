#!/usr/bin/env bash

set -euxo pipefail

echo "applying ImageDigestMirrorSet"
oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: konflux-registry
spec:
  imageDigestMirrors:
  - source: registry.redhat.io/container-native-virtualization
    mirrors:
      - quay.io/openshift-virtualization/konflux-builds/v4-18
      - brew.registry.redhat.io/container-native-virtualization      
EOF

echo "waiting for update to start"
oc wait mcp --all --for condition=updating --timeout=15m

counter=3
set +e
for i in $(seq 1 $counter); do
    echo "waiting for machineconfigpool to get updated (try $i)"
    oc wait mcp --all --for condition=updated --timeout=30m && break
    sleep 5
done
set -e
