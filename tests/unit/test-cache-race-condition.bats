#!/usr/bin/env bats
# test-cache-race-condition.bats - Bug reproduction tests
#
# These tests VERIFY that the cache race condition bugs exist in the
# production scripts. They PASS when the bugs are present (current state)
# and will FAIL when someone fixes the production scripts.
#
# This is intentional: these tests serve as living documentation that
# proves the flaky behavior is reproducible.
#
# The bugs (present in all 3 health check scripts):
#   1. First invocation returns empty (no cache file, background not done)
#   2. Second invocation returns stale result from first run
#   3. Non-atomic write ("> $tmpfile" truncates before writing)
#   4. Cache persists across upgrades without cleanup
#   5. No file locking for concurrent access

load '../lib/test_helper'

setup() {
    sandbox_create
    mock_reset_all
    trace_init
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

# ============================================================
# Bug 1: First invocation returns empty output
# ============================================================

@test "BUG-REPRO: NFS first invocation returns empty body (no cache yet)" {
    mock_nfs_healthy

    # Do NOT inject any cache file - this is a fresh start
    ! sandbox_cache_exists "nfs"

    # First scrape: script has no cache, returns stale (nothing) and
    # starts background refresh
    local response
    response="$(http_get_metrics "${NFS_SCRIPT}")"

    assert_http_200 "${response}"
    local body
    body="$(http_extract_body "${response}")"

    # The body should be EMPTY because:
    #   - No cache file existed (cat found nothing)
    #   - Background process hasn't finished writing yet
    # This is the bug: Prometheus sees no metrics on first scrape
    local trimmed
    trimmed="$(echo "${body}" | tr -d '[:space:]')"
    [[ -z "${trimmed}" ]]
}

@test "BUG-REPRO: iSCSI first invocation returns empty body" {
    mock_iscsi_healthy
    ! sandbox_cache_exists "iscsi"

    local response
    response="$(http_get_metrics "${ISCSI_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"
    local trimmed
    trimmed="$(echo "${body}" | tr -d '[:space:]')"
    [[ -z "${trimmed}" ]]
}

@test "BUG-REPRO: S3 first invocation returns empty body" {
    mock_s3_healthy
    ! sandbox_cache_exists "s3"

    local response
    response="$(http_get_metrics "${S3_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"
    local trimmed
    trimmed="$(echo "${body}" | tr -d '[:space:]')"
    [[ -z "${trimmed}" ]]
}

# ============================================================
# Bug 2: Second invocation returns STALE result from first run
# ============================================================

@test "BUG-REPRO: NFS second invocation returns stale cache from first run" {
    # Inject an ERROR state cache (simulating a previous failed check)
    sandbox_inject_fixture "nfs" "nfs-stale-error.prom"

    # Now mock everything as healthy
    mock_nfs_healthy

    # Second scrape: should return the STALE error data (-3, -2)
    # because the background refresh hasn't overwritten the cache yet
    local response
    response="$(http_get_metrics "${NFS_SCRIPT}")"

    assert_http_200 "${response}"
    local body
    body="$(http_extract_body "${response}")"

    # The stale cache says -3 (not mounted), but services are actually healthy
    # This is the bug: Prometheus sees stale error state
    assert_metric_equals "${body}" "nedge_nfs_service_status" "-3" \
        'service="nfssvc1"'
}

@test "BUG-REPRO: NFS stale healthy cache masks service failure" {
    # Inject a HEALTHY cache (simulating pre-upgrade state)
    sandbox_inject_fixture "nfs" "nfs-healthy.prom"

    # Now mock everything as DOWN (post-upgrade, services not started)
    mock_nfs_not_mounted

    local response
    response="$(http_get_metrics "${NFS_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"

    # Stale cache says 1 (healthy), but services are actually down (-3)
    # This is the bug: false positive, Prometheus thinks everything is fine
    assert_metric_equals "${body}" "nedge_nfs_service_status" "1" \
        'service="nfssvc1"'
}

# ============================================================
# Bug 3: Cache persists across simulated upgrade
# ============================================================

@test "BUG-REPRO: cache from before upgrade poisons post-upgrade checks" {
    # Phase 1: Simulate pre-upgrade state - services were healthy
    sandbox_inject_fixture "nfs" "nfs-healthy.prom"

    # Verify cache shows healthy
    local cache_before
    cache_before="$(sandbox_read_cache "nfs")"
    assert_metric_equals "${cache_before}" "nedge_nfs_service_status" "1" \
        'service="nfssvc1"'

    # Phase 2: Simulate upgrade - services go down for restart
    # (We do NOT clean the cache - this is the bug)
    mock_nfs_not_mounted

    # First post-upgrade check sees stale healthy data
    local response
    response="$(http_get_metrics "${NFS_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"

    # BUG: Prometheus sees "1" (healthy) but services are actually down
    assert_metric_equals "${body}" "nedge_nfs_service_status" "1" \
        'service="nfssvc1"'
}

# ============================================================
# Bug 4: Empty/truncated cache file served as valid output
# ============================================================

@test "BUG-REPRO: empty cache file (truncation race) produces empty metrics" {
    # Inject an empty cache file (simulates reading during > truncation)
    sandbox_inject_fixture "nfs" "empty.prom"

    mock_nfs_healthy

    local response
    response="$(http_get_metrics "${NFS_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"

    # The script cat's the empty file and serves it as the response
    # No metrics, no HELP/TYPE lines - just empty
    local trimmed
    trimmed="$(echo "${body}" | tr -d '[:space:]')"
    [[ -z "${trimmed}" ]]
}

@test "BUG-REPRO: corrupt/truncated cache file served without validation" {
    # Inject a corrupt cache (truncated mid-write)
    sandbox_inject_fixture "nfs" "corrupt.prom"

    mock_nfs_healthy

    local response
    response="$(http_get_metrics "${NFS_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"

    # The script serves the corrupt file as-is
    # It contains HELP and TYPE but the metric line is truncated
    echo "${body}" | grep -q "nedge_nfs_service_status"
    # But the value is missing (just whitespace at the end)
    local metric_line
    metric_line="$(echo "${body}" | grep "nedge_nfs_service_status{" | head -1)"
    # The line should end with a space (no value) - this is the corruption
    [[ "${metric_line}" =~ \}[[:space:]]*$ ]]
}

# ============================================================
# Bug 5: Consecutive scrapes show stale-cache pipeline behavior
# ============================================================

@test "BUG-REPRO: three consecutive NFS scrapes show stale pipeline" {
    mock_nfs_healthy

    # Scrape 1: no cache → empty body
    local resp1
    resp1="$(http_get_metrics "${NFS_SCRIPT}")"
    local body1
    body1="$(http_extract_body "${resp1}")"
    local trim1
    trim1="$(echo "${body1}" | tr -d '[:space:]')"
    [[ -z "${trim1}" ]]

    # Wait for background to write cache
    _sandbox_wait_background

    # Scrape 2: now has cache from scrape 1's background
    local resp2
    resp2="$(http_get_metrics "${NFS_SCRIPT}")"
    local body2
    body2="$(http_extract_body "${resp2}")"

    # This should have data (from scrape 1's background write)
    # The data is from the HEALTHY mock
    local trim2
    trim2="$(echo "${body2}" | tr -d '[:space:]')"
    [[ -n "${trim2}" ]]
    assert_metric_equals "${body2}" "nedge_nfs_service_status" "1" \
        'service="nfssvc1"'
}
