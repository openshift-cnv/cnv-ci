#!/usr/bin/env bash

set -euo pipefail

authfile=/tmp/authfile
trap 'rm -rf /tmp/authfile*' EXIT SIGINT SIGTERM

echo "getting authfile from cluster"
oc get secret/pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' | base64 -d >"$authfile"

echo "injecting credentials for brew image registry into authfile"
jq -c '.auths + '"$(echo '{"brew.registry.redhat.io": { "auth": "'"$(echo "$BREW_IMAGE_REGISTRY_USERNAME:$(<$BREW_IMAGE_REGISTRY_TOKEN_PATH)" | tr -d '\n' | base64 -i -w 0)"'" } }')"' | {"auths": .}' "$authfile" >"${authfile}.new"

echo "updating cluster pull secret from authfile"
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="${authfile}.new"
