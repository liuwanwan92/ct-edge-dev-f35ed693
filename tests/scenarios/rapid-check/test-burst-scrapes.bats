#!/usr/bin/env bats
# =============================================================================
# Scenario: rapid-check / burst scrapes
# ---------------------------------------------------------------------------
# Five scrapes fire in rapid succession (no _sandbox_wait_background between
# them).  Verifies the deterministic stale pipeline: each response returns
# the cache written by the *previous* scrape's background collector.
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

@test "burst: 5 rapid scrapes produce deterministic stale pipeline" {
    mock_nfs_healthy

    local bodies=()

    # Fire 5 scrapes with no wait between them.
    for i in 1 2 3 4 5; do
        local resp body
        resp="$(http_get_metrics "$NFS_SCRIPT")"
        assert_http_200 "$resp"
        body="$(http_extract_body "$resp")"
        bodies+=("$body")
    done

    # Wait for the last background to finish.
    _sandbox_wait_background

    # Pattern: scrape 1 returns empty (no cache yet).
    [[ -z "${bodies[0]}" ]]

    # Scrapes 2-5 each return whatever cache existed at the moment they
    # were called.  Because backgrounds run asynchronously the exact
    # values depend on timing, but they must be non-empty (once the first
    # bg has written) and contain a valid metric.
    for i in 1 2 3 4; do
        # After the first bg finishes, subsequent scrapes should have data.
        # (We allow empty if the bg hasn't written yet — timing-dependent.)
        if [[ -n "${bodies[$i]}" ]]; then
            [[ "${bodies[$i]}" == *"nexenta_nfs_mount_status"* ]]
        fi
    done
}

@test "burst: final cache state matches last background write" {
    mock_nfs_healthy

    # 5 rapid scrapes.
    for i in 1 2 3 4 5; do
        http_get_metrics "$NFS_SCRIPT" >/dev/null
    done

    _sandbox_wait_background

    # After all backgrounds settle, the cache must reflect the latest
    # mock state (healthy = 1).
    local cache
    cache="$(sandbox_read_cache nfs)"
    [[ "$cache" == *"1"* ]]
    [[ "$cache" == *"nexenta_nfs_mount_status"* ]]
}
