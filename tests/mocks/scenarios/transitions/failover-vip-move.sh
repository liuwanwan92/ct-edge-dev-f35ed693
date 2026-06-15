#!/usr/bin/env bash
# Scenario: failover-vip-move (transition)
#
# Simulates a VIP (Virtual IP) failover event where the service IP address
# migrates from one cluster node to another. During the transition, the
# VIP is unreachable (no node owns it). Once the VIP lands on the new node,
# services become available again.
#
# This tests the monitoring system's resilience to brief network disruptions
# during HA failover events.
#
# Phase model:
#   Phase 1 (calls 1-2): VIP is in transit — service unreachable
#   Phase 2 (calls 3+):  VIP has landed on new node — service available
#
# The failover threshold is controlled by MOCK_FAILOVER_COUNT (default: 2).
# A counter file tracks the number of check invocations.
#
# This scenario configures handlers for multiple check types so it can
# be used with NFS, iSCSI, or S3 service checks.
#
# Counter file: ${NEDGE_SANDBOX_TMP:-/tmp}/mock-failover-counter

scenario_setup() {
    local failover_count="${MOCK_FAILOVER_COUNT:-2}"
    local counter_file="${NEDGE_SANDBOX_TMP:-/tmp}/mock-failover-counter"

    # Initialize the counter
    echo "0" > "${counter_file}"

    # Export the failover threshold so handlers can read it
    export MOCK_FAILOVER_COUNT="${failover_count}"

    # Clear direct responses for all potential check commands
    unset MOCK_RESPONSE_SHOWMOUNT 2>/dev/null || true
    unset MOCK_EXIT_SHOWMOUNT 2>/dev/null || true
    unset MOCK_RESPONSE_ISCSI_LS 2>/dev/null || true
    unset MOCK_EXIT_ISCSI_LS 2>/dev/null || true
    unset MOCK_RESPONSE_CURL 2>/dev/null || true
    unset MOCK_EXIT_CURL 2>/dev/null || true

    # Set up scenario handlers for multiple service types
    local scenario_file="${MOCK_ROOT}/scenarios/transitions/failover-vip-move.sh"
    export "MOCK_SCENARIO_SHOWMOUNT=${scenario_file}"
    export "MOCK_SCENARIO_ISCSI_LS=${scenario_file}"
    export "MOCK_SCENARIO_CURL=${scenario_file}"

    # Supporting mocks — NFS needs mount, ps, df, rpcinfo
    mock_set_response mount \
        "10.0.0.1:/export on /mnt/nfssvc1 type nfs (rw,addr=10.0.0.1)"
    mock_set_exit ps 1
    mock_set_exit df 0
    mock_set_exit sleep 0
    mock_set_response rpcinfo "100003    3   udp   2049  nfs  ready and waiting"

    # S3 needs openssl and base64
    mock_set_response openssl "dummy_hmac_binary_data"
    mock_set_response base64 "dGVzdA=="
}

# Helper: read the current counter value and increment it.
# Outputs the pre-increment count to stdout.
_mock_failover_tick() {
    local counter_file="${NEDGE_SANDBOX_TMP:-/tmp}/mock-failover-counter"
    local count=0

    if [[ -f "${counter_file}" ]]; then
        count=$(cat "${counter_file}" 2>/dev/null || echo 0)
    fi
    count=$((count + 1))
    echo "${count}" > "${counter_file}"

    echo "${count}"
}

# Helper: check if the VIP is still in transit.
# Returns 0 if VIP is moving (should fail), 1 if VIP has landed (should succeed).
_mock_vip_in_transit() {
    local current_count="$1"
    local failover_count="${MOCK_FAILOVER_COUNT:-2}"

    if [[ ${current_count} -le ${failover_count} ]]; then
        return 0  # VIP still in transit
    else
        return 1  # VIP has landed
    fi
}

# showmount handler: unreachable during VIP transit, available after
mock_showmount_handler() {
    local count
    count=$(_mock_failover_tick)

    if _mock_vip_in_transit "${count}"; then
        # Phase 1: VIP in transit — showmount times out / fails
        # Simulate connection timeout (no route to host)
        echo "clnt_create: RPC: Timed out" >&2
        return 1
    else
        # Phase 2: VIP landed — showmount succeeds
        return 0
    fi
}

# iscsi-ls handler: unreachable during VIP transit, available after
mock_iscsi-ls_handler() {
    local count
    count=$(_mock_failover_tick)

    if _mock_vip_in_transit "${count}"; then
        # Phase 1: VIP in transit — iSCSI discovery fails
        echo "iscsi-ls: failed to connect to target: Connection timed out" >&2
        return 1
    else
        # Phase 2: VIP landed — target discovered with LUN
        echo "Target: iqn.2005-11.nexenta.com:23008"
        echo "Lun:1    Size:10737418240    Type:disk"
        return 0
    fi
}

# curl handler: unreachable during VIP transit, available after
mock_curl_handler() {
    local count
    count=$(_mock_failover_tick)

    if _mock_vip_in_transit "${count}"; then
        # Phase 1: VIP in transit — connection times out
        echo "curl: (28) Connection timed out after 5000 ms" >&2
        return 1
    else
        # Phase 2: VIP landed — service responds normally
        echo "HTTP/1.1 200 OK"
        echo "Content-Type: application/xml"
        echo "Content-Length: 0"
        return 0
    fi
}
