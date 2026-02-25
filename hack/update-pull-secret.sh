#!/usr/bin/env bash

set -euo pipefail

function get_brew_auth() {
    echo -n '{ "brew.registry.redhat.io": { "auth": "'"$(echo "$BREW_IMAGE_REGISTRY_USERNAME:$(<$BREW_IMAGE_REGISTRY_TOKEN_PATH)" | tr -d '\n' | base64 -i -w 0)"'" } }'
}

function get_konflux_auth() {
    echo -n '{ "quay.io/openshift-virtualization": { "auth": "'"$(echo "$KONFLUX_REGISTRY_USERNAME:$(<$KONFLUX_REGISTRY_TOKEN_PATH)" | tr -d '\n' | base64 -i -w 0)"'" } }'
}

authfile=/tmp/authfile
trap 'rm -rf /tmp/authfile*' SIGINT SIGTERM

echo "getting authfile from cluster"
oc get secret/pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' | base64 -d >"$authfile"

echo "injecting credentials into authfile"
jq -c '.auths + '"$(get_brew_auth)"' + '"$(get_konflux_auth)"' | {"auths": .}' "$authfile" >"${authfile}.new"

echo "updating cluster pull secret from authfile"
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="${authfile}.new"
