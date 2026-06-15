#!/usr/bin/env bats
# test-http-parsing.bats - Tests for the HTTP request handling in health check scripts
#
# Verifies the bash HTTP server implementation handles various request types correctly.

load '../lib/test_helper'

setup() {
    sandbox_create
    mock_reset_all
    trace_init
    mock_ps_fast_fail
    mock_set_response sleep "" 0
    mock_set_response hostname "testhost"

    NFS_SCRIPT="$(get_nfs_script)"
}

teardown() {
    if [[ "${BATS_TEST_COMPLETED:-}" != "1" ]]; then
        echo "--- TRACE LOG ---" >&3
        trace_dump 3
    fi
    sandbox_destroy
}

@test "HTTP: GET /metrics returns 200 OK" {
    mock_nfs_healthy
    local response
    response="$(http_get_metrics_sync "${NFS_SCRIPT}")"
    assert_http_200 "${response}"
}

@test "HTTP: GET /metrics includes Content-Type header" {
    mock_nfs_healthy
    local response
    response="$(http_get_metrics_sync "${NFS_SCRIPT}")"
    # Should contain the Prometheus content type
    echo "${response}" | grep -qi "text/plain"
}

@test "HTTP: POST /metrics returns 405 Method Not Allowed" {
    mock_nfs_healthy
    local response
    response="$(http_request "${NFS_SCRIPT}" "POST" "/metrics")"
    local code
    code="$(http_status_code "${response}")"
    [[ "${code}" == "405" ]]
}

@test "HTTP: GET /nonexistent returns 500 (no route match)" {
    mock_nfs_healthy
    local response
    response="$(http_request "${NFS_SCRIPT}" "GET" "/nonexistent")"
    local code
    code="$(http_status_code "${response}")"
    [[ "${code}" == "500" ]]
}

@test "HTTP: malformed request returns 400 Bad Request" {
    mock_nfs_healthy
    local response
    response="$(http_malformed_request "${NFS_SCRIPT}")"
    local code
    code="$(http_status_code "${response}")"
    [[ "${code}" == "400" ]]
}

@test "HTTP: response includes Server header" {
    mock_nfs_healthy
    local response
    response="$(http_get_metrics_sync "${NFS_SCRIPT}")"
    echo "${response}" | grep -qi "Server:"
}

@test "HTTP: response includes Date header" {
    mock_nfs_healthy
    local response
    response="$(http_get_metrics_sync "${NFS_SCRIPT}")"
    echo "${response}" | grep -qi "Date:"
}
