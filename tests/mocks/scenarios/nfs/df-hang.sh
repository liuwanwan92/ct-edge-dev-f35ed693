#!/usr/bin/env bash
# Scenario: NFS df-hang
#
# NFS mounts are present and showmount completes successfully, but the df
# command hangs (simulating a stale NFS mount or unresponsive filesystem).
# Uses a counter file to differentiate showmount ps polls from df ps polls.
#
# Expected result: -1 (service unavailable — df not working)
#
# Production script flow:
#   1. mount → returns valid NFS mount entries
#   2. showmount -e <ip> & → backgrounded
#   3. ps poll for showmount: returns 1 (process done) → break immediately
#   4. Final ps check for showmount: returns 1 → proceed to df
#   5. df -k <path> & → backgrounded
#   6. ps poll for df: returns 0 (process alive) for all iterations
#   7. Final ps check for df: returns 0 → kill → echo "-1"
#
# Counter logic (counter file: ${NEDGE_SANDBOX_TMP:-/tmp}/mock-ps-counter):
#   - ps calls 1-2: return 1 (showmount loop break + showmount final check)
#   - ps calls 3+:  return 0 (df loop hangs + df final check → kill path)

scenario_setup() {
    # mount returns valid entries so the script enters the check loop
    mock_set_response mount \
        "10.0.0.1:/export on /mnt/nfssvc1 type nfs (rw,addr=10.0.0.1)
10.0.0.1:/export2 on /mnt/nfssvc2 type nfs (rw,addr=10.0.0.1)"

    # Clear the counter file before the scenario starts
    local counter_file="${NEDGE_SANDBOX_TMP:-/tmp}/mock-ps-counter"
    echo "0" > "${counter_file}"

    # Set up ps as a scenario handler (counter-based behavior)
    # We export the scenario file path so the shim sources it
    local scenario_file="${MOCK_ROOT}/scenarios/nfs/df-hang.sh"
    local safe_name="PS"
    export "MOCK_SCENARIO_${safe_name}=${scenario_file}"

    # sleep is a no-op so polling loops run instantly
    mock_set_exit sleep 0
}

# Context-aware ps handler: uses a counter file to track call count.
# First 2 calls return 1 (showmount completes), subsequent calls return 0 (df hangs).
mock_ps_handler() {
    local counter_file="${NEDGE_SANDBOX_TMP:-/tmp}/mock-ps-counter"
    local count=0

    # Read current counter value
    if [[ -f "${counter_file}" ]]; then
        count=$(cat "${counter_file}" 2>/dev/null || echo 0)
    fi

    # Increment counter
    count=$((count + 1))
    echo "${count}" > "${counter_file}"

    # First 2 ps calls: showmount polling (process done → return 1)
    # Calls 3+: df polling (process alive → return 0, simulating hang)
    if [[ ${count} -le 2 ]]; then
        return 1
    else
        return 0
    fi
}
