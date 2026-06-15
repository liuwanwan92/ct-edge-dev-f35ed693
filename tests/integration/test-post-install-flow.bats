#!/usr/bin/env bats
# test-post-install-flow.bats - Integration test for post-installation scenario
#
# Simulates the sequence of events after a fresh NexentaEdge installation:
#   1. No cache files exist
#   2. Services are starting up (may not be ready)
#   3. First health checks return empty/stale data
#   4. Services become ready over time
#   5. Health checks converge to correct values

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

@test "post-install: fresh start with services not yet ready" {
    # After install, services are not mounted yet
    mock_nfs_not_mounted

    # First scrape: empty (no cache)
    local resp1
    resp1="$(http_get_metrics "${NFS_SCRIPT}")"
    local body1
    body1="$(http_extract_body "${resp1}")"
    local trim1
    trim1="$(echo "${body1}" | tr -d '[:space:]')"
    [[ -z "${trim1}" ]]

    _sandbox_wait_background

    # Cache should now contain -3 (not mounted)
    local cache
    cache="$(sandbox_read_cache "nfs")"
    assert_metric_equals "${cache}" "nedge_nfs_service_status" "-3" \
        'service="nfssvc1"'
}

@test "post-install: warmup sequence converges over 5 scrapes" {
    mock_nfs_healthy

    local prev_body=""
    local i

    for i in 1 2 3 4 5; do
        local resp
        resp="$(http_get_metrics "${NFS_SCRIPT}")"
        local body
        body="$(http_extract_body "${resp}")"
        local trimmed
        trimmed="$(echo "${body}" | tr -d '[:space:]')"

        if [[ "${i}" -eq 1 ]]; then
            # First scrape: always empty (no prior cache)
            [[ -z "${trimmed}" ]]
        fi

        if [[ "${i}" -ge 2 ]]; then
            # From second scrape onward: should have data
            [[ -n "${trimmed}" ]]
        fi

        _sandbox_wait_background
        prev_body="${body}"
    done

    # After 5 scrapes, the final response should be stable and correct
    assert_metric_equals "${prev_body}" "nedge_nfs_service_status" "1" \
        'service="nfssvc1"'
}

@test "post-install: service transitions from down to up during warmup" {
    # Services start as down
    mock_nfs_not_mounted

    # Scrape 1: empty (no cache)
    local resp1
    resp1="$(http_get_metrics "${NFS_SCRIPT}")"
    _sandbox_wait_background

    # Cache now has -3
    local cache1
    cache1="$(sandbox_read_cache "nfs")"
    assert_metric_equals "${cache1}" "nedge_nfs_service_status" "-3" \
        'service="nfssvc1"'

    # Services come up
    mock_nfs_healthy

    # Scrape 2: returns stale -3 (from scrape 1)
    local resp2
    resp2="$(http_get_metrics "${NFS_SCRIPT}")"
    local body2
    body2="$(http_extract_body "${resp2}")"
    assert_metric_equals "${body2}" "nedge_nfs_service_status" "-3" \
        'service="nfssvc1"'
    _sandbox_wait_background

    # Cache now has 1 (from scrape 2's bg)
    local cache2
    cache2="$(sandbox_read_cache "nfs")"
    assert_metric_equals "${cache2}" "nedge_nfs_service_status" "1" \
        'service="nfssvc1"'

    # Scrape 3: returns correct value (1)
    local resp3
    resp3="$(http_get_metrics "${NFS_SCRIPT}")"
    local body3
    body3="$(http_extract_body "${resp3}")"
    assert_metric_equals "${body3}" "nedge_nfs_service_status" "1" \
        'service="nfssvc1"'
}

@test "post-install: trace log documents the full warmup timeline" {
    mock_nfs_healthy

    for i in 1 2 3; do
        http_get_metrics "${NFS_SCRIPT}" >/dev/null
        _sandbox_wait_background
    done

    # Verify trace has the expected structure
    local starts
    starts="$(trace_count 'START')"
    [[ "${starts}" -ge 3 ]]

    local ends
    ends="$(trace_count 'END')"
    [[ "${ends}" -ge 3 ]]

    # Should have PRE and POST cache state entries
    trace_has "PRE_STATE"
    trace_has "POST_STATE"
}
