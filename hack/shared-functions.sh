#!/bin/bash

echo_debug()
{
    echo "$@" >&2
}

# Run a command until it succeeds or the maximum number of retries is reached.
#
# Arguments:
# - $1: a banner describing what we are waiting for
# - $2: the maximum number of retries before giving up
# - $3: the delay to wait before each retry
# - $@: the command to run
wait_for() {
  local what="$1"; shift
  local retries="$1"; shift
  local delay="$1"; shift

  echo "[INFO] Waiting for ${what}." >&2

  time (
    { set +x; } 2>/dev/null
    while true; do
      if "$@"; then
        break
      fi

      # Give up after too many tries
      if [[ "${retries}" -le 0 ]]; then
        echo "[ERROR] Timeout waiting for ${what}." >&2
        exit 1
      fi

      retries=$((retries - 1))
      sleep "${delay}"
    done
  )
}


# Wait for a specific operator PackageManifest in a CatalogSource.
# Usage: wait_for_manifests <catalog-source> <operator-name> [<timeout-seconds>]
wait_for_manifests() {
  local catalog_source="$1"
  local operator="$2"
  local timeout="${3:-900}"
  local start_time=${SECONDS}
  local pm_catalog=""

  while (( SECONDS - start_time < timeout )); do
    pm_catalog=$(
      oc get packagemanifest "${operator}" \
        -o jsonpath='{.status.catalogSource}' 2>/dev/null || true
    )
    if [[ "${pm_catalog}" == "${catalog_source}" ]]; then
      echo_debug "PackageManifest '${operator}' indexed in CatalogSource '${catalog_source}'."
      return 0
    fi
    sleep 10
  done

  echo "[ERROR] Timeout after ${timeout}s waiting for PackageManifest '${operator}' in CatalogSource '${catalog_source}'." >&2
  return 1
}

# Get the pull-secret from an OpenShift cluster
#
# The secrets are copied to a temporary file whose path is exported in the
# environment variable REGISTRY_AUTH_FILE used by oc, podman and skopeo.
#
# It is the responsibility of the caller of this function to remove the
# temporary file after use.
common::funcs::get_cluster_pull_secret()
{
  REGISTRY_AUTH_FILE=$(mktemp "${TMPDIR:-/tmp}"/ocp-pull-secret.json.XXXXXX)

  oc get secret pull-secret \
    --namespace='openshift-config' \
    --output=go-template='{{index .data ".dockerconfigjson" | base64decode}}' \
    >"${REGISTRY_AUTH_FILE}"

  export REGISTRY_AUTH_FILE
}

#
# Set default storage
#
# Inputs:
#   * storageclass - name of the storageclass to be default
storageclass::set_default() {
  local storageclass="${1}"
  # Using a W/A - bug: https://bugzilla.redhat.com/show_bug.cgi?id=2079830
  #oc annotate storageclasses --all storageclass.kubernetes.io/is-default-class-
  #oc annotate storageclass "${storageclass}" storageclass.kubernetes.io/is-default-class=true
  oc get storageclass -o name | xargs oc patch -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'
  oc patch storageclass "${storageclass}" -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
  echo "[DEBUG] Printing Storage Classes:"
  oc get storageclasses
}

#
# Set default virt storage
#
# Inputs:
#   * storageclass - name of the storageclass to be default
storageclass::set_virt_default() {
  local storageclass="${1}"
  oc get storageclass -o name | xargs oc patch -p '{"metadata": {"annotations": {"storageclass.kubevirt.io/is-default-virt-class": "false"}}}'
  oc patch storageclass "${storageclass}" -p '{"metadata": {"annotations": {"storageclass.kubevirt.io/is-default-virt-class": "true"}}}'
}

#
# Get the current cluster default storageclass name
#
# Output: the SC name, or empty string if none is set
storageclass::get_cluster_default() {
  oc get sc -o json | jq -r '.items[].metadata | select(.annotations."storageclass.kubernetes.io/is-default-class"=="true") | .name'
}

#
# Check if cluster default storageclass will be changed
#
# Inputs:
#   * new_storageclass - name of the storageclass to be new default
# Return TRUE/FALSE
storageclass::cluster_default_storageclass_changed() {
  local new_storageclass="${1}"
  local current_default_sc
  current_default_sc=$(storageclass::get_cluster_default)
  if [[ $new_storageclass != "${current_default_sc}" ]]; then
    echo 'TRUE'
    return
  else
    echo 'FALSE'
    return
  fi
}

#
# Get the current virt-default storageclass name
#
# Output: the SC name, or empty string if none is set
storageclass::get_virt_default() {
  oc get sc -o json | jq -r '.items[].metadata | select(.annotations."storageclass.kubevirt.io/is-default-virt-class"=="true") | .name'
}

