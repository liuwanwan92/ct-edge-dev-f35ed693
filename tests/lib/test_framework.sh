#!/usr/bin/env bash
# tests/lib/test_framework.sh — Lightweight bash test harness
# Zero external dependencies. Works with bash 4+.
set -uo pipefail

# ── Counters ──────────────────────────────────────────────
_TESTS_RUN=0
_TESTS_PASSED=0
_TESTS_FAILED=0
_CURRENT_SUITE=""
_CURRENT_TEST=""
_CURRENT_TEST_FAILED=0
_CURRENT_TEST_MESSAGES=()

# Per-suite accumulators (parallel arrays)
declare -a _SUITE_NAMES=()
declare -a _SUITE_TOTAL=()
declare -a _SUITE_PASSED=()
declare -a _SUITE_FAILED=()
_SUITE_IDX=-1

# ── Colors / CI detection ────────────────────────────────
if [[ "${CI:-}" == "true" ]] || [[ "${CI:-}" == "1" ]] || [[ ! -t 1 ]]; then
    _C_RED="" ; _C_GREEN="" ; _C_YELLOW="" ; _C_BOLD="" ; _C_DIM="" ; _C_RST=""
    _PASS_LABEL="[PASS]"
    _FAIL_LABEL="[FAIL]"
    _WARN_LABEL="[WARN]"
else
    _C_RED=$'\033[0;31m' ; _C_GREEN=$'\033[0;32m' ; _C_YELLOW=$'\033[0;33m'
    _C_BOLD=$'\033[1m'     ; _C_DIM=$'\033[2m'       ; _C_RST=$'\033[0m'
    _PASS_LABEL="${_C_GREEN}PASS${_C_RST}"
    _FAIL_LABEL="${_C_RED}FAIL${_C_RST}"
    _WARN_LABEL="${_C_YELLOW}WARN${_C_RST}"
fi

# ── Suite lifecycle ───────────────────────────────────────
describe() {
    local name="$1"
    _CURRENT_SUITE="$name"
    _SUITE_IDX=$(( _SUITE_IDX + 1 ))
    _SUITE_NAMES+=( "$name" )
    _SUITE_TOTAL+=( 0 )
    _SUITE_PASSED+=( 0 )
    _SUITE_FAILED+=( 0 )
    echo ""
    echo "${_C_BOLD}[$name]${_C_RST} ${_C_DIM}${SUITE_FILE:-}${_C_RST}"
}

# ── Test lifecycle ────────────────────────────────────────
it() {
    _CURRENT_TEST="$1"
    _CURRENT_TEST_FAILED=0
    _CURRENT_TEST_MESSAGES=()
    _TESTS_RUN=$(( _TESTS_RUN + 1 ))
    _SUITE_TOTAL[_SUITE_IDX]=$(( ${_SUITE_TOTAL[_SUITE_IDX]} + 1 ))
}

pass_test() {
    if (( _CURRENT_TEST_FAILED == 0 )); then
        echo "  ${_PASS_LABEL}  ${_CURRENT_TEST}"
        _TESTS_PASSED=$(( _TESTS_PASSED + 1 ))
        _SUITE_PASSED[_SUITE_IDX]=$(( ${_SUITE_PASSED[_SUITE_IDX]} + 1 ))
    fi
}

fail_test() {
    local msg="${1:-}"
    _CURRENT_TEST_FAILED=1
    _TESTS_FAILED=$(( _TESTS_FAILED + 1 ))
    _SUITE_FAILED[_SUITE_IDX]=$(( ${_SUITE_FAILED[_SUITE_IDX]} + 1 ))
    echo "  ${_FAIL_LABEL}  ${_CURRENT_TEST}"
    if [[ -n "$msg" ]]; then
        echo "         -> $msg"
    fi
}

end_it() {
    if (( _CURRENT_TEST_FAILED == 0 )); then
        pass_test
    fi
    _CURRENT_TEST=""
}

# ── Assertions ────────────────────────────────────────────
_assert_fail() {
    _CURRENT_TEST_FAILED=1
    _TESTS_FAILED=$(( _TESTS_FAILED + 1 ))
    _SUITE_FAILED[_SUITE_IDX]=$(( ${_SUITE_FAILED[_SUITE_IDX]} + 1 ))
    echo "  ${_FAIL_LABEL}  ${_CURRENT_TEST}"
    if (( ${#_CURRENT_TEST_MESSAGES[@]} > 0 )); then
        for m in "${_CURRENT_TEST_MESSAGES[@]}"; do
            echo "         -> $m"
        done
    fi
    if [[ -n "${1:-}" ]]; then
        echo "         -> $1"
    fi
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-expected '$expected', got '$actual'}"
    if [[ "$expected" != "$actual" ]]; then
        _CURRENT_TEST_MESSAGES+=( "$msg" )
        _assert_fail
    fi
}

assert_ne() {
    local unexpected="$1" actual="$2" msg="${3:-value should not be '$unexpected'}"
    if [[ "$unexpected" == "$actual" ]]; then
        _CURRENT_TEST_MESSAGES+=( "$msg" )
        _assert_fail
    fi
}

assert_match() {
    local pattern="$1" actual="$2" msg="${3:-'$actual' does not match /$pattern/}"
    if ! [[ "$actual" =~ $pattern ]]; then
        _CURRENT_TEST_MESSAGES+=( "$msg" )
        _assert_fail
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-output does not contain '$needle'}"
    if [[ "$haystack" != *"$needle"* ]]; then
        _CURRENT_TEST_MESSAGES+=( "$msg" )
        _assert_fail
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-output should not contain '$needle'}"
    if [[ "$haystack" == *"$needle"* ]]; then
        _CURRENT_TEST_MESSAGES+=( "$msg" )
        _assert_fail
    fi
}

