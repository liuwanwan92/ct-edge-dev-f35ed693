#!/usr/bin/env bash
# sandbox.bash - State isolation for health check tests
#
# Production scripts hardcode /tmp/nedge-prom-*.last cache paths.
# We cannot modify them. Instead we:
#   1. Copy the script to a sandbox location
#   2. sed-replace the hardcoded /tmp/ prefix with our sandbox path
#   3. Execute the patched copy
#
# This gives each test a fully isolated filesystem state without root.

SANDBOX_BASE=""
SANDBOX_TMP=""
SANDBOX_VAR=""
SANDBOX_BIN=""
SANDBOX_TRACE=""
_SANDBOX_LAST_BG_PID=""

# Create a new sandbox for the current test
sandbox_create() {
    SANDBOX_BASE="$(mktemp -d "${TMPDIR:-/tmp}/nedge-test-sandbox.XXXXXX")"
    SANDBOX_TMP="${SANDBOX_BASE}/tmp"
    SANDBOX_VAR="${SANDBOX_BASE}/var"
    SANDBOX_BIN="${SANDBOX_BASE}/bin"
    SANDBOX_TRACE="${SANDBOX_BASE}/trace.log"
    mkdir -p "${SANDBOX_TMP}" "${SANDBOX_VAR}" "${SANDBOX_BIN}"
    touch "${SANDBOX_TRACE}"

    export NEDGE_SANDBOX="${SANDBOX_BASE}"
    export NEDGE_SANDBOX_TMP="${SANDBOX_TMP}"
    export NEDGE_SANDBOX_VAR="${SANDBOX_VAR}"
    export NEDGE_SANDBOX_BIN="${SANDBOX_BIN}"
    export NEDGE_TRACE_FILE="${SANDBOX_TRACE}"
}

# Destroy the sandbox and clean up
sandbox_destroy() {
    # Kill any orphaned background export processes
    if [[ -n "${_SANDBOX_LAST_BG_PID}" ]]; then
        kill "${_SANDBOX_LAST_BG_PID}" 2>/dev/null || true
        wait "${_SANDBOX_LAST_BG_PID}" 2>/dev/null || true
    fi
    if [[ -n "${SANDBOX_BASE}" && -d "${SANDBOX_BASE}" ]]; then
        rm -rf "${SANDBOX_BASE}"
    fi
    SANDBOX_BASE=""
    SANDBOX_TMP=""
    SANDBOX_VAR=""
    SANDBOX_BIN=""
    SANDBOX_TRACE=""
    _SANDBOX_LAST_BG_PID=""
    unset NEDGE_SANDBOX NEDGE_SANDBOX_TMP NEDGE_SANDBOX_VAR \
          NEDGE_SANDBOX_BIN NEDGE_TRACE_FILE
}

# Execute a production script with /tmp/ paths redirected to sandbox.
# The script is copied and patched (sed), then run.
# stdout/stderr are captured; background processes may still be running.
# Usage: sandbox_exec <script_path> [args...]
sandbox_exec() {
    local script="$1"; shift
    local name
    name="$(basename "${script}")"
    local patched="${SANDBOX_BIN}/${name}"

    # Patch hardcoded /tmp/ paths to sandbox /tmp/
    sed "s|/tmp/nedge-prom-|${SANDBOX_TMP}/nedge-prom-|g" \
        "${script}" > "${patched}"
    chmod +x "${patched}"

    # Execute with current PATH (includes mock shims)
    "${patched}" "$@"
}

# Execute a script and wait for background cache writes to complete.
# Usage: sandbox_exec_sync <script_path> [args...]
sandbox_exec_sync() {
    local script="$1"; shift
    sandbox_exec "${script}" "$@"
    local rc=$?
    _sandbox_wait_background
    return ${rc}
}

