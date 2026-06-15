#!/usr/bin/env bats
# =============================================================================
# Scenario: failover / service unavailable
# ---------------------------------------------------------------------------
# Temporary loss of a NexentaEdge service.  Documents the inherent 2-scrape
# delay: when a service recovers it takes two more scrapes before the correct
# (healthy) value appears in the HTTP response.
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

@test "unavailable: NFS goes down for 2 scrapes, then recovers" {
    mock_nfs_healthy

    # ---- Scrape 1: prime cache with healthy value ----------------------
    http_get_metrics "$NFS_SCRIPT" >/dev/null
    _sandbox_wait_background
    [[ "$(sandbox_read_cache nfs)" == *"1"* ]]

    # ---- Scrape 2: service goes down; returns stale healthy ------------
    mock_nfs_not_mounted
    local resp2 body2
    resp2="$(http_get_metrics "$NFS_SCRIPT")"
    body2="$(http_extract_body "$resp2")"
    assert_metric_equals "$body2" "nexenta_nfs_mount_status" "1"
    _sandbox_wait_background
    [[ "$(sandbox_read_cache nfs)" == *"-3"* ]]

    # ---- Scrape 3: still down; returns stale error ---------------------
    local resp3 body3
    resp3="$(http_get_metrics "$NFS_SCRIPT")"
    body3="$(http_extract_body "$resp3")"
    assert_metric_equals "$body3" "nexenta_nfs_mount_status" "-3"
    _sandbox_wait_background
    [[ "$(sandbox_read_cache nfs)" == *"-3"* ]]

    # ---- Scrape 4: service recovers; returns stale error (lag!) --------
    mock_nfs_healthy
    local resp4 body4
    resp4="$(http_get_metrics "$NFS_SCRIPT")"
    body4="$(http_extract_body "$resp4")"
    # Still shows -3 — the stale error from scrape 3's bg.
    assert_metric_equals "$body4" "nexenta_nfs_mount_status" "-3"
    _sandbox_wait_background
    [[ "$(sandbox_read_cache nfs)" == *"1"* ]]

    # ---- Scrape 5: finally shows healthy -------------------------------
    local resp5 body5
    resp5="$(http_get_metrics "$NFS_SCRIPT")"
    body5="$(http_extract_body "$resp5")"
    assert_metric_equals "$body5" "nexenta_nfs_mount_status" "1"
}

@test "unavailable: recovery takes 2 scrapes to reflect in output" {
    # Prime cache with error state.
    sandbox_inject_fixture nfs nfs-stale-error.prom
    # Ensure the cache really has an error value.
    local initial_cache
    initial_cache="$(sandbox_read_cache nfs)"
    [[ "$initial_cache" == *"-3"* ]] || [[ "$initial_cache" == *"-2"* ]]

    # Service is healthy now.
    mock_nfs_healthy

    # Scrape A: returns stale error (false alarm).
    local respA bodyA
    respA="$(http_get_metrics "$NFS_SCRIPT")"
    bodyA="$(http_extract_body "$respA")"
    [[ "$bodyA" == *"-3"* ]] || [[ "$bodyA" == *"-2"* ]]
    _sandbox_wait_background

    # Scrape B: returns the healthy value from scrape A's background.
    local respB bodyB
    respB="$(http_get_metrics "$NFS_SCRIPT")"
    bodyB="$(http_extract_body "$respB")"
    assert_metric_equals "$bodyB" "nexenta_nfs_mount_status" "1"

    # The 2-scrape delay is confirmed: scrape A was still wrong,
    # scrape B is the first to show the correct healthy state.
}
