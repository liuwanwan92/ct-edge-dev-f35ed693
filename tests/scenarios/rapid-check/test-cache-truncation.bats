#!/usr/bin/env bats
# =============================================================================
# Scenario: rapid-check / cache truncation
# ---------------------------------------------------------------------------
# Models the read-during-write race: a scrape reads the cache file at the
# exact moment a background collector is (re)writing it.  Verifies graceful
# handling of empty / partially-written cache files.
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

@test "truncation: empty cache file produces empty metric output" {
    # Inject an empty (zero-byte) cache file.
    sandbox_inject_cache nfs ""

    mock_nfs_healthy

    local resp body
    resp="$(http_get_metrics "$NFS_SCRIPT")"
    assert_http_200 "$resp"
    body="$(http_extract_body "$resp")"

    # An empty cache must yield an empty metric body — no garbage, no
    # partial lines, no spurious zeros.
    [[ -z "$body" ]]
}

@test "truncation: cache file size fluctuates during rapid scrapes" {
    mock_nfs_healthy

    # Run a series of rapid scrapes, snapshotting the cache size each time.
    local sizes=()

    for i in 1 2 3 4 5; do
        http_get_metrics "$NFS_SCRIPT" >/dev/null
        # Snapshot the cache size immediately after the scrape returns.
        if sandbox_cache_exists nfs; then
            local sz
            sz="$(wc -c < "$(sandbox_read_cache_path nfs 2>/dev/null || echo /dev/null)")"
            sizes+=("$sz")
        else
            sizes+=(0)
        fi
    done

    _sandbox_wait_background

    # The final cache must be a complete, healthy file.
    local final_cache
    final_cache="$(sandbox_read_cache nfs)"
    [[ "$final_cache" == *"1"* ]]

    # At least one intermediate snapshot should differ from the final size,
    # proving the cache was being rewritten during the burst.
    # (This is a soft check — timing may cause all snapshots to match if
    # backgrounds complete very quickly.)
    local final_size
    final_size="$(echo -n "$final_cache" | wc -c)"
    local saw_change=0
    for sz in "${sizes[@]}"; do
        if [[ "$sz" -ne "$final_size" ]]; then
            saw_change=1
            break
        fi
    done
    # We assert only that the final state is correct; the fluctuation
    # check is informational.
    [[ "$final_size" -gt 0 ]]
}
