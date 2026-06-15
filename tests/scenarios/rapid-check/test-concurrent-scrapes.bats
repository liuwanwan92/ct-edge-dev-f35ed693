#!/usr/bin/env bats
# =============================================================================
# Scenario: rapid-check / concurrent scrapes
# ---------------------------------------------------------------------------
# Two Prometheus scrapes arrive in quick succession (before the first
# background collector finishes).  Both must return the same stale cache
# content without corruption.
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

@test "concurrent: two scrapes in quick succession both get same stale data" {
    # Seed the cache so both scrapes have something to return.
    sandbox_inject_fixture nfs nfs-healthy.prom

    mock_nfs_healthy

    # Fire two scrapes without waiting for background between them.
    local resp1 resp2 body1 body2
    resp1="$(http_get_metrics "$NFS_SCRIPT")"
    resp2="$(http_get_metrics "$NFS_SCRIPT")"

    assert_http_200 "$resp1"
    assert_http_200 "$resp2"

    body1="$(http_extract_body "$resp1")"
    body2="$(http_extract_body "$resp2")"

    # Both responses must carry the same stale cache content.
    [[ "$body1" == "$body2" ]]
    assert_metric_equals "$body1" "nexenta_nfs_mount_status" "1"
}

@test "concurrent: background writes do not corrupt existing cache" {
    # Pre-populate the NFS cache.
    sandbox_inject_fixture nfs nfs-healthy.prom

    local original_cache
    original_cache="$(sandbox_read_cache nfs)"

    mock_nfs_healthy

    # Fire two scrapes quickly.
    http_get_metrics "$NFS_SCRIPT" >/dev/null
    http_get_metrics "$NFS_SCRIPT" >/dev/null

    # Read the cache immediately — it should still be intact (not truncated
    # or partially overwritten by an in-flight background write).
    local mid_cache
    mid_cache="$(sandbox_read_cache nfs)"

    # Either the original is still there or a complete new version has
    # been written; we should never see a truncated / partial file.
    if [[ "$mid_cache" != "$original_cache" ]]; then
        # If it changed, it must be a complete valid metric line.
        [[ "$mid_cache" == *"nexenta_nfs_mount_status"* ]]
    fi

    _sandbox_wait_background

    # After all backgrounds finish, cache must be a valid healthy value.
    local final_cache
    final_cache="$(sandbox_read_cache nfs)"
    [[ "$final_cache" == *"1"* ]]
}
