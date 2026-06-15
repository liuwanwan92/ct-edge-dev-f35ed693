#!/usr/bin/env bats
# test-cache-file-integrity.bats - Tests for cache file handling edge cases
#
# Tests how the health check scripts handle various cache file states:
# empty, corrupt, missing, and concurrent access scenarios.

load '../lib/test_helper'

setup() {
    sandbox_create
    mock_reset_all
    trace_init
    mock_ps_fast_fail
    mock_set_response sleep "" 0
    mock_set_response hostname "testhost"

    NFS_SCRIPT="$(get_nfs_script)"
}

teardown() {
    if [[ "${BATS_TEST_COMPLETED:-}" != "1" ]]; then
        echo "--- TRACE LOG ---" >&3
        trace_dump 3
    fi
    sandbox_destroy
}

@test "CACHE: missing cache file → empty first response" {
    mock_nfs_healthy

    ! sandbox_cache_exists "nfs"

    local response
    response="$(http_get_metrics "${NFS_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"
    local trimmed
    trimmed="$(echo "${body}" | tr -d '[:space:]')"
    [[ -z "${trimmed}" ]]
}

@test "CACHE: empty cache file → served as empty output" {
    # Create an empty cache file
    sandbox_inject_cache "nfs" ""

    mock_nfs_healthy

    local response
    response="$(http_get_metrics "${NFS_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"
    local trimmed
    trimmed="$(echo "${body}" | tr -d '[:space:]')"
    [[ -z "${trimmed}" ]]
}

@test "CACHE: corrupt cache file served verbatim (no validation)" {
    # Inject partially-written cache (truncated mid-value)
    sandbox_inject_fixture "nfs" "corrupt.prom"

    mock_nfs_healthy

    local response
    response="$(http_get_metrics "${NFS_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"

    # Should contain the corrupt content as-is
    echo "${body}" | grep -q "nedge_nfs_service_status"
}

@test "CACHE: background write eventually creates valid cache" {
    mock_nfs_healthy

    # First call - empty response, background starts
    http_get_metrics "${NFS_SCRIPT}" >/dev/null

    # Wait for background to complete
    _sandbox_wait_background

    # Cache should now exist with valid content
    sandbox_cache_exists "nfs"
    local cache
    cache="$(sandbox_read_cache "nfs")"
    assert_valid_prom_format "${cache}"
}

@test "CACHE: second scrape returns previous background result" {
    mock_nfs_healthy

    # First call: empty, background writes healthy cache
    http_get_metrics "${NFS_SCRIPT}" >/dev/null
    _sandbox_wait_background

    # Change mock to simulate service failure
    mock_nfs_not_mounted

    # Second call: returns STALE healthy data from first background
    local response
    response="$(http_get_metrics "${NFS_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"

    # Should show healthy (stale), not the current -3 state
    assert_metric_equals "${body}" "nedge_nfs_service_status" "1" \
        'service="nfssvc1"'
}

@test "CACHE: sandbox isolates cache between tests" {
    # Inject a cache file
    sandbox_inject_fixture "nfs" "nfs-healthy.prom"
    sandbox_cache_exists "nfs"

    # Verify it's in the sandbox, not in real /tmp
    local real_tmp_count
    real_tmp_count="$(ls /tmp/nedge-prom-nfs-check.last 2>/dev/null | wc -l)"
    [[ "${real_tmp_count}" -eq 0 ]]
}

@test "CACHE: different services have independent cache files" {
    ISCSI_SCRIPT="$(get_iscsi_script)"

    # Inject NFS cache only
    sandbox_inject_fixture "nfs" "nfs-healthy.prom"
    sandbox_cache_exists "nfs"
    ! sandbox_cache_exists "iscsi"

    # iSCSI check should not see NFS cache
    mock_iscsi_healthy
    local response
    response="$(http_get_metrics "${ISCSI_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"

    # First iSCSI scrape: no cache → empty
    local trimmed
    trimmed="$(echo "${body}" | tr -d '[:space:]')"
    [[ -z "${trimmed}" ]]
}

@test "CACHE: snapshot captures cache state at a point in time" {
    sandbox_inject_fixture "nfs" "nfs-healthy.prom"

    local snapshot
    snapshot="$(sandbox_snapshot)"

    # Verify snapshot has the cache file
    [[ -f "${snapshot}/nedge-prom-nfs-check.last" ]]

    # Modify the cache
    sandbox_inject_cache "nfs" "modified content"

    # Snapshot should still have the original
    local snapshot_content
    snapshot_content="$(cat "${snapshot}/nedge-prom-nfs-check.last")"
    echo "${snapshot_content}" | grep -q "nedge_nfs_service_status"
}
