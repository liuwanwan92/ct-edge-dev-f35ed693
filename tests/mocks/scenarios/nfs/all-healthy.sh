#!/usr/bin/env bash
# Scenario: NFS all-healthy
#
# All NFS services are fully operational. Both mounts are present,
# showmount and df complete successfully, and rpcinfo reports ready.
#
# Expected result: 1 (service fully available)
#
# Production script flow:
#   1. mount -l -t nfs,nfs4,nfs2,nfs3 → returns valid NFS mount entries
#   2. showmount -e <ip> (backgrounded) → ps poll returns 1 (process done)
#   3. df -k <path> (backgrounded) → ps poll returns 1 (process done)
#   4. rpcinfo -u <ip> nfs → contains "ready" or "waiting"

scenario_setup() {
    # mount returns two NFS mount entries with extractable IP addresses.
    # The production script uses awk to parse addr= from the options field.
    mock_set_response mount \
        "10.0.0.1:/export on /mnt/nfssvc1 type nfs (rw,addr=10.0.0.1)
10.0.0.1:/export2 on /mnt/nfssvc2 type nfs (rw,addr=10.0.0.1)"

    # ps always returns 1 (process not found = already exited).
    # This makes both the showmount and df polling loops break immediately,
    # and the final ps check also sees the process as done.
    mock_set_exit ps 1

    # showmount and df exit codes don't directly matter since they are
    # backgrounded and only polled via ps, but set them to 0 for completeness.
    mock_set_exit showmount 0
    mock_set_exit df 0

    # rpcinfo reports NFS is ready and waiting — this is the final check
    # that determines result=1 vs result=0.
    mock_set_response rpcinfo "100003    3   udp   2049  nfs  ready and waiting"

    # sleep is a no-op in tests (speeds up polling loops)
    mock_set_exit sleep 0
}
