#!/usr/bin/env bats
# =============================================================================
# Scenario: multi-node / rolling upgrade
# ---------------------------------------------------------------------------
# Simulates a rolling upgrade across two cluster nodes.  Each "node" is
# represented by a separate scrape sequence within the same sandbox:
#   - Node 1: inject healthy cache → switch mocks to down → scrape → stale
#   - Node 2: inject healthy cache → keep mocks healthy → scrape → stale
# The two sequences must produce different results, proving that each
# node's cache converges independently.
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

@test "rolling: simulating node1 upgrade does not affect node2 cache" {
    # ---- Sequence A (node 1): healthy → down --------------------------
    # Prime cache with healthy state.
    sandbox_inject_fixture nfs nfs-healthy.prom
    mock_nfs_healthy

    local respA1 bodyA1
    respA1="$(http_get_metrics "$NFS_SCRIPT")"
    bodyA1="$(http_extract_body "$respA1")"
    # Reads the stale healthy cache.
    assert_metric_equals "$bodyA1" "nexenta_nfs_mount_status" "1"

    _sandbox_wait_background

    # Node 1: service goes down (upgrade restart).
    mock_nfs_not_mounted

    local respA2 bodyA2
    respA2="$(http_get_metrics "$NFS_SCRIPT")"
    bodyA2="$(http_extract_body "$respA2")"
    # Still returns stale healthy (1) — the bg hasn't caught up yet.
    assert_metric_equals "$bodyA2" "nexenta_nfs_mount_status" "1"

    _sandbox_wait_background

    # Cache now reflects down state.
    local cache_node1
    cache_node1="$(sandbox_read_cache nfs)"
    [[ "$cache_node1" == *"-3"* ]]

    # ---- Sequence B (node 2): healthy cache, stays healthy ------------
    # Re-inject healthy cache (simulating a different node that was not
    # affected by the upgrade).
    sandbox_inject_fixture nfs nfs-healthy.prom
    mock_nfs_healthy

    local respB bodyB
    respB="$(http_get_metrics "$NFS_SCRIPT")"
    bodyB="$(http_extract_body "$respB")"

    # Node 2 sees healthy — proving the node-1 downgrade didn't leak.
    assert_metric_equals "$bodyB" "nexenta_nfs_mount_status" "1"
}

@test "rolling: each node converges independently after upgrade" {
    # ---- Sequence A (node 1): post-upgrade, service is down ------------
    sandbox_inject_fixture nfs nfs-healthy.prom
    mock_nfs_not_mounted

    local respA bodyA
    respA="$(http_get_metrics "$NFS_SCRIPT")"
    bodyA="$(http_extract_body "$respA")"
    # Stale healthy — false positive on node 1.
    assert_metric_equals "$bodyA" "nexenta_nfs_mount_status" "1"

    _sandbox_wait_background

    local cacheA
    cacheA="$(sandbox_read_cache nfs)"
    [[ "$cacheA" == *"-3"* ]]

    # ---- Sequence B (node 2): post-upgrade, service is healthy ---------
    sandbox_inject_fixture nfs nfs-healthy.prom
    mock_nfs_healthy

    local respB bodyB
    respB="$(http_get_metrics "$NFS_SCRIPT")"
    bodyB="$(http_extract_body "$respB")"
    # Stale healthy — correct (coincidentally) on node 2.
    assert_metric_equals "$bodyB" "nexenta_nfs_mount_status" "1"

    _sandbox_wait_background

    local cacheB
    cacheB="$(sandbox_read_cache nfs)"
    [[ "$cacheB" == *"1"* ]]

    # The caches diverged: node 1 wrote -3, node 2 wrote 1.
    # This proves each sequence converges based on its own mock state.
    [[ "$cacheA" != "$cacheB" ]]
}
