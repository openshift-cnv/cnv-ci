#!/usr/bin/env bash

set -euo pipefail

echo "disabling default catalog source"
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