assert_file_exists() {
    local f="$1"
    local msg="${2:-file not found: $f}"
    if [[ ! -f "$f" ]]; then
        _CURRENT_TEST_MESSAGES+=( "$msg" )
        _assert_fail
    fi
}

assert_file_executable() {
    local f="$1"
    local msg="${2:-file not executable: $f}"
    if [[ ! -x "$f" ]]; then
        _CURRENT_TEST_MESSAGES+=( "$msg" )
        _assert_fail
    fi
}

assert_file_not_empty() {
    local f="$1"
    local msg="${2:-file is empty: $f}"
    if [[ ! -s "$f" ]]; then
        _CURRENT_TEST_MESSAGES+=( "$msg" )
        _assert_fail
    fi
}

assert_exit_code() {
    local expected="$1" actual="$2" msg="${3:-expected exit code $expected, got $actual}"
    if [[ "$expected" != "$actual" ]]; then
        _CURRENT_TEST_MESSAGES+=( "$msg" )
        _assert_fail
    fi
}

# YAML / JSON assertions delegate to helpers
assert_valid_yaml() {
    local f="$1"
    local msg="${2:-invalid YAML: $f}"
    if ! validate_yaml "$f" 2>/dev/null; then
        _CURRENT_TEST_MESSAGES+=( "$msg" )
        _assert_fail
    fi
}

assert_valid_json() {
    local f="$1"
    local msg="${2:-invalid JSON: $f}"
    if ! validate_json "$f" 2>/dev/null; then
        _CURRENT_TEST_MESSAGES+=( "$msg" )
        _assert_fail
    fi
}

assert_no_tabs() {
    local f="$1"
    local msg="${2:-file contains tab characters: $f}"
    if grep -qP '\t' "$f" 2>/dev/null; then
        _CURRENT_TEST_MESSAGES+=( "$msg" )
        _assert_fail
    fi
}

assert_bash_syntax() {
    local f="$1"
    local msg="${2:-bash syntax error in: $f}"
    if ! bash -n "$f" 2>/dev/null; then
        _CURRENT_TEST_MESSAGES+=( "$msg" )
        _assert_fail
    fi
}

# ── Summary ───────────────────────────────────────────────
print_summary() {
    local width=28
    local sep="+$(printf '%*s' $width '' | tr ' ' '-')+-------+------+------+--------+"
    echo ""
    echo "${_C_BOLD}================================================================${_C_RST}"
    echo "${_C_BOLD}  SUMMARY${_C_RST}"
    echo "$sep"
    printf "| %-26s | Total | Pass | Fail | Status |\n" "Category"
    echo "$sep"
    local i
    for (( i=0; i<=_SUITE_IDX; i++ )); do
        local status
        if (( ${_SUITE_FAILED[$i]} == 0 )); then
            status="${_PASS_LABEL}"
        else
            status="${_FAIL_LABEL}"
        fi
        # Pad status for alignment (ANSI codes don't take space)
        local raw_status
        if (( ${_SUITE_FAILED[$i]} == 0 )); then raw_status="PASS"; else raw_status="FAIL"; fi
        printf "| %-26s | %5d | %4d | %4d | %-6s |\n" \
            "${_SUITE_NAMES[$i]}" "${_SUITE_TOTAL[$i]}" "${_SUITE_PASSED[$i]}" "${_SUITE_FAILED[$i]}" "$raw_status"
    done
    echo "$sep"
    local total_status="PASS"
    if (( _TESTS_FAILED > 0 )); then total_status="FAIL"; fi
    printf "| %-26s | %5d | %4d | %4d | %-6s |\n" \
        "TOTAL" "$_TESTS_RUN" "$_TESTS_PASSED" "$_TESTS_FAILED" "$total_status"
    echo "$sep"
    echo ""
}

# Returns exit code for the whole run
get_exit_code() {
    if (( _TESTS_FAILED > 0 )); then echo 1
    else echo 0
    fi
}
