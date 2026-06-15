#!/usr/bin/env bash
# Scenario: iSCSI mixed-services
#
# Two iSCSI services are configured. One target is reachable with its LUN
# present (healthy), while the other target is unreachable (discovery fails).
# Uses a context-aware handler that inspects the -s URL argument to
# determine which service is being queried.
#
# Expected results:
#   - iscsisvc  (10.16.110.214): result = 1  (healthy, LUN present)
#   - iscsi-z1  (10.16.110.211): result = -1 (discovery fails)
#
# Production script flow (per service):
#   1. iscsi-ls -s <url> → behavior depends on URL
#   2. If exit 0: grep for LUN → echo "1" or "0"
#   3. If exit 1: echo "-1"

scenario_setup() {
    # Clear any direct response so the scenario handler takes priority
    unset MOCK_RESPONSE_ISCSI_LS 2>/dev/null || true
    unset MOCK_EXIT_ISCSI_LS 2>/dev/null || true

    # Point the iscsi-ls shim to this scenario file for handler dispatch
    local scenario_file="${MOCK_ROOT}/scenarios/iscsi/mixed-services.sh"
    export "MOCK_SCENARIO_ISCSI_LS=${scenario_file}"
}

# Context-aware iscsi-ls handler.
# Inspects the -s <url> argument to determine which target is being queried.
# - 10.16.110.214 (iscsisvc): healthy target, returns LUN info, exit 0
# - 10.16.110.211 (iscsi-z1): unreachable target, exit 1
mock_iscsi-ls_handler() {
    local url=""

    # Parse the -s <url> argument
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s)
                url="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Route based on target IP in the URL
    if [[ "${url}" == *"10.16.110.214"* ]]; then
        # Healthy target: discovery succeeds, LUN present
        echo "Target: iqn.2005-11.nexenta.com:23008"
        echo "Lun:1    Size:10737418240    Type:disk"
        return 0
    elif [[ "${url}" == *"10.16.110.211"* ]]; then
        # Unreachable target: discovery fails
        return 1
    else
        # Unknown target: fail by default
        return 1
    fi
}
