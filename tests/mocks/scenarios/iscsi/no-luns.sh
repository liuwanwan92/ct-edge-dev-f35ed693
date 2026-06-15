#!/usr/bin/env bash
# Scenario: iSCSI no-luns
#
# iSCSI target is discovered successfully, but the expected LUN is not
# mapped/present. The first iscsi-ls call succeeds (exit 0), but the
# grep for "Lun:<N>" finds no match.
#
# Expected result: 0 (service LUNs not found)
#
# Production script flow:
#   1. iscsi-ls -s <url> &>/dev/null → exit code 0 (discovery OK)
#   2. iscsi-ls -s <url> | grep "Lun:1" → no match → echo "0"

scenario_setup() {
    # iscsi-ls returns target info but NO Lun: lines.
    # The production script's grep for "Lun:1" will not match.
    mock_set_response iscsi-ls \
        "Target: iqn.2005-11.nexenta.com:23008"
    mock_set_exit iscsi-ls 0
}
