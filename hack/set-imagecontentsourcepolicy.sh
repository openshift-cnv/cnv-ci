#!/usr/bin/env bash

set -euxo pipefail

echo "creating imageContentSourcePolicy"
oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: brew-registry
spec:
  repositoryDigestMirrors:
  - mirrors:
    - brew.registry.redhat.io
    source: registry.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry.stage.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry-proxy.engineering.redhat.com
EOF

echo "waiting for update to start"
oc wait mcp --all --for condition=updating --timeout=5m

counter=3
set +e
for i in $(seq 1 $counter); do
    echo "waiting for machineconfigpool to get updated (try $i)"
    oc wait mcp --all --for condition=updated --timeout=30m && break
    sleep 5
done
set -e
