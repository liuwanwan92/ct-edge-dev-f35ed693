#!/usr/bin/env bats
# test-post-upgrade-flow.bats - Integration test for post-upgrade scenario
#
# Simulates the sequence of events after a NexentaEdge upgrade:
#   1. Pre-upgrade cache exists with healthy values
#   2. Services restart (go down, come back)
#   3. First post-upgrade check returns STALE pre-upgrade data
#   4. This creates false positives/negatives

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

@test "upgrade: stale healthy cache masks post-upgrade service failure" {
    # Phase 1: Pre-upgrade - services are healthy, cache exists
    sandbox_inject_fixture "nfs" "nfs-healthy.prom"

    # Phase 2: Upgrade happens - services go down for restart
    mock_nfs_not_mounted

    # First post-upgrade scrape
    local response
    response="$(http_get_metrics "${NFS_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"

    # BUG: Prometheus sees healthy (1) from stale cache
    # but services are actually DOWN
    assert_metric_equals "${body}" "nedge_nfs_service_status" "1" \
        'service="nfssvc1"'

    # Verify trace shows this is a stale read
    trace_has "PRE_STATE.*status=.*[0-9]"
}

@test "upgrade: stale error cache causes false alarm post-upgrade" {
    # Phase 1: Pre-upgrade - services had errors, cache has error values
    sandbox_inject_fixture "nfs" "nfs-stale-error.prom"

    # Phase 2: Upgrade succeeds - services are now healthy
    mock_nfs_healthy

    # First post-upgrade scrape
    local response
    response="$(http_get_metrics "${NFS_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"

    # BUG: Prometheus sees -3 (not mounted) from stale cache
    # but services are actually healthy
    assert_metric_equals "${body}" "nedge_nfs_service_status" "-3" \
        'service="nfssvc1"'
}

@test "upgrade: cache from different hostname leaks incorrect labels" {
    # Inject cache with a different hostname (from before upgrade/hostname change)
    sandbox_inject_cache "nfs" \
        "# HELP nedge_nfs_service_status NFS service client access status
# TYPE nedge_nfs_service_status gauge
nedge_nfs_service_status{service=\"nfssvc1\",path=\"/mnt/nfssvc1\",hostname=\"old-hostname\",namespace=\"nedge\"} 1"

    mock_nfs_healthy

    local response
    response="$(http_get_metrics "${NFS_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"

    # The stale cache has the OLD hostname
    echo "${body}" | grep -q 'hostname="old-hostname"'
    # NOT the current hostname
    refute_metric "$(echo "${body}" | grep -v 'old-hostname')" \
        "nedge_nfs_service_status" || true
}

@test "upgrade: cache eventually corrects after 2 scrapes" {
    # Stale healthy cache + services down
    sandbox_inject_fixture "nfs" "nfs-healthy.prom"
    mock_nfs_not_mounted

    # Scrape 1: returns stale healthy (BUG)
    local resp1
    resp1="$(http_get_metrics "${NFS_SCRIPT}")"
    local body1
    body1="$(http_extract_body "${resp1}")"
    assert_metric_equals "${body1}" "nedge_nfs_service_status" "1" \
        'service="nfssvc1"'

    _sandbox_wait_background

    # Scrape 2: returns data from scrape 1's background (-3)
    local resp2
    resp2="$(http_get_metrics "${NFS_SCRIPT}")"
    local body2
    body2="$(http_extract_body "${resp2}")"
    assert_metric_equals "${body2}" "nedge_nfs_service_status" "-3" \
        'service="nfssvc1"'

    # After 2 scrapes, the correct state is visible
}

@test "upgrade: iSCSI stale cache behavior matches NFS pattern" {
    # Same bug pattern in iSCSI
    sandbox_inject_fixture "iscsi" "iscsi-healthy.prom"
    mock_iscsi_no_targets

    local response
    response="$(http_get_metrics "${ISCSI_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"

    # Stale healthy data despite targets being unavailable
    assert_metric_equals "${body}" "nedge_iscsi_service_status" "1" \
        'service="iscsisvc"'
}

@test "upgrade: S3 stale cache behavior matches NFS pattern" {
    sandbox_inject_fixture "s3" "s3-healthy.prom"
    mock_s3_service_down

    local response
    response="$(http_get_metrics "${S3_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"

    assert_metric_equals "${body}" "nedge_s3_service_status" "1" \
        'service="s3svc1"'
}
