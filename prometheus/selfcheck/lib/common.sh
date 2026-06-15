#!/usr/bin/env bash
#
# common.sh - shared logging, assertions and pass/fail accounting for the
# NexentaEdge monitoring self-check and its test suite.
#
# Source this file; it defines functions and counters but intentionally does
# NOT change shell options (entry scripts own `set -uo pipefail`) so that it
# is safe to source from anywhere.
#
# Public API:
#   begin_category NAME / end_category        - group checks; tracks per-category fails
#   pass MSG / fail MSG / warn MSG / info MSG  - record an outcome
#   assert_eq EXP ACT MSG
#   assert_contains HAYSTACK NEEDLE MSG
#   assert_file_exists PATH MSG
#   assert_grep_fixed FILE TOKEN MSG           - literal substring must be present
#   assert_grep_re FILE REGEX MSG              - ERE must match
#   assert_exit EXP_RC ACT_RC MSG
#   finish                                      - print summary; return 1 if any fail
#
# Every assert_* / pass / fail returns 0 on success and 1 on failure so callers
# may chain, while also updating the global counters used by finish().

# ----- counters / state (globals) -----
_SC_FAIL_TOTAL=0
_SC_PASS_TOTAL=0
_SC_WARN_TOTAL=0
_SC_CUR_CAT=""
_SC_CAT_FAILS=0
_SC_FAILED_CATS=()

# ----- colors (tty + NO_COLOR aware) -----
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _C_RED=$'\033[31m'; _C_GRN=$'\033[32m'; _C_YEL=$'\033[33m'
  _C_CYN=$'\033[36m'; _C_BLD=$'\033[1m'; _C_RST=$'\033[0m'
else
  _C_RED=""; _C_GRN=""; _C_YEL=""; _C_CYN=""; _C_BLD=""; _C_RST=""
fi

info() { printf '%s[INFO]%s %s\n' "$_C_CYN" "$_C_RST" "$*"; }

pass() {
  _SC_PASS_TOTAL=$((_SC_PASS_TOTAL + 1))
  printf '%s[PASS]%s %s\n' "$_C_GRN" "$_C_RST" "$*"
  return 0
}

warn() {
  _SC_WARN_TOTAL=$((_SC_WARN_TOTAL + 1))
  printf '%s[WARN]%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2
  return 0
}

fail() {
  _SC_FAIL_TOTAL=$((_SC_FAIL_TOTAL + 1))
  _SC_CAT_FAILS=$((_SC_CAT_FAILS + 1))
  printf '%s[FAIL]%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2
  return 1
}

begin_category() {
  _SC_CUR_CAT="$1"
  _SC_CAT_FAILS=0
  printf '\n%s== %s ==%s\n' "$_C_BLD" "$1" "$_C_RST"
}

end_category() {
  if [ "$_SC_CAT_FAILS" -gt 0 ]; then
    _SC_FAILED_CATS+=("$_SC_CUR_CAT")
    printf '%s%s: FAILED (%d)%s\n' "$_C_RED" "$_SC_CUR_CAT" "$_SC_CAT_FAILS" "$_C_RST"
  else
    printf '%s%s: PASSED%s\n' "$_C_GRN" "$_SC_CUR_CAT" "$_C_RST"
  fi
  _SC_CUR_CAT=""
}

# ----- assertions -----
assert_eq() {
  local exp="$1" act="$2" msg="$3"
  if [ "$exp" = "$act" ]; then
    pass "$msg"
  else
    fail "$msg (expected '$exp', got '$act')"
  fi
}

assert_contains() {
  local hay="$1" needle="$2" msg="$3"
  case "$hay" in
    *"$needle"*) pass "$msg" ;;
    *) fail "$msg (string does not contain '$needle')" ;;
  esac
}

assert_not_contains() {
  local hay="$1" needle="$2" msg="$3"
  case "$hay" in
    *"$needle"*) fail "$msg (string unexpectedly contains '$needle')" ;;
    *) pass "$msg" ;;
  esac
}

assert_file_exists() {
  local path="$1" msg="$2"
  if [ -f "$path" ]; then
    pass "$msg"
  else
    fail "$msg (file not found: $path)"
  fi
}

# Literal substring must be present in FILE (grep -F).
assert_grep_fixed() {
  local file="$1" token="$2" msg="$3"
  if [ ! -f "$file" ]; then
    fail "$msg (file not found: $file)"
    return 1
  fi
  if grep -Fq -- "$token" "$file"; then
    pass "$msg"
  else
    fail "$msg (token not found: '$token' in $file)"
  fi
}

# Extended regex must match somewhere in FILE (grep -E).
assert_grep_re() {
  local file="$1" re="$2" msg="$3"
  if [ ! -f "$file" ]; then
    fail "$msg (file not found: $file)"
    return 1
  fi
  if grep -Eq -- "$re" "$file"; then
    pass "$msg"
  else
    fail "$msg (pattern not matched: /$re/ in $file)"
  fi
}

assert_exit() {
  local exp="$1" act="$2" msg="$3"
  if [ "$exp" = "$act" ]; then
    pass "$msg"
  else
    fail "$msg (expected exit $exp, got $act)"
  fi
}

# ----- summary -----
finish() {
  printf '\n%s---- summary ----%s\n' "$_C_BLD" "$_C_RST"
  printf 'pass=%d  warn=%d  fail=%d\n' "$_SC_PASS_TOTAL" "$_SC_WARN_TOTAL" "$_SC_FAIL_TOTAL"
  if [ "$_SC_FAIL_TOTAL" -gt 0 ]; then
    printf '%sFAILED categories: %s%s\n' "$_C_RED" "${_SC_FAILED_CATS[*]:-<uncategorized>}" "$_C_RST"
    return 1
  fi
  printf '%sALL CHECKS PASSED%s\n' "$_C_GRN" "$_C_RST"
  return 0
}
