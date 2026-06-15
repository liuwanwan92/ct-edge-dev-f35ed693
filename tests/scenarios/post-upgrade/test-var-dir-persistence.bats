#!/usr/bin/env bats
# =============================================================================
# Scenario: post-upgrade / var/ directory persistence
# ---------------------------------------------------------------------------
# The var/ directory may contain leftover state from a previous install or
# upgrade.  These tests verify that the NFS check produces correct results
# regardless of what is (or isn't) in the var/ directory.
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

@test "var: old var/ state persists but does not affect NFS check results" {
    # Seed the SANDBOX_VAR directory with leftover files that might exist
    # after a previous installation (config fragments, PID files, logs).
    mkdir -p "${SANDBOX_VAR}/nfs" "${SANDBOX_VAR}/iscsi"
    echo "stale-nfs-state=1" > "${SANDBOX_VAR}/nfs/state.dat"
    echo "pid=99999"        > "${SANDBOX_VAR}/nfs/nfsd.pid"
    echo "old-log-entry"    > "${SANDBOX_VAR}/nfs/check.log"

    # Run the NFS check with healthy mocks.
    mock_nfs_healthy

    local resp body
    resp="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp"
    body="$(http_extract_body "$resp")"

    _sandbox_wait_background

    # The background collector must produce the correct healthy cache,
    # completely ignoring whatever was in var/.
    local cache
    cache="$(sandbox_read_cache nfs)"
    [[ "$cache" == *"1"* ]]
    [[ "$cache" != *"stale"* ]]
    [[ "$cache" != *"99999"* ]]
}

@test "var: empty var/ dir created for fresh install" {
    # Remove SANDBOX_VAR entirely to simulate a fresh install.
    rm -rf "${SANDBOX_VAR}"

    # The check script should still work and produce correct output.
    mock_nfs_healthy

    local resp body
    resp="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp"
    body="$(http_extract_body "$resp")"

    # First scrape — empty cache — returns empty body.
    [[ -z "$body" ]]

    _sandbox_wait_background

    # After background runs, cache should be healthy.
    local cache
    cache="$(sandbox_read_cache nfs)"
    [[ "$cache" == *"1"* ]]
}