#
# Check if virt-default storageclass will be changed
#
# Inputs:
#   * new_storageclass - name of the storageclass to be new virt-default
# Return TRUE/FALSE
storageclass::virt_default_storageclass_changed() {
  local new_storageclass="${1}"
  local current_virt_default_sc
  current_virt_default_sc=$(storageclass::get_virt_default)
  if [[ $new_storageclass != "${current_virt_default_sc}" ]]; then
    echo 'TRUE'
    return
  else
    echo 'FALSE'
    return
  fi
}

# ============================================================================
# TOOLS NAMESPACE - Binary and Tool Management
# ============================================================================

# tools::bin_dir::get_temp - Get the temporary bin directory path for storing downloaded binaries
# Creates the directory if it doesn't exist
# Returns: Absolute path to the .bin directory (via echo)
# Side effects: Creates .bin directory if it doesn't exist
tools::bin_dir::get_temp() {
  _detect_top_dir
  local bin_dir="${TOP_DIR}/.bin"
  mkdir -p "${bin_dir}"
  echo "${bin_dir}"
}

# tools::yq::get - Get yq (YAML processor) - downloads if not available
# Returns the path to yq (./yq or yq)
# Checks for existing yq at specified path or system yq before downloading
# Uses lazy initialization: downloads only on first call, caches result in YQ_CMD global variable
# Subsequent calls return the cached value without re-downloading
# Note: When called via command substitution, the function sets YQ_CMD in the parent shell
# by outputting the value, which the caller should assign: YQ_CMD=$(tools::yq::get)
# Args:
#   $1: Optional path to store yq (defaults to ${TOP_DIR}/.bin/yq)
# Returns: Path to yq executable (via echo)
tools::yq::get() {
  # If already initialized in parent shell (check via eval to access parent scope)
  # When called via command substitution, we can't directly check parent's YQ_CMD,
  # but the caller should set it: YQ_CMD=$(tools::yq::get)
  # For direct calls (not in subshell), check if YQ_CMD is set
  if [[ "${BASH_SUBSHELL}" -eq 0 ]] && [[ -n "${YQ_CMD:-}" ]]; then
    echo "${YQ_CMD}"
    return 0
  fi

  local yq_path="${1:-}"
  local YQ_LATEST_VERSION
  local current_version

  # Determine tools bin directory (reuse across calls)
  if [[ -z "${yq_path}" ]]; then
    yq_path="$(tools::bin_dir::get_temp)/yq"
  fi

  # Convert to absolute path
  if [[ "${yq_path}" != /* ]] && [[ "${yq_path}" != "yq" ]]; then
    yq_path=$(readlink -f "${yq_path}" 2>/dev/null || realpath "${yq_path}" 2>/dev/null || echo "${yq_path}")
  fi

  # Check if yq already exists at the specified path and is the Go version
  if [[ -f "${yq_path}" ]]; then
    # Check if it's the Go version (try --version flag first, then version subcommand)
    if "${yq_path}" --version &>/dev/null 2>&1; then
      current_version=$("${yq_path}" --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
      if [[ -n "${current_version}" ]]; then
        YQ_CMD="${yq_path}"
        echo "${YQ_CMD}"
        return 0
      fi
    fi
  fi

  # Check system yq if path not explicitly provided
  if [[ -z "${1:-}" ]] && command -v yq &> /dev/null; then
    # Check if system yq is Go version (try --version flag first)
    if yq --version &>/dev/null 2>&1; then
      current_version=$(yq --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
      if [[ -n "${current_version}" ]]; then
        YQ_CMD="yq"
        echo "${YQ_CMD}"
        return 0
      fi
    fi
  fi

  # Get latest version
  YQ_LATEST_VERSION=$(curl -fsSL -H 'Accept: application/json' https://github.com/mikefarah/yq/releases/latest | jq -r .tag_name)
  if [[ "${YQ_LATEST_VERSION}" == "null" ]] || [[ -z "${YQ_LATEST_VERSION}" ]]; then
    YQ_LATEST_VERSION="v4.43.1"
  fi

  if ! curl -fsSLo "${yq_path}" "https://github.com/mikefarah/yq/releases/download/${YQ_LATEST_VERSION}/yq_linux_amd64"; then
    echo "Error: Failed to download yq ${YQ_LATEST_VERSION}" >&2
    return 1
  fi
  chmod +x "${yq_path}"
  # Ensure we return absolute path
  if [[ "${yq_path}" != /* ]]; then
    yq_path=$(readlink -f "${yq_path}" 2>/dev/null || realpath "${yq_path}" 2>/dev/null || echo "${yq_path}")
  fi
  YQ_CMD="${yq_path}"
  echo "${YQ_CMD}"
}

#
# Wait for a CRD to be available
# Parameters:
#   crd_name - the name of the CRD to wait for
#
wait_for_crd() {
  local crd_name="$1"

  wait_for \
    "CRD ${crd_name} to be available" 30 5 \
    bash -c "oc get crd '${crd_name}' >/dev/null 2>&1"

  echo "⏳ Waiting for ${crd_name} resource to be ready..."
  until oc explain "${crd_name}" &>/dev/null; do
    sleep 5
  done
}

function env::hash()
{
    # Check if trace is currently on
    local trace_was_on=0
    if [[ $- == *x* ]]; then
        set +x  # Turn it OFF immediately to hide logic
        trace_was_on=1
    fi

    local sensitive_patterns="password|token|secret|access_key"

    env | while IFS= read -r line; do
        local key="${line%%=*}"
        local val="${line#*=}"

        if [[ "${key,,}" =~ $sensitive_patterns ]]; then
            local hash=""
            if command -v sha512sum >/dev/null 2>&1; then
                hash=$(printf "%s" "$val" | sha512sum | awk '{print $1}' | cut -c1-64) # We truncate the hash to 64 characters
            else
                hash="[error_no_sha512sum_tool_found]"
            fi

            echo "$key=SHA512:$hash..."
        else
            echo "$line"
        fi
    done

    if [[ $trace_was_on -eq 1 ]]; then
        set -x
    fi
}

retry() {
    local -r max_attempts="${1}"
    local -r delay="${2}"
    shift 2

    local count=1

    until "$@"; do
        local exit_code=$?
        if (( count >= max_attempts )); then
            echo "Error: Command '$*' failed after ${count} attempts (exit code ${exit_code})." >&2
            return ${exit_code}
        fi

        echo "Attempt ${count}/${max_attempts} failed with exit code ${exit_code}. Retrying in ${delay}s..." >&2
        sleep "${delay}"
        ((count++))
    done
}

retry_backoff() {
    local max_attempts="${1}"
    local delay="${2}"
    shift 2

    local count=1

    until "$@"; do
        local exit_code=$?
        if (( count >= max_attempts )); then
            echo "Error: Command failed after ${count} attempts." >&2
            return ${exit_code}
        fi

        echo "Attempt ${count}/${max_attempts} failed. Retrying in ${delay}s..." >&2
        sleep "${delay}"
        delay=$(( delay * 2 ))
        ((count++))
    done
}

oc::getClusterVersionXYZ() {
    oc get clusterversion version -o jsonpath='{.status.desired.version}'
}

oc::getClusterVersionXY() {
    oc::getClusterVersionXYZ | cut -d. -f1,2
}

oc::getClusterVersionX() {
    oc::getClusterVersionXYZ | cut -d. -f1
}

oc::getClusterPullSecret() {
    oc get secret/pull-secret -n openshift-config --template='{{index .data ".dockerconfigjson" | base64decode}}'
}

function download_virtctl() {
    echo "[INFO] Downloading virtctl to ${BIN_FOLDER} .." >&2
    curl -k -fsS "${virtctl_url}" | tar -C "${BIN_FOLDER}" \
      --transform='flags=r;s/virtctl-linux-.*/virtctl/' -xzf -

    chmod +x "${BIN_FOLDER}/virtctl"
    echo "[INFO] virtctl installed: $("${BIN_FOLDER}/virtctl" version --client 2>/dev/null | head -1 || echo unknown)" >&2
}

# shellcheck disable=SC2329
function virtctl_download_ready() {
  curl -k -fsS -o /dev/null --connect-timeout 15 --max-time 120 "$1" 2>/dev/null
}

function install_yq_if_not_exists() {
    # Install yq manually if not found in image
    echo "Checking if yq exists"
    cmd_yq="$(yq --version 2>/dev/null || true)"
    if [ -n "$cmd_yq" ]; then
        echo "yq version: $cmd_yq"
    else
        echo "Installing yq"
        mkdir -p /tmp/bin
        export PATH=$PATH:/tmp/bin/
        curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
         -o /tmp/bin/yq && chmod +x /tmp/bin/yq
    fi
}

function mapTestsForComponentReadiness() {

    [[ ${MAP_TESTS:-false} != "true" ]] && return

    results_file="${1}"
    echo "Patching Tests Result File: ${results_file}"
    if [ -f "${results_file}" ]; then
        install_yq_if_not_exists
        echo "Mapping Test Suite Name To: CNV-lp-interop"
        yq eval -px -ox -iI0 '.testsuites.testsuite.+@name="CNV-lp-interop"' "${results_file}"
    fi
}

# Description:
#   Polls all CatalogSource resources in the cluster until they are all healthy and ready,
#   or until a timeout is reached.
# Usage:
#   make_sure_all_catalog_source_are_healthy <timeout-seconds> [<poll-interval-seconds>]
make_sure_all_catalog_source_are_healthy() {
  local timeout=${1:?"Error: timeout (in seconds) is required as first argument"}
  local interval=${2:-5}
  local start_time=${SECONDS}

  local CS_NAME="${CNV_IIB_CATALOG_NAME}"
  local CS_IMAGE="${CNV_CATALOG_IMAGE}"

  echo_debug "Waiting for all CatalogSource resources to become healthy (timeout: ${timeout}s, interval: ${interval}s)..."

  while true; do
    # Fetch all CatalogSources and count those not READY or explicitly unhealthy
    local not_ready_count
    not_ready_count=$(oc get catalogsource --all-namespaces -o json \
      | jq '[.items[] | select(
            .status.connectionState.lastObservedState != "READY" or
            (.status.health.healthy? == false)
          )] | length')

    if [[ "$not_ready_count" -eq 0 ]]; then
      echo_debug "All CatalogSource resources are healthy and ready."
      return 0
    fi

    # Check for timeout
    local elapsed=$(( SECONDS - start_time ))
    if (( elapsed >= timeout )); then
      echo_debug "Timeout after ${elapsed}s: ${not_ready_count} CatalogSource(s) are still not healthy or ready."
      oc get catalogsource --all-namespaces -o yaml | tee "${ARTIFACT_DIR}/catalogsources.yaml"

      echo_debug '[DEBUG] Dumping the state of all subscriptions'
      oc get subscriptions.operators -A -o yaml | tee "${ARTIFACT_DIR}/subscriptions.yaml"

      echo_debug "Checking catalog source status..."
      # Check if catalog source still exists (it might have been deleted by OpenShift)
      if oc get catalogsource "${CS_NAME}" -n openshift-marketplace &>/dev/null; then
        echo_debug "Catalog source still exists, showing details:"
        oc get catalogsource "${CS_NAME}" -n openshift-marketplace -o yaml | tee "${ARTIFACT_DIR}/catalogsource.${CS_NAME}.yaml"
        echo_debug ""
        echo_debug "Catalog source pod status:"
        oc get pods -n openshift-marketplace -l olm.catalogSource="${CS_NAME}" -o wide >&2 || true
        echo_debug ""
        echo_debug "Catalog source events:"
        oc get events -n openshift-marketplace --field-selector involvedObject.name="${CS_NAME}" --sort-by='.lastTimestamp' | tail -20 >&2 || true
      else
        echo_debug "[ERROR] Catalog source ${CS_NAME} was deleted by OpenShift (likely due to image pull failure)."
        echo_debug "Image: ${CS_IMAGE}"
        echo_debug "This usually indicates:"
        echo_debug "  - Image does not exist or is inaccessible"
        echo_debug "  - Authentication/authorization issues"
        echo_debug "  - Network connectivity problems"
        echo_debug "  - Invalid image reference"
      fi

      return 1
    fi

    echo_debug "${not_ready_count} CatalogSource(s) not ready or unhealthy. Retrying in ${interval}s..."
    sleep "${interval}"
  done
}

# Wait until master and worker MCP are Updated
# or timeout after 90min (default).
wait_for_mcp_to_update() {

    local timeout_minutes=${1:-90}
    local poll_interval_seconds=30
    local max_attempts=$(( timeout_minutes * 60 / poll_interval_seconds ))
    local attempt=0

    echo "Waiting for MCPs to update (timeout: ${timeout_minutes} minutes)"

    while true; do
        attempt=$((attempt+1))

        if oc wait mcp --all --for condition=updated --timeout="${poll_interval_seconds}s"; then
            echo "MCPs are updated."
            return 0
        fi

        if (( attempt >= max_attempts )); then
            echo "Error: MCPs did not update within ${timeout_minutes} minutes." >&2
            return 1
        fi

        echo "Attempt ${attempt}/${max_attempts}: MCPs not yet updated, retrying in ${poll_interval_seconds} seconds..."
    done
}

mcp.pause()
{
    #shellcheck disable=SC2046
    oc patch --type=merge --patch='{"spec":{"paused": true}}' $(oc get mcp -o name)
}

# Resume master and worker MCP.
mcp.resume()
{
    #shellcheck disable=SC2046
    oc patch --type=merge --patch='{"spec":{"paused": false}}' $(oc get mcp -o name)
}
