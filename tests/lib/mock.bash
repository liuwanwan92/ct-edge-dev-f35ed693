#!/usr/bin/env bash
# mock.bash - Command interception via PATH manipulation
#
# Creates shim scripts for each external command the production scripts use.
# Each shim:
#   1. Logs the call to the trace file
#   2. Checks for MOCK_RESPONSE_<CMD> override → return directly
#   3. Checks for MOCK_SCENARIO_<CMD> file → source and call handler
#   4. Falls through to the real command (if available)

MOCK_BIN_DIR=""

# All commands that need mocking
_MOCK_COMMANDS=(mount showmount df rpcinfo iscsi-ls curl openssl base64
                docker modprobe ps hostname sleep egrep grep)

# Initialize mock infrastructure (called from test_helper setup)
mock_init() {
    MOCK_BIN_DIR="${SANDBOX_BIN}/mock"
    mkdir -p "${MOCK_BIN_DIR}"
    # Pre-compute the real PATH (without mock dir) BEFORE prepending mock dir.
    # This avoids using grep in the shim's fallthrough path, which would
    # consume piped stdin (the root cause of `echo | grep` hangs).
    _MOCK_REAL_PATH="$(echo "${PATH}" | tr ':' '\n' | grep -v "/mock" | tr '\n' ':')"
    export _MOCK_REAL_PATH
    # Prepend mock dir to PATH so our shims are found first
    export PATH="${MOCK_BIN_DIR}:${PATH}"
    # Write ONE generic shim, then symlink each command to it
    _mock_write_generic_shim
    local cmd
    for cmd in "${_MOCK_COMMANDS[@]}"; do
        ln -sf _mock_shim "${MOCK_BIN_DIR}/${cmd}"
    done
}

# Reset all mocks (clear responses and scenarios)
mock_reset_all() {
    mock_clear
    mock_init
}

# Write a single generic mock shim that derives the command name from $0.
# Uses a quoted heredoc ('EOF') to avoid any variable expansion issues.
_mock_write_generic_shim() {
    local shim="${MOCK_BIN_DIR}/_mock_shim"
    cat > "${shim}" << 'EOF'
#!/usr/bin/env bash
# Generic mock shim - derives command name from $0
CMD_NAME="$(basename "$0")"
SAFE_NAME="$(echo "${CMD_NAME}" | tr 'a-z-' 'A-Z_')"
# Find our mock bin dir (where this script lives)
MOCK_BIN="$(cd "$(dirname "$0")" && pwd)"

# Log to trace file
if [[ -n "${NEDGE_TRACE_FILE:-}" ]]; then
    _ts="$(date +%s.%N 2>/dev/null || date +%s)"
    echo "${_ts} MOCK MOCK ${CMD_NAME} ARGS=[$*]" >> "${NEDGE_TRACE_FILE}"
fi

# Priority 1: Direct response override
RESP_VAR="MOCK_RESPONSE_${SAFE_NAME}"
EXIT_VAR="MOCK_EXIT_${SAFE_NAME}"
if [[ -n "${!RESP_VAR+x}" ]]; then
    if [[ -n "${!RESP_VAR}" ]]; then
        echo "${!RESP_VAR}"
    fi
    exit ${!EXIT_VAR:-0}
fi

# Priority 2: Scenario handler
SCEN_VAR="MOCK_SCENARIO_${SAFE_NAME}"
if [[ -n "${!SCEN_VAR:-}" && -f "${!SCEN_VAR}" ]]; then
    source "${!SCEN_VAR}"
    if declare -f "mock_${CMD_NAME}_handler" &>/dev/null; then
        "mock_${CMD_NAME}_handler" "$@"
        exit $?
    fi
fi

# Priority 3: Fall through to real command
# IMPORTANT: We use pre-computed _MOCK_REAL_PATH (set during mock_init)
# instead of filtering PATH with grep here. Using grep would consume
# piped stdin, breaking commands like `echo "data" | grep pattern`.
_REAL_CMD="$(PATH="${_MOCK_REAL_PATH}" command -v "${CMD_NAME}" 2>/dev/null)" || true
if [[ -n "${_REAL_CMD}" ]]; then
    exec "${_REAL_CMD}" "$@"
else
    exit 127
fi
EOF
    chmod +x "${shim}"
}

# Set a direct response for a command (highest priority)
# Usage: mock_set_response <cmd> <output> [exit_code]
mock_set_response() {
    local cmd="$1" response="$2" exit_code="${3:-0}"
    local safe_name
    safe_name="$(echo "${cmd}" | tr 'a-z-' 'A-Z_')"
    export "MOCK_RESPONSE_${safe_name}=${response}"
    export "MOCK_EXIT_${safe_name}=${exit_code}"
}

# Set exit code for a command (no output)
# Usage: mock_set_exit <cmd> <exit_code>
mock_set_exit() {
    local cmd="$1" exit_code="$2"
    local safe_name
    safe_name="$(echo "${cmd}" | tr 'a-z-' 'A-Z_')"
    export "MOCK_RESPONSE_${safe_name}="
    export "MOCK_EXIT_${safe_name}=${exit_code}"
}

