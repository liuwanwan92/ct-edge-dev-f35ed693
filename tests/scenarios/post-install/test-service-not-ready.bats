#!/usr/bin/env bats
# =============================================================================
# Scenario: post-install / service not ready
# ---------------------------------------------------------------------------
# Health checks are invoked before NexentaEdge services have fully started.
# The check script should report the "not mounted" / error state, and once
# services recover the stale-cache pipeline should propagate the healthy
# value within two scrapes.
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

@test "not-ready: NFS services initially down, then recover" {
    # ---- Scrape 1: services not ready (not mounted) --------------------
    mock_nfs_not_mounted

    local resp1 body1
    resp1="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp1"
    body1="$(http_extract_body "$resp1")"
    # First scrape — no cache — returns empty.
    [[ -z "$body1" ]]

    _sandbox_wait_background

    # Background collector should have written an error code (-3 = not mounted).
    local cache_after_first
    cache_after_first="$(sandbox_read_cache nfs)"
    [[ "$cache_after_first" == *"-3"* ]]

    # ---- Scrape 2: still returns stale -3; change mocks to healthy -----
    local resp2 body2
    resp2="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp2"
    body2="$(http_extract_body "$resp2")"
    # Should see the not-mounted value from scrape 1's background.
    assert_metric_equals "$body2" "nexenta_nfs_mount_status" "-3"

    # Now the services come up.
    mock_nfs_healthy

    _sandbox_wait_background

    # ---- Scrape 3: returns stale 1 (healthy from scrape 2's bg) --------
    local resp3 body3
    resp3="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp3"
    body3="$(http_extract_body "$resp3")"
    assert_metric_equals "$body3" "nexenta_nfs_mount_status" "1"
}

@test "not-ready: stale empty cache does not mask the transition" {
    # Ensure that the transition from "not ready" to "healthy" is always
    # visible in the cache files — the framework never silently swallows
    # the state change.

    # Phase 1: service down
    mock_nfs_not_mounted
    http_get_metrics "$NFS_SCRIPT" >/dev/null
    _sandbox_wait_background

    local cache_down
    cache_down="$(sandbox_read_cache nfs)"
    [[ "$cache_down" == *"-3"* ]]

    # Phase 2: service recovers
    mock_nfs_healthy
    http_get_metrics "$NFS_SCRIPT" >/dev/null
    _sandbox_wait_background

    local cache_healthy
    cache_healthy="$(sandbox_read_cache nfs)"
    [[ "$cache_healthy" == *"1"* ]]

    # The two cache snapshots must differ — proving the transition is
    # observable and not masked by stale data.
    [[ "$cache_down" != "$cache_healthy" ]]
}
