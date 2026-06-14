#!/usr/bin/env bash
#
# tests/lib/common.sh — shared test framework for NexentaEdge DevOps CI checks
#
# Usage: source this file at the top of every test_*.sh
#   . "$(dirname "$0")/lib/common.sh"
#
# Exit codes:
#   0  all tests passed
#   1  one or more tests failed
#   2  setup / environment error (e.g. missing dependency, bad fixture)
#
# Environment variables:
#   TEST_VERBOSE=1        — show PASS lines too (default: only FAIL + summary)
#   TEST_STOP_ON_FAIL=1   — abort immediately on first failure
#   TEST_FILTER=<regex>   — only run tests matching this regex
#

set -uo pipefail

# ---------------------------------------------------------------------------
# Detect working Python (python3 may be a Windows Store stub)
# ---------------------------------------------------------------------------
_PYTHON=""
for _p in python3 python; do
    if command -v "$_p" >/dev/null 2>&1 && "$_p" -c "print('ok')" >/dev/null 2>&1; then
        _PYTHON="$_p"
        break
    fi
done

if [ -z "$_PYTHON" ]; then
    echo "ERROR: No working Python interpreter found (tried python3, python)" >&2
    echo "Python 3 is required for JSON validation and config parsing." >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
export TESTS_DIR REPO_ROOT

# ---------------------------------------------------------------------------
# Path conversion: MSYS/Git Bash paths → Windows native paths for Python
# On Linux/macOS this is a no-op.
# ---------------------------------------------------------------------------
_to_native_path() {
    local path="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$path" 2>/dev/null || printf '%s' "$path"
    else
        printf '%s' "$path"
    fi
}

# ---------------------------------------------------------------------------
# Colour helpers (auto-disable when stdout is not a terminal)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    _C_RED='\033[0;31m'; _C_GREEN='\033[0;32m'; _C_YELLOW='\033[0;33m'
    _C_CYAN='\033[0;36m'; _C_BOLD='\033[1m'; _C_RESET='\033[0m'
else
    _C_RED=''; _C_GREEN=''; _C_YELLOW=''; _C_CYAN=''; _C_BOLD=''; _C_RESET=''
fi

# ---------------------------------------------------------------------------
# Test counters — all globals, intentionally prefixed with _TC_
# ---------------------------------------------------------------------------
_TC_PASS=0
_TC_FAIL=0
_TC_SKIP=0
_TC_TOTAL=0
_TC_CURRENT=""          # name of the currently-running test
_TC_SUITE=""            # name of the current test suite (file)
_TC_DIAGNOSTICS=()      # collected diagnostic messages for failures

# ---------------------------------------------------------------------------
# Temporary directory — auto-cleaned via EXIT trap
# ---------------------------------------------------------------------------
_TEST_TMPDIR=""

_test_cleanup() {
    if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
        rm -rf "$_TEST_TMPDIR"
    fi
}
trap _test_cleanup EXIT

