#!/usr/bin/env bash
# Scenario: iSCSI no-targets
#
# iSCSI discovery fails completely — the target is unreachable, likely
# due to a network issue or the iSCSI service being down. The production
# script checks the exit code of the first iscsi-ls call.
#
# Expected result: -1 (service not discoverable)
#
# Production script flow:
#   1. iscsi-ls -s <url> &>/dev/null → exit code 1 (failure)
#   2. Script enters error branch → echo "-1"

scenario_setup() {
    # iscsi-ls returns empty output and exits with code 1 (discovery failure)
    mock_set_response iscsi-ls "" 1
}
