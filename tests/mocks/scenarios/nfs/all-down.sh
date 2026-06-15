#!/usr/bin/env bash
# Scenario: NFS all-down
#
# No NFS filesystems are mounted at all. The production script's mount
# grep finds nothing, so it never enters the showmount/df/rpcinfo checks.
#
# Expected result: -3 (service unavailable — not mounted)
#
# Production script flow:
#   1. mount -l -t nfs,nfs4,nfs2,nfs3 → empty output
#   2. grep -w "$path" finds nothing → ipaddr is empty
#   3. Script enters else branch → echo "-3"

scenario_setup() {
    # mount returns empty — no NFS mounts exist on this system
    mock_set_response mount ""
}
