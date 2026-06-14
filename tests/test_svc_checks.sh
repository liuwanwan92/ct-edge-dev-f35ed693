#!/usr/bin/env bash
#
# tests/test_svc_checks.sh — test the service health monitor scripts
#

set -uo pipefail
. "$(dirname "$0")/lib/common.sh"

SVC_DIR="$REPO_ROOT/prometheus/svc-checks"

# ──────────────────────────────────────────────────────────────
# Helper: build a self-contained test harness for a check function
# ──────────────────────────────────────────────────────────────
_build_s3_harness() {
    local mock_dir="$1" out="$2"
    {
        echo '#!/usr/bin/env bash'
        extract_function "$SVC_DIR/nedge-prom-s3-check" "s3_check"
        echo 'result=$(s3_check "$1" "$2")'
        echo 'printf "%s\n" "$result"'
    } > "$out"
    chmod +x "$out"
}

_build_nfs_harness() {
    local mock_dir="$1" out="$2"
    {
        echo '#!/usr/bin/env bash'
        extract_function "$SVC_DIR/nedge-prom-nfs-check" "nfs_check"
        echo 'result=$(nfs_check "$1" "$2")'
        echo 'printf "%s\n" "$result"'
    } > "$out"
    chmod +x "$out"
}

_build_iscsi_harness() {
    local mock_dir="$1" out="$2"
    {
        echo '#!/usr/bin/env bash'
        extract_function "$SVC_DIR/nedge-prom-iscsi-check" "iscsi_check"
        echo 'result=$(iscsi_check "$1" "$2")'
        echo 'printf "%s\n" "$result"'
    } > "$out"
    chmod +x "$out"
}

# ──────────────────────────────────────────────────────────────
# Test functions
# ──────────────────────────────────────────────────────────────

_test_s3_state_1() {
    local tmpdir; tmpdir="$(test_make_tmpdir)"
    local mock_dir harness; mock_dir="$(mock_setup)"
    harness="$tmpdir/s3_test.sh"

    mock_command_script "$mock_dir" "curl" '
        printf "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n"
    '
    mock_command_script "$mock_dir" "openssl" 'printf "dummysig"'
    mock_command_script "$mock_dir" "base64" 'cat'

    _build_s3_harness "$mock_dir" "$harness"

    local result
    result="$(PATH="$mock_dir:$PATH" bash "$harness" "testsvc" \
        "http://10.0.0.1:9982/bk1/obj1^KEYID^KEYSECRET")"
    assert_eq "1" "$result" "S3 object HEAD success should return state 1"
    mock_teardown "$mock_dir"
}

_test_s3_state_0() {
    local tmpdir; tmpdir="$(test_make_tmpdir)"
    local mock_dir harness call_count_file; mock_dir="$(mock_setup)"
    harness="$tmpdir/s3_test.sh"
    call_count_file="$tmpdir/curl_calls"

    mock_command_script "$mock_dir" "curl" '
        count=0
        if [ -f "'"$call_count_file"'" ]; then count=$(cat "'"$call_count_file"'"); fi
        count=$((count + 1))
        printf "%s" "$count" > "'"$call_count_file"'"
        if [ "$count" -eq 1 ]; then
            printf "HTTP/1.1 404 Not Found\r\n\r\n"
        elif [ "$count" -eq 2 ]; then
            printf "HTTP/1.1 200 OK\r\n\r\n"
        else
            printf "HTTP/1.1 403 Forbidden\r\n\r\n"
        fi
    '
    mock_command_script "$mock_dir" "openssl" 'printf "dummysig"'
    mock_command_script "$mock_dir" "base64" 'cat'

    _build_s3_harness "$mock_dir" "$harness"
    local result
    result="$(PATH="$mock_dir:$PATH" bash "$harness" "testsvc" \
        "http://10.0.0.1:9982/bk1/obj1^KEYID^KEYSECRET")"
    assert_eq "0" "$result" "S3 bucket-only should return state 0"
    mock_teardown "$mock_dir"
}

_test_s3_state_neg1() {
    local tmpdir; tmpdir="$(test_make_tmpdir)"
    local mock_dir harness call_count_file; mock_dir="$(mock_setup)"
    harness="$tmpdir/s3_test.sh"
    call_count_file="$tmpdir/curl_calls"

    mock_command_script "$mock_dir" "curl" '
        count=0
        if [ -f "'"$call_count_file"'" ]; then count=$(cat "'"$call_count_file"'"); fi
        count=$((count + 1))
        printf "%s" "$count" > "'"$call_count_file"'"
        if [ "$count" -le 2 ]; then
            printf "HTTP/1.1 404 Not Found\r\n\r\n"
        else
            printf "HTTP/1.1 403 Forbidden\r\n\r\n"
        fi
    '
    mock_command_script "$mock_dir" "openssl" 'printf "dummysig"'
    mock_command_script "$mock_dir" "base64" 'cat'

    _build_s3_harness "$mock_dir" "$harness"
    local result
    result="$(PATH="$mock_dir:$PATH" bash "$harness" "testsvc" \
        "http://10.0.0.1:9982/bk1/obj1^KEYID^KEYSECRET")"
    assert_eq "-1" "$result" "S3 service reachable but no access should return -1"
    mock_teardown "$mock_dir"
}

