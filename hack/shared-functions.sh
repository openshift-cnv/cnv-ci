#!/bin/bash

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
