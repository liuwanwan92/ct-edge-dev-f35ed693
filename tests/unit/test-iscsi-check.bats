#!/usr/bin/env bats
# test-iscsi-check.bats - Unit tests for iscsi_check() function
#
# Tests the iSCSI health check logic with mocked iscsi-ls command.

load '../lib/test_helper'

setup() {
    sandbox_create
    mock_reset_all
    trace_init
    mock_set_response sleep "" 0
    mock_set_response hostname "testhost"

    ISCSI_SCRIPT="$(get_iscsi_script)"
}

teardown() {
    if [[ "${BATS_TEST_COMPLETED:-}" != "1" ]]; then
        echo "--- TRACE LOG ---" >&3
        trace_dump 3
    fi
    sandbox_destroy
}

@test "iSCSI: target found with LUN returns status 1" {
    mock_iscsi_healthy

    http_get_metrics "${ISCSI_SCRIPT}" >/dev/null
    local response
    response="$(http_get_metrics "${ISCSI_SCRIPT}")"

    assert_http_200 "${response}"
    local body
    body="$(http_extract_body "${response}")"
    assert_prom_help "${body}" "nedge_iscsi_service_status"
    assert_metric_equals "${body}" "nedge_iscsi_service_status" "1" \
        'service="iscsisvc"'
}

@test "iSCSI: target not discoverable returns status -1" {
    mock_iscsi_no_targets

    http_get_metrics "${ISCSI_SCRIPT}" >/dev/null
    local response
    response="$(http_get_metrics "${ISCSI_SCRIPT}")"

    assert_http_200 "${response}"
    local body
    body="$(http_extract_body "${response}")"
    assert_metric_equals "${body}" "nedge_iscsi_service_status" "-1" \
        'service="iscsisvc"'
}

@test "iSCSI: target found but LUN missing returns status 0" {
    mock_iscsi_no_luns

    http_get_metrics "${ISCSI_SCRIPT}" >/dev/null
    local response
    response="$(http_get_metrics "${ISCSI_SCRIPT}")"

    assert_http_200 "${response}"
    local body
    body="$(http_extract_body "${response}")"
    assert_metric_equals "${body}" "nedge_iscsi_service_status" "0" \
        'service="iscsisvc"'
}

@test "iSCSI: prom_export writes valid Prometheus format to cache" {
    mock_iscsi_healthy

    http_get_metrics "${ISCSI_SCRIPT}" >/dev/null

    sandbox_cache_exists "iscsi"
    local cache
    cache="$(sandbox_read_cache "iscsi")"
    assert_prom_help "${cache}" "nedge_iscsi_service_status"
    assert_prom_type "${cache}" "nedge_iscsi_service_status" "gauge"

    local count
    count="$(prom_metric_count "${cache}" "nedge_iscsi_service_status")"
    [[ "${count}" -eq 2 ]]
}

@test "iSCSI: metric includes service and path labels" {
    mock_iscsi_healthy

    http_get_metrics "${ISCSI_SCRIPT}" >/dev/null
    local response
    response="$(http_get_metrics "${ISCSI_SCRIPT}")"
    local body
    body="$(http_extract_body "${response}")"

    local metric_line
    metric_line="$(echo "${body}" | grep 'service="iscsisvc"')"
    [[ "${metric_line}" == *'path="iscsi://'* ]]
    [[ "${metric_line}" == *'hostname="'* ]]
    [[ "${metric_line}" == *'namespace="nedge"'* ]]
}
