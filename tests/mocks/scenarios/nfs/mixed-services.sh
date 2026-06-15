#!/usr/bin/env bash
# Scenario: NFS mixed-services
#
# Two NFS services are configured, but only one has an active mount.
# The production script iterates over SERVICES[] and calls nfs_check()
# for each. The service whose mount point appears in mount output gets
# checked normally; the other gets -3 (not mounted).
#
# Expected results:
#   - nfssvc1 (mounted): result depends on showmount/df/rpcinfo → 1 (healthy)
#   - nfssvc2 (not mounted): result = -3 (not found in mount output)
#
# Production script flow:
#   For nfssvc1 (/mnt/nfssvc1):
#     1. mount | grep "/mnt/nfssvc1" → found, extracts IP
#     2. showmount/df/rpcinfo → all pass → echo 1
#   For nfssvc2 (/mnt/nfssvc2):
#     1. mount | grep "/mnt/nfssvc2" → not found, ipaddr empty
#     2. echo "-3"

scenario_setup() {
    # mount returns only ONE service — nfssvc2 is NOT in the output.
    # The production script greps for the mount path, so /mnt/nfssvc2
    # will not match and ipaddr will be empty.
    mock_set_response mount \
        "10.0.0.1:/export on /mnt/nfssvc1 type nfs (rw,addr=10.0.0.1)"

    # ps returns 1 (process done) so showmount and df complete immediately
    mock_set_exit ps 1

    # showmount and df succeed
    mock_set_exit showmount 0
    mock_set_exit df 0

    # rpcinfo reports healthy
    mock_set_response rpcinfo "100003    3   udp   2049  nfs  ready and waiting"

    # sleep is a no-op
    mock_set_exit sleep 0
}
