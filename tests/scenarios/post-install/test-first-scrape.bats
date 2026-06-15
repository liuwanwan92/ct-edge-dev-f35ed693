#!/usr/bin/env bats
# =============================================================================
# Scenario: post-install / first scrape
# ---------------------------------------------------------------------------
# Very first Prometheus scrape after a fresh NexentaEdge installation.
# No cache files exist yet, so every service must return an empty body
# (Prometheus sees no metrics until the background collector finishes).
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

@test "post-install: NFS first scrape returns empty (no prior cache)" {
    # All mocks are healthy, but there is no cache on disk yet.
    mock_nfs_healthy

    local resp
    resp="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp"

    local body
    body="$(http_extract_body "$resp")"

    # First scrape must return an empty body — nothing cached yet.
    [[ -z "$body" ]]

    # Cache should NOT exist before the background finishes.
    ! sandbox_cache_exists nfs
}

@test "post-install: iSCSI first scrape returns empty" {
    mock_iscsi_healthy

    local resp
    resp="$(http_get_metrics "$ISCSI_SCRIPT")"
    assert_http_200 "$resp"

    local body
    body="$(http_extract_body "$resp")"
    [[ -z "$body" ]]

    ! sandbox_cache_exists iscsi
}

@test "post-install: S3 first scrape returns empty" {
    mock_s3_healthy

    local resp
    resp="$(http_get_metrics "$S3_SCRIPT")"
    assert_http_200 "$resp"

    local body
    body="$(http_extract_body "$resp")"
    [[ -z "$body" ]]

    ! sandbox_cache_exists s3
}

@test "post-install: all 3 services first scrape are empty" {
    # Verify that scraping all three services in a row yields empty bodies
    # for each, confirming that no cross-service cache pollution occurs.
    mock_nfs_healthy
    mock_iscsi_healthy
    mock_s3_healthy

    local nfs_body iscsi_body s3_body
    nfs_body="$(http_extract_body "$(http_get_metrics "$NFS_SCRIPT")")"
    iscsi_body="$(http_extract_body "$(http_get_metrics "$ISCSI_SCRIPT")")"
    s3_body="$(http_extract_body "$(http_get_metrics "$S3_SCRIPT")")"

    [[ -z "$nfs_body" ]]
    [[ -z "$iscsi_body" ]]
    [[ -z "$s3_body" ]]
}
