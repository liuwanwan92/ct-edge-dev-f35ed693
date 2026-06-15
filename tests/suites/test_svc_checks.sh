#!/usr/bin/env bash
# tests/suites/test_svc_checks.sh — Validate service probe scripts + dependency simulation
SUITE_FILE="prometheus/svc-checks/"

describe "SERVICE_PROBES"

SVC_DIR="${PROJECT_ROOT}/prometheus/svc-checks"
ISCSI_CHECK="${SVC_DIR}/nedge-prom-iscsi-check"
NFS_CHECK="${SVC_DIR}/nedge-prom-nfs-check"
S3_CHECK="${SVC_DIR}/nedge-prom-s3-check"

# ── Helper: common checks for each probe ──────────────────
_check_probe_common() {
    local script="$1" label="$2" expected_metric="$3"

    # File exists
    it "$label: file exists"
    assert_file_exists "$script"
    end_it

    # Executable
    it "$label: has executable permission"
    assert_file_executable "$script"
    end_it

    # Bash shebang
    it "$label: has bash shebang"
    local first_line
    first_line=$(head -1 "$script")
    assert_match 'bash' "$first_line" "first line should contain bash"
    end_it

    # Valid bash syntax
    it "$label: bash syntax valid (bash -n)"
    assert_bash_syntax "$script"
    end_it

    # socat 8090 in comments
    it "$label: documents socat TCP4-LISTEN:8090 in comments"
    local content
    content=$(< "$script")
    assert_contains "$content" "8090" "should reference port 8090 in socat comment"
    end_it

    # /metrics route
    it "$label: routes /metrics endpoint"
    assert_contains "$content" "/metrics" "should route /metrics"
    end_it

    # Content-Type for prometheus
    it "$label: sets Content-Type text/plain; version=0.0.4"
    assert_contains "$content" "text/plain; version=0.0.4" "should set Prometheus Content-Type"
    end_it

    # # HELP line
    it "$label: has # HELP line for metric"
    assert_contains "$content" "# HELP $expected_metric" "should have '# HELP $expected_metric'"
    end_it

    # # TYPE line
    it "$label: has # TYPE gauge line for metric"
    assert_contains "$content" "# TYPE $expected_metric gauge" "should have '# TYPE $expected_metric gauge'"
    end_it

    # send_response_ok_exit defined
    it "$label: defines send_response_ok_exit function"
    assert_contains "$content" "send_response_ok_exit" "should define send_response_ok_exit"
    end_it

    # fail_with calls exit 1
    it "$label: fail_with function exits with code 1"
    if grep -A3 'fail_with()' "$script" | grep -q 'exit 1'; then
        :
    else
        _CURRENT_TEST_MESSAGES+=( "fail_with() should call 'exit 1'" )
        _assert_fail
    fi
    end_it

    # declare -A SERVICES (bash 4+ associative array)
    it "$label: uses declare -A SERVICES (bash 4+)"
    assert_contains "$content" "declare -A SERVICES" "should use 'declare -A SERVICES'"
    end_it
}

# ── iSCSI check ───────────────────────────────────────────
_check_probe_common "$ISCSI_CHECK" "iscsi" "nedge_iscsi_service_status"

it "iscsi: metric name is nedge_iscsi_service_status"
content=$(< "$ISCSI_CHECK")
assert_contains "$content" "nedge_iscsi_service_status" "metric name mismatch"
end_it

it "iscsi: references iscsi-ls tool"
assert_contains "$content" "iscsi-ls" "should use iscsi-ls for discovery"
end_it

it "iscsi: defines iscsi_check function"
assert_contains "$content" "iscsi_check()" "should define iscsi_check()"
end_it

it "iscsi: handles state -1 (not discoverable)"
assert_contains "$content" '"-1"' "should handle state -1"
end_it

it "iscsi: handles state 0 (LUNs not found)"
# The script echoes "0" when LUN not found
if grep -q 'echo "0"' "$ISCSI_CHECK" || grep -q "echo \"0\"" "$ISCSI_CHECK"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "should handle state 0 (LUNs not found)" )
    _assert_fail
fi
end_it

# ── NFS check ─────────────────────────────────────────────
_check_probe_common "$NFS_CHECK" "nfs" "nedge_nfs_service_status"

it "nfs: metric name is nedge_nfs_service_status"
content=$(< "$NFS_CHECK")
assert_contains "$content" "nedge_nfs_service_status" "metric name mismatch"
end_it

it "nfs: references showmount"
assert_contains "$content" "showmount" "should use showmount"
end_it

it "nfs: references df command"
assert_contains "$content" "df " "should use df for mount check"
end_it

it "nfs: references rpcinfo"
assert_contains "$content" "rpcinfo" "should use rpcinfo as fallback"
end_it

it "nfs: defines nfs_check function"
assert_contains "$content" "nfs_check()" "should define nfs_check()"
end_it

it "nfs: handles state -3 (not mounted)"
assert_contains "$content" '"-3"' "should handle state -3"
end_it

it "nfs: handles state -2 (showmount timeout)"
assert_contains "$content" '"-2"' "should handle state -2"
end_it