# Wait for orphaned background *_prom_export processes to finish.
# These processes are orphaned (reparented to init) when the main script
# exits, so `wait` cannot see them. Instead, we poll for cache files
# to appear and stabilize.
#
# IMPORTANT: The cache write is NON-ATOMIC (bug we're documenting).
# The background process truncates the file with `>` then writes services
# one at a time. Each service check can take up to 2 seconds (ps polling
# loops). We must wait long enough for ALL services to be written.
#
# Strategy: We track BOTH file size stability AND file content completeness.
# A "complete" cache has metric lines with values (ending in a number).
# We require stability for at least 10 iterations AND a minimum of 1 second.
_sandbox_wait_background() {
    # First, wait for any direct child processes
    wait 2>/dev/null || true

    local max_wait=80  # 80 * 0.1s = 8 seconds max
    local prev_size=-1
    local stable_count=0
    local i

    for ((i = 0; i < max_wait; i++)); do
        sleep 0.1

        # Sum sizes of all cache files in sandbox
        local current_size=0
        local f
        for f in "${SANDBOX_TMP}"/nedge-prom-*-check.last; do
            if [[ -f "$f" ]]; then
                local sz
                sz="$(wc -c < "$f" 2>/dev/null)" || sz=0
                sz="${sz//[^0-9]/}"  # strip all non-digits
                current_size=$(( current_size + ${sz:-0} ))
            fi
        done

        # Check stability: size hasn't changed
        if [[ "${current_size}" -eq "${prev_size}" && "${current_size}" -gt 0 ]]; then
            stable_count=$(( stable_count + 1 ))
            # Require 10 stable iterations AND minimum 1 second elapsed
            if [[ "${stable_count}" -ge 10 && "${i}" -ge 10 ]]; then
                # Extra check: verify the cache looks complete
                # (all metric lines should end with a number value)
                local incomplete=0
                for f in "${SANDBOX_TMP}"/nedge-prom-*-check.last; do
                    if [[ -f "$f" ]]; then
                        # Count metric lines (start with service name, not #)
                        local metric_lines
                        metric_lines=$(grep -c '^[a-z]' "$f" 2>/dev/null) || true
                        metric_lines="${metric_lines//[^0-9]/}"
                        metric_lines="${metric_lines:-0}"
                        # Count lines that end with a number
                        local complete_lines
                        complete_lines=$(grep -cE '^[a-z].*[0-9]$' "$f" 2>/dev/null) || true
                        complete_lines="${complete_lines//[^0-9]/}"
                        complete_lines="${complete_lines:-0}"
                        if [[ "${metric_lines}" -gt 0 && "${metric_lines}" -ne "${complete_lines}" ]]; then
                            incomplete=1
                        fi
                    fi
                done
                if [[ "${incomplete}" -eq 0 ]]; then
                    break
                fi
                # Cache looks incomplete, reset stability counter
                stable_count=0
            fi
        else
            stable_count=0
        fi
        prev_size="${current_size}"
    done
}

# Inject content directly into a service's cache file
# Usage: sandbox_inject_cache <service> <content>
sandbox_inject_cache() {
    local service="$1"
    local content="$2"
    printf '%s\n' "${content}" > "${SANDBOX_TMP}/nedge-prom-${service}-check.last"
}

# Copy a fixture file into a service's cache file
# Usage: sandbox_inject_fixture <service> <fixture_filename>
sandbox_inject_fixture() {
    local service="$1"
    local fixture_name="$2"
    local fixture_path="${FIXTURE_ROOT}/sample-cache/${fixture_name}"
    if [[ ! -f "${fixture_path}" ]]; then
        echo "ERROR: fixture not found: ${fixture_path}" >&2
        return 1
    fi
    cp "${fixture_path}" "${SANDBOX_TMP}/nedge-prom-${service}-check.last"
}

# Read the current content of a service's cache file
# Usage: sandbox_read_cache <service>
sandbox_read_cache() {
    local service="$1"
    local cache_file="${SANDBOX_TMP}/nedge-prom-${service}-check.last"
    if [[ -f "${cache_file}" ]]; then
        cat "${cache_file}"
    fi
}

# Check if a service's cache file exists
sandbox_cache_exists() {
    local service="$1"
    [[ -f "${SANDBOX_TMP}/nedge-prom-${service}-check.last" ]]
}

# Get the size (bytes) of a service's cache file, 0 if missing
sandbox_cache_size() {
    local service="$1"
    local cache_file="${SANDBOX_TMP}/nedge-prom-${service}-check.last"
    if [[ -f "${cache_file}" ]]; then
        wc -c < "${cache_file}" | tr -d ' '
    else
        echo "0"
    fi
}

# Take a snapshot of the current sandbox tmp state
# Returns the snapshot directory path
sandbox_snapshot() {
    local ts
    ts="$(date +%s%N)"
    local snapshot_dir="${SANDBOX_BASE}/snapshots/${ts}"
    mkdir -p "${snapshot_dir}"
    if ls "${SANDBOX_TMP}/"* &>/dev/null; then
        cp -a "${SANDBOX_TMP}/"* "${snapshot_dir}/"
    fi
    echo "${snapshot_dir}"
}

# Verify no files leaked to the real /tmp
sandbox_verify_isolation() {
    local real_tmp_count
    real_tmp_count=$(ls /tmp/nedge-test-sandbox.* 2>/dev/null | \
        grep -v "^${SANDBOX_BASE}" | wc -l)
    [[ "${real_tmp_count}" -eq 0 ]]
}

# List all cache files in the sandbox with sizes
sandbox_list_caches() {
    ls -la "${SANDBOX_TMP}"/nedge-prom-*-check.last 2>/dev/null || echo "(no cache files)"
}
