#!/usr/bin/env bats
# =============================================================================
# Scenario: failover / VIP transition
# ---------------------------------------------------------------------------
# When a Virtual IP (VIP) moves between cluster nodes there is a brief
# window where the service is unreachable.  These tests model that window
# and show how the stale-cache pipeline can mask the outage.
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

@test "failover: VIP transition causes temporary service unavailability" {
    # No prior cache exists — cold start.

    # ---- Scrape 1: VIP is mid-transition, service down -----------------
    mock_nfs_not_mounted

    local resp1 body1
    resp1="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp1"
    body1="$(http_extract_body "$resp1")"
    # No cache yet → empty response.
    [[ -z "$body1" ]]

    _sandbox_wait_background

    # Background wrote the error state.
    [[ "$(sandbox_read_cache nfs)" == *"-3"* ]]

    # ---- Scrape 2: VIP has landed, service is back ---------------------
    mock_nfs_healthy

    local resp2 body2
    resp2="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp2"
    body2="$(http_extract_body "$resp2")"
    # Returns stale error from scrape 1's bg — operator sees the old outage.
    assert_metric_equals "$body2" "nexenta_nfs_mount_status" "-3"

    _sandbox_wait_background

    # Background now writes healthy.
    [[ "$(sandbox_read_cache nfs)" == *"1"* ]]

    # ---- Scrape 3: stable healthy --------------------------------------
    local resp3 body3
    resp3="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp3"
    body3="$(http_extract_body "$resp3")"
    assert_metric_equals "$body3" "nexenta_nfs_mount_status" "1"
}

@test "failover: stale cache masks the VIP transition" {
    # Pre-inject a healthy cache (simulating a node that was fine before
    # the VIP moved away).
    sandbox_inject_fixture nfs nfs-healthy.prom

    # VIP moves — service is now unreachable.
    mock_nfs_not_mounted

    local resp body
    resp="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp"
    body="$(http_extract_body "$resp")"

    # The response shows the STALE healthy value — a false positive.
    # The operator has no idea the VIP has moved and the service is down.
    assert_metric_equals "$body" "nexenta_nfs_mount_status" "1"

    _sandbox_wait_background

    # Only after the background runs does the cache catch up.
    [[ "$(sandbox_read_cache nfs)" == *"-3"* ]]
}
