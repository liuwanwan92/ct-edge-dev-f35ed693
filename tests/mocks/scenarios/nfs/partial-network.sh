#!/usr/bin/env bash
# Scenario: NFS partial-network
#
# NFS mounts are present, but the showmount process hangs (simulating a
# network partition or unresponsive NFS server). The ps polling loop
# exhausts all iterations with the process still "alive", triggering the
# kill -9 path.
#
# Expected result: -2 (service unavailable — showmount not working)
#
# Production script flow:
#   1. mount → returns valid NFS mount entries with IP addresses
#   2. showmount -e <ip> &  → backgrounded
#   3. ps polling loop: ps always returns 0 (process alive) for 19 iterations
#   4. Final ps check: still returns 0 → kill -9 → echo "-2"

scenario_setup() {
    # mount returns valid entries so the script enters the check loop
    mock_set_response mount \
        "10.0.0.1:/export on /mnt/nfssvc1 type nfs (rw,addr=10.0.0.1)
10.0.0.1:/export2 on /mnt/nfssvc2 type nfs (rw,addr=10.0.0.1)"

    # ps always returns 0 (process alive). This makes the showmount polling
    # loop run through all 19 iterations, and the final check also sees the
    # process as alive → kill -9 → result -2.
    mock_set_exit ps 0

    # sleep is a no-op so the polling loop runs instantly in tests
    mock_set_exit sleep 0
}