_test_s3_state_neg2() {
    local tmpdir; tmpdir="$(test_make_tmpdir)"
    local mock_dir harness; mock_dir="$(mock_setup)"
    harness="$tmpdir/s3_test.sh"

    mock_command_script "$mock_dir" "curl" 'printf ""; exit 7'
    mock_command_script "$mock_dir" "openssl" 'printf "dummysig"'
    mock_command_script "$mock_dir" "base64" 'cat'

    _build_s3_harness "$mock_dir" "$harness"
    local result
    result="$(PATH="$mock_dir:$PATH" bash "$harness" "testsvc" \
        "http://10.0.0.1:9982/bk1/obj1^KEYID^KEYSECRET")"
    assert_eq "-2" "$result" "S3 service not discoverable should return -2"
    mock_teardown "$mock_dir"
}

_test_iscsi_state_1() {
    local tmpdir; tmpdir="$(test_make_tmpdir)"
    local mock_dir harness; mock_dir="$(mock_setup)"
    harness="$tmpdir/iscsi_test.sh"

    mock_command_script "$mock_dir" "iscsi-ls" '
        printf "Target: iqn.2018-01.com.nexenta:iscsi\n  Lun:1\n"
        exit 0
    '

    _build_iscsi_harness "$mock_dir" "$harness"
    local result
    result="$(PATH="$mock_dir:$PATH" bash "$harness" "testsvc" \
        "iscsi://10.0.0.1:3260^1")"
    assert_eq "1" "$result" "iSCSI LUN found should return state 1"
    mock_teardown "$mock_dir"
}

_test_iscsi_state_0() {
    local tmpdir; tmpdir="$(test_make_tmpdir)"
    local mock_dir harness; mock_dir="$(mock_setup)"
    harness="$tmpdir/iscsi_test.sh"

    mock_command_script "$mock_dir" "iscsi-ls" '
        printf "Target: iqn.2018-01.com.nexenta:iscsi\n  Lun:99\n"
        exit 0
    '

    _build_iscsi_harness "$mock_dir" "$harness"
    local result
    result="$(PATH="$mock_dir:$PATH" bash "$harness" "testsvc" \
        "iscsi://10.0.0.1:3260^1")"
    assert_eq "0" "$result" "iSCSI target found but LUN missing should return 0"
    mock_teardown "$mock_dir"
}

_test_iscsi_state_neg1() {
    local tmpdir; tmpdir="$(test_make_tmpdir)"
    local mock_dir harness; mock_dir="$(mock_setup)"
    harness="$tmpdir/iscsi_test.sh"

    mock_command_script "$mock_dir" "iscsi-ls" 'exit 1'

    _build_iscsi_harness "$mock_dir" "$harness"
    local result
    result="$(PATH="$mock_dir:$PATH" bash "$harness" "testsvc" \
        "iscsi://10.0.0.1:3260^1")"
    assert_eq "-1" "$result" "iSCSI not discoverable should return -1"
    mock_teardown "$mock_dir"
}

_test_nfs_state_neg3() {
    local tmpdir; tmpdir="$(test_make_tmpdir)"
    local mock_dir harness; mock_dir="$(mock_setup)"
    harness="$tmpdir/nfs_test.sh"

    mock_command_script "$mock_dir" "mount" 'exit 0'

    _build_nfs_harness "$mock_dir" "$harness"
    local result
    result="$(PATH="$mock_dir:$PATH" bash "$harness" "testsvc" "/mnt/nfssvc1")"
    assert_eq "-3" "$result" "NFS not mounted should return -3"
    mock_teardown "$mock_dir"
}

_test_nfs_state_1() {
    local tmpdir; tmpdir="$(test_make_tmpdir)"
    local mock_dir harness; mock_dir="$(mock_setup)"
    harness="$tmpdir/nfs_test.sh"

    mock_command_script "$mock_dir" "mount" '
        printf "10.0.0.1:/share on /mnt/nfssvc1 type nfs (rw,addr=10.0.0.1)\n"
    '
    mock_command_script "$mock_dir" "showmount" 'exit 0'
    mock_command_script "$mock_dir" "df" 'exit 0'
    mock_command_script "$mock_dir" "rpcinfo" '
        printf "100003 3 udp 2049 nfs program 100003 version 3 ready\n"
    '

    _build_nfs_harness "$mock_dir" "$harness"
    local result
    result="$(PATH="$mock_dir:$PATH" bash "$harness" "testsvc" "/mnt/nfssvc1")"
    assert_eq "1" "$result" "NFS fully available should return 1"
    mock_teardown "$mock_dir"
}

