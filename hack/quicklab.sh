#!/usr/bin/env bash

set -euxo pipefail

echo "applying machineconfigs"
oc create -f manifests/brew/10-master-registries.yaml
oc create -f manifests/brew/10-worker-registries.yaml

echo "waiting for update to start"
oc wait mcp --all --for condition=updating --timeout=5m

counter=6
set +e
for i in $(seq 1 $counter); do
    echo "waiting for machineconfigpool to get updated (try $i)"
    oc wait mcp --all --for condition=updated --timeout=20m && break
    sleep 5
done
set -e
