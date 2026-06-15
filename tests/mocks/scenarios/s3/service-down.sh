#!/usr/bin/env bash
# Scenario: S3 service-down
#
# The S3 service is completely unreachable. All curl calls fail with a
# connection error (exit code 1, empty output). This indicates a network
# issue or the S3 service being entirely down.
#
# Expected result: -2 (service not discoverable)
#
# Production script flow:
#   1. openssl | base64 → HMAC signature (still works locally)
#   2. curl (object HEAD): exit 1, empty output → grep "200 OK" fails
#   3. curl (bucket HEAD): exit 1, empty output → grep "200 OK" fails
#   4. curl (service check): exit 1, empty output → grep "403 Forbidden" fails
#      → echo "-2"

scenario_setup() {
    # openssl and base64 still work (they run locally)
    mock_set_response openssl "dummy_hmac_binary_data"
    mock_set_response base64 "dGVzdA=="

    # curl returns empty output and exits with code 1 (connection failed).
    # All three curl calls in the production script will fail:
    #   - Object HEAD: no "200 OK" match
    #   - Bucket HEAD: no "200 OK" match
    #   - Service check: no "403 Forbidden" match → result -2
    mock_set_response curl "" 1
}
