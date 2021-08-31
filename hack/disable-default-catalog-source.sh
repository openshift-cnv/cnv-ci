#!/usr/bin/env bash

set -euxo pipefail
# TODO: test also the opposite case before merging
PRODUCTION_RELEASE=${PRODUCTION_RELEASE:-true}

if [ "$PRODUCTION_RELEASE" != "true" ]; then
  echo "disabling default catalog source"
  oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
fi
