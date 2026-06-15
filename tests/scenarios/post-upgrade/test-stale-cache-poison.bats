#!/usr/bin/env bats
# =============================================================================
# Scenario: post-upgrade / stale cache poisoning
# ---------------------------------------------------------------------------
# Core upgrade bug: leftover cache files from the previous version give
# incorrect results after an upgrade.  Three variants:
#   1. Healthy cache masks a real post-upgrade failure   (false negative)
#   2. Error cache causes a false alarm after upgrade    (false positive)
#   3. Cache with old hostname leaks incorrect labels
# =============================================================================

load '../../lib/test_helper'

setup() {
    sandbox_create
    mock_reset_all
    trace_init
    mock_ps_fast_fail
    mock_set_response sleep "" 0
    mock_set_response hostname "testhost"
    NFS_SCRIPT="$(get_nfs_script)"
    ISCSI_SCRIPT="$(get_iscsi_script)"
    S3_SCRIPT="$(get_s3_script)"
}

teardown() {
    if [[ "${BATS_TEST_COMPLETED:-}" != "1" ]]; then
        echo "--- TRACE LOG ---" >&3; trace_dump 3
    fi
    sandbox_destroy
}

# --------------------------------------------------------------------------- #

@test "upgrade: healthy cache from before masks post-upgrade service failure" {
    # Simulate a leftover healthy cache (value=1) from the old version.
    sandbox_inject_fixture nfs nfs-healthy.prom

    # After upgrade the NFS service is actually down.
    mock_nfs_not_mounted

    local resp body
    resp="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp"
    body="$(http_extract_body "$resp")"

    # The response shows the STALE healthy value — a false positive.
    # This is the bug we want to expose: the operator sees "healthy"
    # even though the service is down.
    assert_metric_equals "$body" "nexenta_nfs_mount_status" "1"

    _sandbox_wait_background

    # After background runs, the cache should reflect the real (down) state.
    local updated_cache
    updated_cache="$(sandbox_read_cache nfs)"
    [[ "$updated_cache" == *"-3"* ]]
}

@test "upgrade: error cache from before causes false alarm post-upgrade" {
    # Simulate a leftover error cache (value=-3 or -2) from the old version.
    sandbox_inject_fixture nfs nfs-stale-error.prom

    # After upgrade the NFS service is actually healthy.
    mock_nfs_healthy

    local resp body
    resp="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp"
    body="$(http_extract_body "$resp")"

    # The response shows the STALE error value — a false alarm.
    # Prometheus will alert even though the service is fine.
    [[ "$body" == *"-3"* ]] || [[ "$body" == *"-2"* ]]

    _sandbox_wait_background

    # After background runs, the cache should reflect the real (healthy) state.
    local updated_cache
    updated_cache="$(sandbox_read_cache nfs)"
    [[ "$updated_cache" == *"1"* ]]
}

@test "upgrade: cache from different hostname leaks incorrect labels" {
    # Inject a cache file that was written by a node with hostname "oldhost".
    local stale_content
    stale_content='nexenta_nfs_mount_status{hostname="oldhost",mount="/mnt/nfs"} 1'
    sandbox_inject_cache nfs "$stale_content"

    mock_nfs_healthy

    local resp body
    resp="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp"
    body="$(http_extract_body "$resp")"

    # The stale cache leaks the OLD hostname into the current response.
    [[ "$body" == *"oldhost"* ]]

    # After background runs the correct hostname ("testhost") should appear.
    _sandbox_wait_background

    local updated_cache
    updated_cache="$(sandbox_read_cache nfs)"
    [[ "$updated_cache" == *"testhost"* ]]
}