test_make_tmpdir() {
    _TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/nedge-test.XXXXXX")"
    echo "$_TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info()  { printf "${_C_CYAN}[INFO]${_C_RESET}  %s\n" "$*"; }
log_warn()  { printf "${_C_YELLOW}[WARN]${_C_RESET}  %s\n" "$*"; }
log_error() { printf "${_C_RED}[ERROR]${_C_RESET} %s\n" "$*" >&2; }
log_diag()  {
    # Append a diagnostic line; these are printed only when a test fails
    _TC_DIAGNOSTICS+=("    │ $*")
}

# ---------------------------------------------------------------------------
# Suite / test lifecycle
# ---------------------------------------------------------------------------
begin_suite() {
    _TC_SUITE="${1:-$(basename "${BASH_SOURCE[1]}" .sh)}"
    _TC_PASS=0; _TC_FAIL=0; _TC_SKIP=0; _TC_TOTAL=0
    _TC_DIAGNOSTICS=()
    printf "\n${_C_BOLD}═══ %s ═══${_C_RESET}\n" "$_TC_SUITE"
}

begin_test() {
    _TC_CURRENT="$1"
    _TC_DIAGNOSTICS=()
    _TC_TOTAL=$((_TC_TOTAL + 1))
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

# assert_eq <expected> <actual> [label]
assert_eq() {
    local expected="$1" actual="$2" label="${3:-}"
    if [ "$expected" = "$actual" ]; then
        _pass "${label:-values equal}"
    else
        _fail "${label:-values differ}: expected '$expected', got '$actual'"
    fi
}

# assert_ne <unexpected> <actual> [label]
assert_ne() {
    local unexpected="$1" actual="$2" label="${3:-}"
    if [ "$unexpected" != "$actual" ]; then
        _pass "${label:-values differ as expected}"
    else
        _fail "${label:-unexpected match}: both are '$actual'"
    fi
}

# assert_contains <haystack> <needle> [label]
assert_contains() {
    local haystack="$1" needle="$2" label="${3:-}"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        _pass "${label:-substring found}"
    else
        _fail "${label:-substring not found}: '$needle' not in output"
        log_diag "Output (first 500 chars): $(printf '%s' "$haystack" | head -c 500)"
    fi
}

# assert_not_contains <haystack> <needle> [label]
assert_not_contains() {
    local haystack="$1" needle="$2" label="${3:-}"
    if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then
        _pass "${label:-substring correctly absent}"
    else
        _fail "${label:-unexpected substring found}: '$needle'"
    fi
}

# assert_exit <expected_code> <command...>
assert_exit() {
    local expected="$1"; shift
    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?
    if [ "$expected" -eq "$actual" ]; then
        _pass "exit code $expected from: $*"
    else
        _fail "exit code mismatch for '$*': expected $expected, got $actual"
    fi
}

# assert_exit_nonzero <command...>
assert_exit_nonzero() {
    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?
    if [ "$actual" -ne 0 ]; then
        _pass "non-zero exit ($actual) from: $*"
    else
        _fail "expected non-zero exit from: $*"
    fi
}

# assert_file_exists <path> [label]
assert_file_exists() {
    local path="$1" label="${2:-}"
    if [ -e "$path" ]; then
        _pass "${label:-file exists: $path}"
    else
        _fail "${label:-file missing: $path}"
    fi
}

# assert_file_not_exists <path> [label]
assert_file_not_exists() {
    local path="$1" label="${2:-}"
    if [ ! -e "$path" ]; then
        _pass "${label:-file correctly absent: $path}"
    else
        _fail "${label:-file should not exist: $path}"
    fi
}

# assert_valid_json <string> [label]
assert_valid_json() {
    local json="$1" label="${2:-}"
    if printf '%s' "$json" | $_PYTHON -m json.tool >/dev/null 2>&1; then
        _pass "${label:-valid JSON}"
    else
        _fail "${label:-invalid JSON}"
        log_diag "Content (first 200 chars): $(printf '%s' "$json" | head -c 200)"
    fi
}

# assert_valid_json_file <path> [label]
assert_valid_json_file() {
    local path="$1" label="${2:-}"
    if [ ! -f "$path" ]; then
        _fail "${label:-file not found: $path}"
        return
    fi
    if $_PYTHON -m json.tool < "$path" >/dev/null 2>&1; then
        _pass "${label:-valid JSON: $path}"
    else
        _fail "${label:-invalid JSON: $path}"
    fi
}

# assert_command_exists <cmd> [label]
assert_command_exists() {
    local cmd="$1" label="${2:-}"
    if command -v "$cmd" >/dev/null 2>&1; then
        _pass "${label:-command available: $cmd}"
    else
        _fail "${label:-command missing: $cmd}"
    fi
}

# assert_match <string> <regex> [label]
assert_match() {
    local string="$1" regex="$2" label="${3:-}"
    if printf '%s' "$string" | grep -qE -- "$regex"; then
        _pass "${label:-regex matched}"
    else
        _fail "${label:-regex not matched}: /$regex/"
        log_diag "String (first 300 chars): $(printf '%s' "$string" | head -c 300)"
    fi
}

# ---------------------------------------------------------------------------
# Skip / pass / fail helpers (internal)
# ---------------------------------------------------------------------------
_pass() {
    local msg="${1:-ok}"
    _TC_PASS=$((_TC_PASS + 1))
    if [ "${TEST_VERBOSE:-0}" = "1" ]; then
        printf "  ${_C_GREEN}✓ PASS${_C_RESET} %s — %s\n" "$_TC_CURRENT" "$msg"
    fi
}

_fail() {
    local msg="${1:-FAILED}"
    _TC_FAIL=$((_TC_FAIL + 1))
    printf "  ${_C_RED}✗ FAIL${_C_RESET} %s — %s\n" "$_TC_CURRENT" "$msg"
    # Print collected diagnostics for this test
    for d in "${_TC_DIAGNOSTICS[@]+"${_TC_DIAGNOSTICS[@]}"}"; do
        printf "  ${_C_YELLOW}%s${_C_RESET}\n" "$d"
    done
    if [ "${TEST_STOP_ON_FAIL:-0}" = "1" ]; then
        log_error "Aborting (TEST_STOP_ON_FAIL=1)"
        exit 1
    fi
}

skip_test() {
    local reason="${1:-skipped}"
    _TC_SKIP=$((_TC_SKIP + 1))
    printf "  ${_C_YELLOW}○ SKIP${_C_RESET} %s — %s\n" "$_TC_CURRENT" "$reason"
}

# ---------------------------------------------------------------------------
# run_test <name> <function>
#   Wraps a test function with lifecycle management.
# ---------------------------------------------------------------------------
run_test() {
    local name="$1"; shift
    # Apply filter if set
    if [ -n "${TEST_FILTER:-}" ] && ! printf '%s' "$name" | grep -qE "$TEST_FILTER"; then
        return 0
    fi
    begin_test "$name"
    "$@"
}

# ---------------------------------------------------------------------------
# end_suite — print summary and return appropriate exit code
# ---------------------------------------------------------------------------
end_suite() {
    local passed=$((_TC_PASS))
    local failed=$((_TC_FAIL))
    local skipped=$((_TC_SKIP))
    local total=$((_TC_TOTAL))

    printf "\n${_C_BOLD}─── %s summary ───${_C_RESET}\n" "$_TC_SUITE"
    printf "  Tests: %d  ${_C_GREEN}Pass: %d${_C_RESET}  ${_C_RED}Fail: %d${_C_RESET}  ${_C_YELLOW}Skip: %d${_C_RESET}\n" \
        "$total" "$passed" "$failed" "$skipped"

    if [ "$failed" -gt 0 ]; then
        printf "  ${_C_RED}Suite FAILED${_C_RESET}\n"
        return 1
    else
        printf "  ${_C_GREEN}Suite PASSED${_C_RESET}\n"
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Mock environment helpers
# ---------------------------------------------------------------------------

# mock_setup — create a mock bin directory
mock_setup() {
    local mock_dir
    mock_dir="$(mktemp -d "${TMPDIR:-/tmp}/nedge-mock-bin.XXXXXX")"
    echo "$mock_dir"
}

# mock_command <mock_dir> <cmd_name> <exit_code> [stdout_content]
mock_command() {
    local mock_dir="$1" cmd="$2" exit_code="${3:-0}" stdout="${4:-}"
    cat > "$mock_dir/$cmd" <<EOF
#!/usr/bin/env bash
if [ -n "$stdout" ]; then
    printf '%s\n' '$stdout'
fi
exit $exit_code
EOF
    chmod +x "$mock_dir/$cmd"
}

# mock_command_script <mock_dir> <cmd_name> <script_body>
mock_command_script() {
    local mock_dir="$1" cmd="$2" body="$3"
    cat > "$mock_dir/$cmd" <<EOF
#!/usr/bin/env bash
$body
EOF
    chmod +x "$mock_dir/$cmd"
}

# mock_teardown <mock_dir>
mock_teardown() {
    local mock_dir="$1"
    if [ -n "$mock_dir" ] && [ -d "$mock_dir" ]; then
        rm -rf "$mock_dir"
    fi
}

# with_mock_path <mock_dir> <command...>
with_mock_path() {
    local mock_dir="$1"; shift
    PATH="$mock_dir:$PATH" "$@"
}

# ---------------------------------------------------------------------------
# JSON query helpers — use _to_native_path for cross-platform compatibility
# ---------------------------------------------------------------------------

# json_query <file> <python_expression>
# The expression receives the parsed JSON as variable `d`.
json_query() {
    local file="$1" expr="$2"
    local native_path
    native_path="$(_to_native_path "$file")"
    $_PYTHON -c "
import json, sys
with open(r'''$native_path''') as f:
    d = json.load(f)
try:
    r = $expr
    if isinstance(r, (dict, list)):
        print(json.dumps(r))
    elif isinstance(r, bool):
        print('true' if r else 'false')
    elif r is None:
        print('null')
    else:
        print(r)
except (KeyError, IndexError, TypeError) as e:
    print('ERROR:' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
}

# json_has_key <file> <dotted.key.path>
# Returns 0 if the key exists, 1 otherwise.
json_has_key() {
    local file="$1" keypath="$2"
    local native_path
    native_path="$(_to_native_path "$file")"
    $_PYTHON -c "
import json, sys
with open(r'''$native_path''') as f:
    d = json.load(f)
keys = '$keypath'.split('.')
cur = d
for k in keys:
    if isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        sys.exit(1)
sys.exit(0)
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# extract_function <script_file> <function_name>
# ---------------------------------------------------------------------------
extract_function() {
    local file="$1" func="$2"
    awk -v fn="$func" '
    BEGIN { depth=0; found=0 }
    $0 ~ "^"fn"\\(\\)" || $0 ~ "^"fn" \\(\\)" || $0 ~ "^function "fn {
        found=1
    }
    found {
        print
        n = split($0, chars, "")
        for (i = 1; i <= n; i++) {
            if (chars[i] == "{") depth++
            if (chars[i] == "}") depth--
        }
        if (depth <= 0 && found > 1) exit
        if (depth <= 0 && index($0, "{") > 0 && index($0, "}") > 0) exit
        found++
    }
    ' "$file"
}
