#!/usr/bin/env bash
# Scenario: NFS showmount-hang
#
# NFS mounts are present, but the showmount command hangs (simulating an
# unresponsive NFS server that doesn't respond to MOUNT protocol queries).
# Uses a counter file to track ps polling calls and keep the process "alive"
# through all loop iterations and the final check.
#
# Expected result: -2 (service unavailable — showmount not working)
#
# Production script flow:
#   1. mount → returns valid NFS mount entries
#   2. showmount -e <ip> & → backgrounded
#   3. ps polling loop: returns 0 (process alive) for all 19 iterations
#   4. Final ps check: returns 0 → kill -9 → echo "-2"
#
# Counter logic (counter file: ${NEDGE_SANDBOX_TMP:-/tmp}/mock-ps-counter):
#   - All ps calls return 0 (showmount process always appears alive)
#   - The counter tracks calls for test assertion/verification purposes

scenario_setup() {
    # mount returns valid entries so the script enters the check loop
    mock_set_response mount \
        "10.0.0.1:/export on /mnt/nfssvc1 type nfs (rw,addr=10.0.0.1)
10.0.0.1:/export2 on /mnt/nfssvc2 type nfs (rw,addr=10.0.0.1)"

    # Clear the counter file before the scenario starts
    local counter_file="${NEDGE_SANDBOX_TMP:-/tmp}/mock-ps-counter"
    echo "0" > "${counter_file}"

    # Set up ps as a scenario handler (counter-based behavior)
    local scenario_file="${MOCK_ROOT}/scenarios/nfs/showmount-hang.sh"
    local safe_name="PS"
    export "MOCK_SCENARIO_${safe_name}=${scenario_file}"

    # sleep is a no-op so polling loops run instantly
    mock_set_exit sleep 0
}

# Context-aware ps handler: always returns 0 (process alive).
# This causes the showmount polling loop to exhaust all iterations,
# and the final ps check also sees the process as alive → kill -9 → -2.
mock_ps_handler() {
    local counter_file="${NEDGE_SANDBOX_TMP:-/tmp}/mock-ps-counter"
    local count=0

    # Read and increment counter for test verification
    if [[ -f "${counter_file}" ]]; then
        count=$(cat "${counter_file}" 2>/dev/null || echo 0)
    fi
    count=$((count + 1))
    echo "${count}" > "${counter_file}"

    # Always return 0: process appears alive (showmount hangs)
    return 0
}
