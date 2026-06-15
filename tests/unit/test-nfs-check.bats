#!/usr/bin/env bats
# test-nfs-check.bats - Unit tests for nfs_check() function
#
# Tests the NFS health check logic with mocked system commands.
#
# IMPORTANT: Due to the stale-cache architecture (bug we're documenting),
# the first scrape always returns empty. We need TWO scrapes:
#   Scrape 1: primes the cache (background writes check results)
#   Scrape 2: returns cached data from scrape 1

load '../lib/test_helper'

setup() {
    sandbox_create
    mock_reset_all
    trace_init
    # NOTE: Do NOT call mock_ps_fast_fail here. Some tests use counter-based
    # ps scenarios that must take priority over a blanket ps exit-1 mock.
    mock_set_response sleep "" 0
    mock_set_response hostname "testhost"

    NFS_SCRIPT="$(get_nfs_script)"
}

teardown() {
    if [[ "${BATS_TEST_COMPLETED:-}" != "1" ]]; then
        echo "--- TRACE LOG ---" >&3
        trace_dump 3
        echo "--- END TRACE ---" >&3
    fi
    sandbox_destroy
}

# Helper: scrape twice and return the second response body
_nfs_scrape_twice() {
    http_get_metrics "${NFS_SCRIPT}" >/dev/null  # prime cache
    local response
    response="$(http_get_metrics "${NFS_SCRIPT}")"
    http_extract_body "${response}"
}

@test "NFS: all checks pass returns status 1 (fully available)" {
    mock_nfs_healthy

    local body
    body="$(_nfs_scrape_twice)"

    assert_prom_help "${body}" "nedge_nfs_service_status"
    assert_prom_type "${body}" "nedge_nfs_service_status" "gauge"
    assert_metric_equals "${body}" "nedge_nfs_service_status" "1" \
        'service="nfssvc1"'
}

@test "NFS: not mounted returns status -3" {
    mock_nfs_not_mounted

    local body
    body="$(_nfs_scrape_twice)"

    assert_metric_equals "${body}" "nedge_nfs_service_status" "-3" \
        'service="nfssvc1"'
}

@test "NFS: showmount timeout returns status -2" {
    # The production script checks showmount via ps polling (timeout detection),
    # NOT via showmount's exit code. Use the showmount-hang scenario which
    # makes ps always return 0 (process alive), causing the timeout path.
    mock_load_scenario nfs showmount-hang

    local body
    body="$(_nfs_scrape_twice)"

    assert_metric_equals "${body}" "nedge_nfs_service_status" "-2" \
        'service="nfssvc1"'
}

@test "NFS: df timeout returns status -1" {
    # The df-hang scenario uses a ps counter that works best with 1 service.
    # Create a custom script with only 1 NFS service.
    local custom_script
    custom_script="$(create_nfs_script "nfssvc1" "/mnt/nfssvc1")"

    mock_load_scenario nfs df-hang

    http_get_metrics "${custom_script}" >/dev/null  # prime cache
    local response
    response="$(http_get_metrics "${custom_script}")"
    local body
    body="$(http_extract_body "${response}")"

    assert_metric_equals "${body}" "nedge_nfs_service_status" "-1" \
        'service="nfssvc1"'
}

@test "NFS: rpcinfo not ready returns status 0 (partially available)" {
    # rpcinfo output IS checked by the production script (via egrep),
    # so the direct mock approach works here.
    # Use a single-service script for simpler ps handling.
    local custom_script
    custom_script="$(create_nfs_script "nfssvc1" "/mnt/nfssvc1")"

    mock_set_response mount \
        "10.0.0.1:/export on /mnt/nfssvc1 type nfs (rw,addr=10.0.0.1)"
    mock_set_exit showmount 0
    mock_set_exit df 0
    mock_set_response rpcinfo "100003    3   udp   2049  nfs  not ready"
    mock_ps_fast_fail

    http_get_metrics "${custom_script}" >/dev/null  # prime cache
    local response
    response="$(http_get_metrics "${custom_script}")"
    local body
    body="$(http_extract_body "${response}")"

    assert_metric_equals "${body}" "nedge_nfs_service_status" "0" \
        'service="nfssvc1"'
}

@test "NFS: prom_export writes valid Prometheus format to cache" {
    mock_nfs_healthy

    # First scrape primes cache
    http_get_metrics "${NFS_SCRIPT}" >/dev/null

    # Cache should now exist with valid content
    sandbox_cache_exists "nfs"
    local cache
    cache="$(sandbox_read_cache "nfs")"
    assert_prom_help "${cache}" "nedge_nfs_service_status"
    assert_prom_type "${cache}" "nedge_nfs_service_status" "gauge"

    # Should have metric lines for both services
    local count
    count="$(prom_metric_count "${cache}" "nedge_nfs_service_status")"
    [[ "${count}" -eq 2 ]]
}

@test "NFS: metric includes correct labels (service, path, hostname, namespace)" {
    mock_nfs_healthy

    local body
    body="$(_nfs_scrape_twice)"

    # Check that the metric line contains all expected labels
    local metric_line
    metric_line="$(echo "${body}" | grep 'service="nfssvc1"')"
    [[ "${metric_line}" == *'path="/mnt/nfssvc1"'* ]]
    [[ "${metric_line}" == *'hostname="'* ]]
    [[ "${metric_line}" == *'namespace="nedge"'* ]]
}
