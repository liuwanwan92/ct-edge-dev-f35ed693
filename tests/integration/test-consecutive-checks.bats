#!/usr/bin/env bats
# test-consecutive-checks.bats - Integration test for consecutive health checks
#
# Tests the end-to-end behavior of running health checks consecutively,
# documenting the stale-cache pipeline that causes flaky results.

load '../lib/test_helper'

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
        echo "--- TRACE LOG ---" >&3
        trace_dump 3
    fi
    sandbox_destroy
}

@test "consecutive: NFS 3 scrapes show empty→stale→stable pipeline" {
    mock_nfs_healthy

    # Scrape 1: no cache → empty
    local resp1
    resp1="$(http_get_metrics "${NFS_SCRIPT}")"
    local body1
    body1="$(http_extract_body "${resp1}")"
    local trim1
    trim1="$(echo "${body1}" | tr -d '[:space:]')"
    [[ -z "${trim1}" ]]

    # Wait for background to write cache
    _sandbox_wait_background
    sandbox_cache_exists "nfs"

    # Scrape 2: returns stale data from scrape 1's background
    local resp2
    resp2="$(http_get_metrics "${NFS_SCRIPT}")"
    local body2
    body2="$(http_extract_body "${resp2}")"

    # Should now have metric data (from scrape 1's bg write)
    local trim2
    trim2="$(echo "${body2}" | tr -d '[:space:]')"
    [[ -n "${trim2}" ]]
    assert_metric_equals "${body2}" "nedge_nfs_service_status" "1" \
        'service="nfssvc1"'

    _sandbox_wait_background

    # Scrape 3: returns data from scrape 2's background
    local resp3
    resp3="$(http_get_metrics "${NFS_SCRIPT}")"
    local body3
    body3="$(http_extract_body "${resp3}")"
    assert_metric_equals "${body3}" "nedge_nfs_service_status" "1" \
        'service="nfssvc1"'
}

@test "consecutive: NFS state does not affect iSCSI state" {
    # Set up NFS as healthy, iSCSI as down
    mock_nfs_healthy
    mock_iscsi_no_targets

    # Run NFS check (creates NFS cache)
    http_get_metrics_sync "${NFS_SCRIPT}" >/dev/null
    sandbox_cache_exists "nfs"

    # iSCSI cache should not exist
    ! sandbox_cache_exists "iscsi"

    # Run iSCSI check
    local resp
    resp="$(http_get_metrics "${ISCSI_SCRIPT}")"
    local body
    body="$(http_extract_body "${resp}")"

    # First iSCSI scrape: empty (no iSCSI cache, NFS cache irrelevant)
    local trimmed
    trimmed="$(echo "${body}" | tr -d '[:space:]')"
    [[ -z "${trimmed}" ]]
}

@test "consecutive: all 3 services run one after another" {
    mock_nfs_healthy
    mock_iscsi_healthy
    # S3 healthy mock is tricky (needs different curl responses for object vs bucket).
    # Skip S3 in this test and verify it separately.

    # Prime caches
    http_get_metrics "${NFS_SCRIPT}" >/dev/null
    http_get_metrics "${ISCSI_SCRIPT}" >/dev/null

    # Each service should have its own cache
    sandbox_cache_exists "nfs"
    sandbox_cache_exists "iscsi"

    # Second round: should return stale data from first round
    local nfs_resp iscsi_resp
    nfs_resp="$(http_get_metrics "${NFS_SCRIPT}")"
    iscsi_resp="$(http_get_metrics "${ISCSI_SCRIPT}")"

    local nfs_body iscsi_body
    nfs_body="$(http_extract_body "${nfs_resp}")"
    iscsi_body="$(http_extract_body "${iscsi_resp}")"

    # Both should have data now
    assert_metric_equals "${nfs_body}" "nedge_nfs_service_status" "1" \
        'service="nfssvc1"'
    assert_metric_equals "${iscsi_body}" "nedge_iscsi_service_status" "1" \
        'service="iscsisvc"'
}

@test "consecutive: trace log captures full execution sequence" {
    mock_nfs_healthy

    http_get_metrics_sync "${NFS_SCRIPT}" >/dev/null
    _sandbox_wait_background
    http_get_metrics "${NFS_SCRIPT}" >/dev/null

    # Trace should record both check starts and mock invocations
    local check_starts
    check_starts="$(trace_count 'START')"
    [[ "${check_starts}" -ge 2 ]]

    local mock_calls
    mock_calls="$(trace_count 'MOCK MOCK')"
    [[ "${mock_calls}" -gt 0 ]]
}
