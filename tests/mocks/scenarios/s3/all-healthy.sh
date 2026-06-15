#!/usr/bin/env bash
# Scenario: S3 all-healthy
#
# S3 service is fully operational. The object HEAD request succeeds with
# HTTP 200 OK, so the production script doesn't need to fall back to
# bucket or service checks.
#
# Expected result: 1 (service fully available)
#
# Production script flow:
#   1. openssl sha1 -binary -hmac <key> | base64 → generates HMAC signature
#   2. curl -I <url> -H "Date: ..." -H "Authorization: ..." 2>&1 | grep "200 OK"
#      → match found → echo "1"

scenario_setup() {
    # openssl outputs dummy binary data (gets piped to base64, but the
    # base64 mock ignores stdin and returns its own mocked response)
    mock_set_response openssl "dummy_hmac_binary_data"

    # base64 returns a valid-looking HMAC signature string.
    # This becomes the $sig variable used in the Authorization header.
    mock_set_response base64 "dGVzdA=="

    # curl returns HTTP 200 OK for all calls.
    # The first call (object HEAD) matches "200 OK" → result = 1
    mock_set_response curl "HTTP/1.1 200 OK"
    mock_set_exit curl 0
}
