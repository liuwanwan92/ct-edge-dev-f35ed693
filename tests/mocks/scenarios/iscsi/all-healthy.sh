#!/usr/bin/env bash
# Scenario: iSCSI all-healthy
#
# iSCSI target is discoverable and the expected LUN is present.
# The production script calls iscsi-ls twice: once to check discovery
# (exit code only) and once to grep for the specific LUN number.
#
# Expected result: 1 (service fully available)
#
# Production script flow:
#   1. iscsi-ls -s <url> &>/dev/null → exit code 0 (discovery OK)
#   2. iscsi-ls -s <url> | grep "Lun:<N>" → match found → echo "1"

scenario_setup() {
    # iscsi-ls returns target info with a LUN entry.
    # The production script greps for "Lun:1" (the LUN number from config).
    mock_set_response iscsi-ls \
        "Target: iqn.2005-11.nexenta.com:23008
Lun:1    Size:10737418240    Type:disk"
    mock_set_exit iscsi-ls 0
}