# Load a scenario file for a command
# Usage: mock_set_scenario <cmd> <category> <scenario_name>
mock_set_scenario() {
    local cmd="$1" category="$2" scenario="$3"
    local safe_name
    safe_name="$(echo "${cmd}" | tr 'a-z-' 'A-Z_')"
    local scenario_file="${MOCK_ROOT}/scenarios/${category}/${scenario}.sh"
    if [[ ! -f "${scenario_file}" ]]; then
        echo "ERROR: scenario not found: ${scenario_file}" >&2
        return 1
    fi
    export "MOCK_SCENARIO_${safe_name}=${scenario_file}"
}

# Load a full scenario that sets up multiple commands at once
# Usage: mock_load_scenario <category> <scenario_name>
mock_load_scenario() {
    local category="$1" scenario="$2"
    local scenario_file="${MOCK_ROOT}/scenarios/${category}/${scenario}.sh"
    if [[ ! -f "${scenario_file}" ]]; then
        echo "ERROR: scenario not found: ${scenario_file}" >&2
        return 1
    fi
    source "${scenario_file}"
    # Call the setup function if defined
    if declare -f "scenario_setup" &>/dev/null; then
        scenario_setup
    fi
}

# Clear all mock responses and scenarios
mock_clear() {
    local cmd
    for cmd in "${_MOCK_COMMANDS[@]}"; do
        local safe_name
        safe_name="$(echo "${cmd}" | tr 'a-z-' 'A-Z_')"
        unset "MOCK_RESPONSE_${safe_name}" 2>/dev/null || true
        unset "MOCK_EXIT_${safe_name}" 2>/dev/null || true
        unset "MOCK_SCENARIO_${safe_name}" 2>/dev/null || true
    done
    # Also clear any scenario-specific state
    unset MOCK_COUNTER_FILE 2>/dev/null || true
}

# --- Convenience functions for common mock setups ---

# Configure NFS check mocks for a specific result
# Usage: mock_nfs_healthy | mock_nfs_not_mounted | mock_nfs_showmount_fail | etc.
mock_nfs_healthy() {
    mock_set_response mount \
        "10.0.0.1:/export on /mnt/nfssvc1 type nfs (rw,addr=10.0.0.1)
10.0.0.1:/export2 on /mnt/nfssvc2 type nfs (rw,addr=10.0.0.1)"
    mock_set_exit showmount 0
    mock_set_exit df 0
    mock_set_response rpcinfo "100003    3   udp   2049  nfs  ready and waiting"
}

mock_nfs_not_mounted() {
    mock_set_response mount ""
}

mock_nfs_showmount_fail() {
    mock_set_response mount \
        "10.0.0.1:/export on /mnt/nfssvc1 type nfs (rw,addr=10.0.0.1)
10.0.0.1:/export2 on /mnt/nfssvc2 type nfs (rw,addr=10.0.0.1)"
    mock_set_exit showmount 1
}

mock_nfs_df_fail() {
    mock_set_response mount \
        "10.0.0.1:/export on /mnt/nfssvc1 type nfs (rw,addr=10.0.0.1)
10.0.0.1:/export2 on /mnt/nfssvc2 type nfs (rw,addr=10.0.0.1)"
    mock_set_exit showmount 0
    mock_set_exit df 1
}

mock_nfs_rpcinfo_not_ready() {
    mock_set_response mount \
        "10.0.0.1:/export on /mnt/nfssvc1 type nfs (rw,addr=10.0.0.1)
10.0.0.1:/export2 on /mnt/nfssvc2 type nfs (rw,addr=10.0.0.1)"
    mock_set_exit showmount 0
    mock_set_exit df 0
    mock_set_response rpcinfo "100003    3   udp   2049  nfs  not ready"
}

# Configure iSCSI check mocks
mock_iscsi_healthy() {
    mock_set_response iscsi_ls "Target: iqn.2005-11.nexenta.com:23008
Lun:1    Size:10737418240    Type:disk"
    mock_set_exit iscsi_ls 0
}

mock_iscsi_no_targets() {
    mock_set_response iscsi_ls ""
    mock_set_exit iscsi_ls 1
}

mock_iscsi_no_luns() {
    mock_set_response iscsi_ls "Target: iqn.2005-11.nexenta.com:23008"
    mock_set_exit iscsi_ls 0
}

# Configure S3 check mocks
mock_s3_healthy() {
    mock_set_response curl "HTTP/1.1 200 OK"
    mock_set_exit curl 0
}

mock_s3_bucket_only() {
    # Need scenario for different responses per call
    mock_set_scenario curl s3 bucket-only
}

mock_s3_service_down() {
    mock_set_response curl ""
    mock_set_exit curl 1
}

# Make ps always report "process not found" (speeds up timeout loops)
mock_ps_fast_fail() {
    mock_set_exit ps 1
}
