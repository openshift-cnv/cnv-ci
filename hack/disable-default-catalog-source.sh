#!/usr/bin/env bash

set -euxo pipefail

echo "disabling default catalog source"
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
