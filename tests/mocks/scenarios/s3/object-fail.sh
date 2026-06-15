#!/usr/bin/env bash
# Scenario: S3 object-fail
#
# Both the object HEAD and bucket HEAD requests fail, but the service
# is reachable (unauthenticated request gets 403 Forbidden instead of
# a connection error). This means the S3 service is running but
# authentication or authorization is failing.
#
# Expected result: -1 (service object HEAD failed, service is reachable)
#
# Production script flow:
#   1. openssl | base64 → HMAC signature
#   2. curl (object HEAD): no "200 OK" → fail
#   3. curl (bucket HEAD): no "200 OK" → fail
#   4. curl (service check, unauthenticated): grep "403 Forbidden" → match
#      → echo "-1"
#
# Curl call sequence (counter-based):
#   Call 1 (object HEAD, auth):    "HTTP/1.1 403 Forbidden" (no "200 OK")
#   Call 2 (bucket HEAD, auth):    "HTTP/1.1 403 Forbidden" (no "200 OK")
#   Call 3 (service check, noauth): "HTTP/1.1 403 Forbidden" (matches grep)

scenario_setup() {
    # openssl and base64 work normally for HMAC generation
    mock_set_response openssl "dummy_hmac_binary_data"
    mock_set_response base64 "dGVzdA=="

    # Clear any direct curl response so the scenario handler takes priority
    unset MOCK_RESPONSE_CURL 2>/dev/null || true
    unset MOCK_EXIT_CURL 2>/dev/null || true

    # Initialize the curl call counter
    local counter_file="${NEDGE_SANDBOX_TMP:-/tmp}/mock-curl-counter"
    echo "0" > "${counter_file}"

    # Point the curl shim to this scenario file for handler dispatch
    local scenario_file="${MOCK_ROOT}/scenarios/s3/object-fail.sh"
    export "MOCK_SCENARIO_CURL=${scenario_file}"
}

# Context-aware curl handler: all calls return 403 Forbidden.
# - Calls 1-2 (authenticated): grep for "200 OK" fails
# - Call 3 (unauthenticated): grep for "403 Forbidden" succeeds → result -1
mock_curl_handler() {
    local counter_file="${NEDGE_SANDBOX_TMP:-/tmp}/mock-curl-counter"
    local count=0

    # Read and increment the call counter
    if [[ -f "${counter_file}" ]]; then
        count=$(cat "${counter_file}" 2>/dev/null || echo 0)
    fi
    count=$((count + 1))
    echo "${count}" > "${counter_file}"

    # All calls return 403 Forbidden.
    # The production script greps for "200 OK" on calls 1-2 (fails),
    # then greps for "403 Forbidden" on call 3 (succeeds).
    echo "HTTP/1.1 403 Forbidden"
    echo "Content-Type: application/xml"
    echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    echo "<Error><Code>AccessDenied</Code></Error>"
    return 0
}