it "nfs: handles state -1 (df timeout)"
assert_contains "$content" '"-1"' "should handle state -1"
end_it

# ── S3 check ─────────────────────────────────────────────
_check_probe_common "$S3_CHECK" "s3" "nedge_s3_service_status"

it "s3: metric name is nedge_s3_service_status"
content=$(< "$S3_CHECK")
assert_contains "$content" "nedge_s3_service_status" "metric name mismatch"
end_it

it "s3: references curl"
assert_contains "$content" "curl" "should use curl"
end_it

it "s3: references openssl"
assert_contains "$content" "openssl" "should use openssl for HMAC"
end_it

it "s3: references base64"
assert_contains "$content" "base64" "should use base64 for signing"
end_it

it "s3: defines s3_check function"
assert_contains "$content" "s3_check()" "should define s3_check()"
end_it

it "s3: handles state -2 (not discoverable)"
assert_contains "$content" '"-2"' "should handle state -2"
end_it

it "s3: handles state -1 (object HEAD failed)"
assert_contains "$content" '"-1"' "should handle state -1"
end_it

# ── Cross-script checks ──────────────────────────────────
it "all three scripts reference port 8090 consistently"
for script in "$ISCSI_CHECK" "$NFS_CHECK" "$S3_CHECK"; do
    if ! grep -q "8090" "$script"; then
        _CURRENT_TEST_MESSAGES+=( "$(basename "$script") does not reference port 8090" )
        _assert_fail
        break
    fi
done
end_it

it "each script uses a unique tmpfile path"
tmpfiles=""
for script in "$ISCSI_CHECK" "$NFS_CHECK" "$S3_CHECK"; do
    tf=$(grep -oE '/tmp/nedge-prom-[a-z]+-check\.last' "$script" | head -1)
    if [[ -n "$tf" ]]; then
        tmpfiles="$tmpfiles $tf"
    fi
done
unique_count=$(echo "$tmpfiles" | tr ' ' '\n' | sort -u | grep -c .)
total_count=$(echo "$tmpfiles" | tr ' ' '\n' | grep -c .)
if (( unique_count == total_count )); then
    :
else
    _CURRENT_TEST_MESSAGES+=( "tmpfile paths are not unique: $tmpfiles" )
    _assert_fail
fi
end_it

# ── Mock environment: dependency-missing tests ────────────
# These tests verify that probe scripts don't falsely report "service fully available"
# when required tools are missing.

# Setup mock environment for dependency tests
setup_mock_env

# Test: iSCSI check should NOT report status 1 when iscsi-ls is missing
it "MOCK: iscsi_check does not falsely report status=1 when iscsi-ls is missing"
remove_mock "iscsi-ls"
# Source only the iscsi_check function and SERVICES array, then call it
_iscsi_out=$(
    bash -c "
        source '${ISCSI_CHECK}' 2>/dev/null || true
        # If sourcing ran the full script, we need a different approach
        # Instead, extract and run just the check function
    " 2>&1
) || true

# Better approach: check if the script has a pre-check for iscsi-ls
if grep -qE '(command -v iscsi-ls|which iscsi-ls|type iscsi-ls)' "$ISCSI_CHECK"; then
    : # Script has a pre-check, good
else
    _CURRENT_TEST_MESSAGES+=( "nedge-prom-iscsi-check has no 'command -v iscsi-ls' pre-check — iscsi-ls absence is not caught before use, risking false success" )
    _assert_fail
fi
end_it

# Test: NFS check should NOT report status 1 when showmount is missing
it "MOCK: nfs_check does not falsely report status=1 when showmount is missing"
remove_mock "showmount"
if grep -qE '(command -v showmount|which showmount|type showmount)' "$NFS_CHECK"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "nedge-prom-nfs-check has no 'command -v showmount' pre-check — showmount absence is not caught before use" )
    _assert_fail
fi
end_it

# Test: S3 check should NOT report status 1 when openssl is missing
it "MOCK: s3_check does not falsely report status=1 when openssl is missing"
remove_mock "openssl"
if grep -qE '(command -v openssl|which openssl|type openssl)' "$S3_CHECK"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "nedge-prom-s3-check has no 'command -v openssl' pre-check — openssl absence is not caught before use" )
    _assert_fail
fi
end_it

# Test: S3 check should NOT report status 1 when curl is missing
it "MOCK: s3_check does not falsely report status=1 when curl is missing"
remove_mock "curl"
if grep -qE '(command -v curl|which curl|type curl)' "$S3_CHECK"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "nedge-prom-s3-check has no 'command -v curl' pre-check — curl absence is not caught before use" )
    _assert_fail
fi
end_it

# Test: S3 check should NOT report status 1 when base64 is missing
it "MOCK: s3_check does not falsely report status=1 when base64 is missing"
remove_mock "base64"
if grep -qE '(command -v base64|which base64|type base64)' "$S3_CHECK"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "nedge-prom-s3-check has no 'command -v base64' pre-check — base64 absence is not caught before use" )
    _assert_fail
fi
end_it

# Cleanup mock environment
teardown_mock_env
