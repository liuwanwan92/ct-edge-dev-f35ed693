#!/usr/bin/env bats
# =============================================================================
# Scenario: post-upgrade / service restarting
# ---------------------------------------------------------------------------
# During a rolling upgrade, NexentaEdge services may be restarted.  This
# test exercises the 3-scrape cycle: healthy → down → healthy, and verifies
# the trace log captures every state transition.
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

@test "restart: NFS service goes down, comes back across 3 scrapes" {
    # ---- Scrape 1: healthy, primes the cache ---------------------------
    mock_nfs_healthy

    local resp1 body1
    resp1="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp1"
    body1="$(http_extract_body "$resp1")"
    # First scrape — no prior cache — empty.
    [[ -z "$body1" ]]

    _sandbox_wait_background

    # Cache should now hold healthy value (1).
    [[ "$(sandbox_read_cache nfs)" == *"1"* ]]

    # ---- Scrape 2: service restarts (down), returns stale healthy ------
    mock_nfs_not_mounted

    local resp2 body2
    resp2="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp2"
    body2="$(http_extract_body "$resp2")"
    # Stale cache still says healthy — false positive during restart.
    assert_metric_equals "$body2" "nexenta_nfs_mount_status" "1"

    _sandbox_wait_background

    # Background now writes the down state (-3).
    [[ "$(sandbox_read_cache nfs)" == *"-3"* ]]

    # ---- Scrape 3: service back up, returns stale error ----------------
    mock_nfs_healthy

    local resp3 body3
    resp3="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp3"
    body3="$(http_extract_body "$resp3")"
    # Stale cache shows the error from scrape 2's bg — false alarm.
    assert_metric_equals "$body3" "nexenta_nfs_mount_status" "-3"

    _sandbox_wait_background

    # Background writes the correct healthy value again.
    [[ "$(sandbox_read_cache nfs)" == *"1"* ]]
}

@test "restart: trace shows the state transition timeline" {
    # Run the same 3-scrape cycle and verify the trace log captures it.
    mock_nfs_healthy
    http_get_metrics "$NFS_SCRIPT" >/dev/null
    _sandbox_wait_background

    mock_nfs_not_mounted
    http_get_metrics "$NFS_SCRIPT" >/dev/null
    _sandbox_wait_background

    mock_nfs_healthy
    http_get_metrics "$NFS_SCRIPT" >/dev/null
    _sandbox_wait_background

    # Trace must record at least 3 NFS mock invocations.
    local nfs_count
    nfs_count="$(trace_count "nfs")"
    [[ "$nfs_count" -ge 3 ]]

    # Hostname must appear in the trace as well.
    trace_has "hostname"
}
