#!/usr/bin/env bash
# Scenario: S3 bucket-only
#
# The S3 object HEAD request fails (object not found or inaccessible),
# but the bucket HEAD request succeeds. This indicates partial availability:
# the service and bucket exist, but the specific object is missing.
#
# Expected result: 0 (service bucket HEAD OK, object HEAD failed)
#
# Production script flow:
#   1. openssl | base64 → HMAC signature (always works)
#   2. curl (object HEAD): output does NOT contain "200 OK" → fail
#   3. curl (bucket HEAD): output contains "200 OK" → echo "0"
#
# Curl call sequence (counter-based):
#   Call 1 (object HEAD): returns "HTTP/1.1 404 Not Found" (no "200 OK" match)
#   Call 2 (bucket HEAD): returns "HTTP/1.1 200 OK" (match → result 0)
#   Call 3+: not reached in this scenario

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
    local scenario_file="${MOCK_ROOT}/scenarios/s3/bucket-only.sh"
    export "MOCK_SCENARIO_CURL=${scenario_file}"
}

# Context-aware curl handler: returns different responses per call number.
# Call 1 (object HEAD): 404 Not Found — object doesn't exist
# Call 2 (bucket HEAD): 200 OK — bucket is accessible
# Call 3+ (service):    200 OK — fallback, shouldn't be reached
mock_curl_handler() {
    local counter_file="${NEDGE_SANDBOX_TMP:-/tmp}/mock-curl-counter"
    local count=0

    # Read and increment the call counter
    if [[ -f "${counter_file}" ]]; then
        count=$(cat "${counter_file}" 2>/dev/null || echo 0)
    fi
    count=$((count + 1))
    echo "${count}" > "${counter_file}"

    case ${count} in
        1)
            # Object HEAD: object not found, no "200 OK" in output
            echo "HTTP/1.1 404 Not Found"
            echo "Content-Type: application/xml"
            return 0
            ;;
        2)
            # Bucket HEAD: bucket accessible, contains "200 OK"
            echo "HTTP/1.1 200 OK"
            echo "Content-Type: application/xml"
            return 0
            ;;
        *)
            # Service check or further calls: return 200 OK
            echo "HTTP/1.1 200 OK"
            return 0
            ;;
    esac
}
