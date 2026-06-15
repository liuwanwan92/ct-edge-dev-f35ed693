#!/usr/bin/env bats
# =============================================================================
# Scenario: multi-node / node independence
# ---------------------------------------------------------------------------
# Verifies that cache and mock state are isolated per-run.  Since the test
# harness uses a single sandbox, we simulate multi-node isolation by:
#   Test 1 — cross-service isolation: NFS cache does not affect iSCSI.
#   Test 2 — temporal isolation: two sequential runs with different mocks
#            produce different results, proving each run is independent.
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

@test "multi-node: node1 cache does not leak to node2" {
    # Cross-service isolation: inject NFS cache, verify iSCSI is unaffected.
    sandbox_inject_fixture nfs nfs-healthy.prom

    mock_iscsi_healthy

    local resp body
    resp="$(http_get_metrics "$ISCSI_SCRIPT")"
    assert_http_200 "$resp"
    body="$(http_extract_body "$resp")"

    # iSCSI should have no cache → empty body, even though NFS has one.
    [[ -z "$body" ]]
    ! sandbox_cache_exists iscsi
}

@test "multi-node: different mock states per node produce different results" {
    # Simulate two "nodes" by running two sequential checks with different
    # mock configurations.

    # ---- "Node 1": healthy mocks ---------------------------------------
    sandbox_inject_fixture nfs nfs-healthy.prom
    mock_nfs_healthy

    local resp1 body1
    resp1="$(http_get_metrics "$NFS_SCRIPT")"
    body1="$(http_extract_body "$resp1")"
    assert_metric_equals "$body1" "nexenta_nfs_mount_status" "1"

    # ---- "Node 2": inject error cache, different mocks -----------------
    sandbox_inject_fixture nfs nfs-stale-error.prom
    mock_nfs_not_mounted

    local resp2 body2
    resp2="$(http_get_metrics "$NFS_SCRIPT")"
    body2="$(http_extract_body "$resp2")"

    # The two responses must differ — each "node" sees its own cache.
    [[ "$body1" != "$body2" ]]
    # Node 2 should show the error value.
    [[ "$body2" == *"-3"* ]] || [[ "$body2" == *"-2"* ]]
}