_check_s3_state_docs() {
    local readme="$SVC_DIR/README.md"
    local doc_states
    doc_states="$(sed -n '/S3 service/,//p' "$readme" | grep -oE '^\s+-?[0-9]+' | grep -oE '\-?[0-9]+' | sort -u)"
    local expected="0 1 -1 -2"
    local missing=0
    for s in $expected; do
        if ! printf '%s\n' "$doc_states" | grep -qxF -- "$s"; then
            _fail "S3 state $s not documented"; missing=1
        fi
    done
    [ "$missing" -eq 0 ] && _pass "all S3 states documented: $expected"
}

_check_nfs_state_docs() {
    local readme="$SVC_DIR/README.md"
    local doc_states
    doc_states="$(sed -n '/NFS service/,/iSCSI service/p' "$readme" | grep -oE '^\s+-?[0-9]+' | grep -oE '\-?[0-9]+' | sort -u)"
    local expected="0 1 -1 -2 -3"
    local missing=0
    for s in $expected; do
        if ! printf '%s\n' "$doc_states" | grep -qxF -- "$s"; then
            _fail "NFS state $s not documented"; missing=1
        fi
    done
    [ "$missing" -eq 0 ] && _pass "all NFS states documented: $expected"
}

_check_iscsi_state_docs() {
    local readme="$SVC_DIR/README.md"
    local doc_states
    doc_states="$(sed -n '/iSCSI service/,/S3 service/p' "$readme" | grep -oE '^\s+-?[0-9]+' | grep -oE '\-?[0-9]+' | sort -u)"
    local expected="0 1 -1"
    local missing=0
    for s in $expected; do
        if ! printf '%s\n' "$doc_states" | grep -qxF -- "$s"; then
            _fail "iSCSI state $s not documented"; missing=1
        fi
    done
    [ "$missing" -eq 0 ] && _pass "all iSCSI states documented: $expected"
}

_check_s3_deps_declared() {
    local script="$SVC_DIR/nedge-prom-s3-check"
    local has_dep_check=0
    for dep in curl openssl base64; do
        if grep -qE "which $dep|command -v $dep|type $dep" "$script"; then
            has_dep_check=1
        fi
    done
    if [ "$has_dep_check" -eq 0 ]; then
        _fail "s3-check declares dependencies in comments but never validates them"
        log_diag "Script requires curl, openssl, base64 but has no runtime dependency check"
    else
        _pass "dependency checks present"
    fi
}

_check_iscsi_deps_declared() {
    local script="$SVC_DIR/nedge-prom-iscsi-check"
    if grep -qE "which iscsi-ls|command -v iscsi-ls|type iscsi-ls" "$script"; then
        _pass "dependency check present"
    else
        _fail "iscsi-check declares iscsi-ls dependency but never validates it"
        log_diag "If iscsi-ls is missing, the script fails with 'command not found'"
    fi
}

_test_s3_missing_curl() {
    local tmpdir; tmpdir="$(test_make_tmpdir)"
    local mock_dir harness; mock_dir="$(mock_setup)"
    harness="$tmpdir/s3_test.sh"

    # Do NOT provide curl — only openssl and base64
    mock_command_script "$mock_dir" "openssl" 'printf "dummysig"'
    mock_command_script "$mock_dir" "base64" 'cat'

    _build_s3_harness "$mock_dir" "$harness"

    local result rc=0
    result="$(PATH="$mock_dir" bash "$harness" "testsvc" \
        "http://10.0.0.1:9982/bk1/obj1^KEYID^KEYSECRET" 2>/dev/null)" || rc=$?

    if [ "$rc" -ne 0 ]; then
        _pass "correctly fails when curl is missing (exit $rc)"
    elif printf '%s' "$result" | grep -qE '^-'; then
        _pass "returns negative state when curl is missing: $result"
    elif [ "$result" = "1" ]; then
        _fail "FALSE POSITIVE: reports service OK when curl is missing"
    else
        _pass "returned non-OK state: $result"
    fi
    mock_teardown "$mock_dir"
}

# ──────────────────────────────────────────────────────────────
# Test execution
# ──────────────────────────────────────────────────────────────
begin_suite "svc-checks"

run_test "s3:state-1-object-ok" _test_s3_state_1
run_test "s3:state-0-bucket-only" _test_s3_state_0
run_test "s3:state-neg1-service-reachable" _test_s3_state_neg1
run_test "s3:state-neg2-not-discoverable" _test_s3_state_neg2
run_test "iscsi:state-1-lun-found" _test_iscsi_state_1
run_test "iscsi:state-0-lun-missing" _test_iscsi_state_0
run_test "iscsi:state-neg1-not-discoverable" _test_iscsi_state_neg1
run_test "nfs:state-neg3-not-mounted" _test_nfs_state_neg3
run_test "nfs:state-1-fully-available" _test_nfs_state_1
run_test "docs:s3-state-codes-match" _check_s3_state_docs
run_test "docs:nfs-state-codes-match" _check_nfs_state_docs
run_test "docs:iscsi-state-codes-match" _check_iscsi_state_docs
run_test "deps:s3-check-declares-deps" _check_s3_deps_declared
run_test "deps:iscsi-check-declares-deps" _check_iscsi_deps_declared
run_test "negative:s3-missing-curl-no-false-ok" _test_s3_missing_curl

end_suite
