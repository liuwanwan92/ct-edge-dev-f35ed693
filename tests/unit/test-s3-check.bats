#!/usr/bin/env bats
# test-s3-check.bats - Unit tests for s3_check() function
#
# Tests the S3 health check logic with mocked curl/openssl commands.

load '../lib/test_helper'

setup() {
    sandbox_create
    mock_reset_all
    trace_init
    mock_set_response sleep "" 0
    mock_set_response hostname "testhost"

    S3_SCRIPT="$(get_s3_script)"
}

teardown() {
    if [[ "${BATS_TEST_COMPLETED:-}" != "1" ]]; then
        echo "--- TRACE LOG ---" >&3
        trace_dump 3
    fi
    sandbox_destroy
}

@test "S3: object HEAD succeeds returns status 1" {
    mock_s3_healthy

    http_get_metrics "${S3_SCRIPT}" >/dev/null
    local response
    response="$(http_get_metrics "${S3_SCRIPT}")"

    assert_http_200 "${response}"
    local body
    body="$(http_extract_body "${response}")"
    assert_prom_help "${body}" "nedge_s3_service_status"
    assert_metric_equals "${body}" "nedge_s3_service_status" "1" \
        'service="s3svc1"'
}

@test "S3: service unreachable returns status -2" {
    mock_s3_service_down

    http_get_metrics "${S3_SCRIPT}" >/dev/null
    local response
    response="$(http_get_metrics "${S3_SCRIPT}")"

    assert_http_200 "${response}"
    local body
    body="$(http_extract_body "${response}")"
    assert_metric_equals "${body}" "nedge_s3_service_status" "-2" \
        'service="s3svc1"'
}

@test "S3: bucket HEAD succeeds but object fails returns status 0" {
    # Need a scenario handler for curl that returns different results per call
    mock_set_scenario curl s3 bucket-only

    http_get_metrics "${S3_SCRIPT}" >/dev/null
    local response
    response="$(http_get_metrics "${S3_SCRIPT}")"

    assert_http_200 "${response}"
    local body
    body="$(http_extract_body "${response}")"
    assert_metric_equals "${body}" "nedge_s3_service_status" "0" \
        'service="s3svc1"'
}

@test "S3: object+bucket fail, service responds 403 returns status -1" {
    mock_set_scenario curl s3 object-fail

    http_get_metrics "${S3_SCRIPT}" >/dev/null
    local response
    response="$(http_get_metrics "${S3_SCRIPT}")"

    assert_http_200 "${response}"
    local body
    body="$(http_extract_body "${response}")"
    assert_metric_equals "${body}" "nedge_s3_service_status" "-1" \
        'service="s3svc1"'
}

@test "S3: prom_export writes valid Prometheus format to cache" {
    mock_s3_healthy

    http_get_metrics "${S3_SCRIPT}" >/dev/null

    sandbox_cache_exists "s3"
    local cache
    cache="$(sandbox_read_cache "s3")"
    assert_prom_help "${cache}" "nedge_s3_service_status"
    assert_prom_type "${cache}" "nedge_s3_service_status" "gauge"

    local count
    count="$(prom_metric_count "${cache}" "nedge_s3_service_status")"
    [[ "${count}" -eq 1 ]]
}
