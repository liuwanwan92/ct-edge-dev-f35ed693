#!/usr/bin/env bash
# Scenario: service-starting (transition)
#
# Simulates a service that is in the process of starting up. The first N
# calls to the service check fail (service not yet ready), and subsequent
# calls succeed (service fully operational). This tests the monitoring
# system's ability to handle transient startup states.
#
# The warmup threshold is controlled by MOCK_WARMUP_COUNT (default: 3).
# A counter file tracks the number of check invocations.
#
# Expected behavior:
#   - Calls 1 to MOCK_WARMUP_COUNT: service unavailable
#   - Calls MOCK_WARMUP_COUNT+1 and beyond: service healthy
#
# This scenario configures handlers for multiple check types so it can
# be used with NFS, iSCSI, or S3 service checks.
#
# Counter file: ${NEDGE_SANDBOX_TMP:-/tmp}/mock-warmup-counter

scenario_setup() {
    local warmup_count="${MOCK_WARMUP_COUNT:-3}"
    local counter_file="${NEDGE_SANDBOX_TMP:-/tmp}/mock-warmup-counter"

    # Initialize the counter
    echo "0" > "${counter_file}"

    # Export the warmup threshold so handlers can read it
    export MOCK_WARMUP_COUNT="${warmup_count}"

    # Clear direct responses for all potential check commands
    unset MOCK_RESPONSE_SHOWMOUNT 2>/dev/null || true
    unset MOCK_EXIT_SHOWMOUNT 2>/dev/null || true
    unset MOCK_RESPONSE_ISCSI_LS 2>/dev/null || true
    unset MOCK_EXIT_ISCSI_LS 2>/dev/null || true
    unset MOCK_RESPONSE_CURL 2>/dev/null || true
    unset MOCK_EXIT_CURL 2>/dev/null || true

    # Set up scenario handlers for multiple service types
    local scenario_file="${MOCK_ROOT}/scenarios/transitions/service-starting.sh"
    export "MOCK_SCENARIO_SHOWMOUNT=${scenario_file}"
    export "MOCK_SCENARIO_ISCSI_LS=${scenario_file}"
    export "MOCK_SCENARIO_CURL=${scenario_file}"

    # Supporting mocks
    mock_set_response mount \
        "10.0.0.1:/export on /mnt/nfssvc1 type nfs (rw,addr=10.0.0.1)"
    mock_set_exit ps 1
    mock_set_exit df 0
    mock_set_exit sleep 0
    mock_set_response rpcinfo "100003    3   udp   2049  nfs  ready and waiting"
    mock_set_response openssl "dummy_hmac_binary_data"
    mock_set_response base64 "dGVzdA=="
}

# Helper: read the current counter value and increment it.
# Returns the pre-increment value via stdout.
_mock_warmup_tick() {
    local counter_file="${NEDGE_SANDBOX_TMP:-/tmp}/mock-warmup-counter"
    local count=0

    if [[ -f "${counter_file}" ]]; then
        count=$(cat "${counter_file}" 2>/dev/null || echo 0)
    fi
    count=$((count + 1))
    echo "${count}" > "${counter_file}"

    # Return the count (caller captures via stdout)
    echo "${count}"
}

# Helper: check if we're still in the warmup phase.
# Returns 0 if still warming up (should fail), 1 if ready (should succeed).
_mock_is_warming_up() {
    local current_count="$1"
    local warmup_count="${MOCK_WARMUP_COUNT:-3}"

    if [[ ${current_count} -le ${warmup_count} ]]; then
        return 0  # still warming up
    else
        return 1  # service is ready
    fi
}

# showmount handler: fails during warmup, succeeds after
mock_showmount_handler() {
    local count
    count=$(_mock_warmup_tick)

    if _mock_is_warming_up "${count}"; then
        # Service not ready yet: showmount fails
        return 1
    else
        # Service is up: showmount succeeds
        return 0
    fi
}

# iscsi-ls handler: fails during warmup, succeeds with LUN after
mock_iscsi-ls_handler() {
    local count
    count=$(_mock_warmup_tick)

    if _mock_is_warming_up "${count}"; then
        # Service not ready: discovery fails
        return 1
    else
        # Service is up: target found with LUN
        echo "Target: iqn.2005-11.nexenta.com:23008"
        echo "Lun:1    Size:10737418240    Type:disk"
        return 0
    fi
}

# curl handler: fails during warmup, returns 200 OK after
mock_curl_handler() {
    local count
    count=$(_mock_warmup_tick)

    if _mock_is_warming_up "${count}"; then
        # Service not ready: connection refused
        echo "curl: (7) Failed to connect: Connection refused"
        return 1
    else
        # Service is up: return success
        echo "HTTP/1.1 200 OK"
        return 0
    fi
}
