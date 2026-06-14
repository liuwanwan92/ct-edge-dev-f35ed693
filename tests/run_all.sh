#!/usr/bin/env bash
#
# tests/run_all.sh — top-level CI test runner
#
# Executes all test_*.sh files in the tests/ directory and reports
# aggregate results. Returns exit code 0 if all suites pass, 1 if
# any suite fails.
#
# Usage:
#   ./tests/run_all.sh                    # Run all suites
#   ./tests/run_all.sh conf-validate      # Run only conf-validate suite
#   TEST_VERBOSE=1 ./tests/run_all.sh     # Show passing tests too
#   TEST_FILTER=regex ./tests/run_all.sh  # Filter tests by name
#
# Environment:
#   TEST_VERBOSE=1     show PASS lines (default: only FAIL + summary)
#   TEST_STOP_ON_FAIL=1  abort on first failure (across all suites)
#   TEST_FILTER=<re>   only run tests matching this regex
#   TEST_SUITES="a b"  space-separated list of suite names to run
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colours
if [ -t 1 ]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
    C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

# ──────────────────────────────────────────────────────────────
# Discover test files
# ──────────────────────────────────────────────────────────────
TEST_FILES=()
for f in "$SCRIPT_DIR"/test_*.sh; do
    [ -f "$f" ] && TEST_FILES+=("$f")
done

if [ "${#TEST_FILES[@]}" -eq 0 ]; then
    printf "${C_RED}No test files found in %s${C_RESET}\n" "$SCRIPT_DIR"
    exit 2
fi

# If specific suites are requested via CLI args or env
if [ -n "${TEST_SUITES:-}" ]; then
    FILTERED=()
    for f in "${TEST_FILES[@]}"; do
        base="$(basename "$f" .sh)"
        base="${base#test_}"
        for s in $TEST_SUITES; do
            if [ "$base" = "$s" ]; then
                FILTERED+=("$f")
                break
            fi
        done
    done
    TEST_FILES=("${FILTERED[@]}")
fi

# If a single suite is passed as first argument
if [ -n "${1:-}" ] && [ -f "$SCRIPT_DIR/test_${1}.sh" ]; then
    TEST_FILES=("$SCRIPT_DIR/test_${1}.sh")
fi

# ──────────────────────────────────────────────────────────────
# Print header
# ──────────────────────────────────────────────────────────────
printf "\n${C_BOLD}╔══════════════════════════════════════════════════╗${C_RESET}\n"
printf "${C_BOLD}║    NexentaEdge DevOps CI Self-Check Suite       ║${C_RESET}\n"
printf "${C_BOLD}╚══════════════════════════════════════════════════╝${C_RESET}\n"
printf "  Repo:     %s\n" "$REPO_ROOT"
printf "  Suites:   %d\n" "${#TEST_FILES[@]}"
printf "  Date:     %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "\n"

# ──────────────────────────────────────────────────────────────
# Execute suites
# ──────────────────────────────────────────────────────────────
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
SUITES_PASSED=0
SUITES_FAILED=0
FAILED_SUITES=()

for test_file in "${TEST_FILES[@]}"; do
    suite_name="$(basename "$test_file" .sh)"

    # Run each test file in a subshell to isolate failures
    output="$(bash "$test_file" 2>&1)"
    rc=$?

    # Print the output
    printf '%s\n' "$output"

    # Parse results from the summary line
    # Format: "  Tests: N  Pass: N  Fail: N  Skip: N"
    local_pass="$(printf '%s\n' "$output" | grep 'Pass:' | tail -1 | grep -oE 'Pass: [0-9]+' | grep -oE '[0-9]+')"
    local_fail="$(printf '%s\n' "$output" | grep 'Fail:' | tail -1 | grep -oE 'Fail: [0-9]+' | grep -oE '[0-9]+')"
    local_skip="$(printf '%s\n' "$output" | grep 'Skip:' | tail -1 | grep -oE 'Skip: [0-9]+' | grep -oE '[0-9]+')"

    local_pass="${local_pass:-0}"
    local_fail="${local_fail:-0}"
    local_skip="${local_skip:-0}"

    TOTAL_PASS=$((TOTAL_PASS + local_pass))
    TOTAL_FAIL=$((TOTAL_FAIL + local_fail))
    TOTAL_SKIP=$((TOTAL_SKIP + local_skip))

    if [ "$rc" -eq 0 ] && [ "$local_fail" -eq 0 ]; then
        SUITES_PASSED=$((SUITES_PASSED + 1))
    else
        SUITES_FAILED=$((SUITES_FAILED + 1))
        FAILED_SUITES+=("$suite_name")
    fi

    if [ "${TEST_STOP_ON_FAIL:-0}" = "1" ] && [ "$local_fail" -gt 0 ]; then
        printf "\n${C_RED}Aborting (TEST_STOP_ON_FAIL=1)${C_RESET}\n"
        break
    fi
done

# ──────────────────────────────────────────────────────────────
# Print aggregate summary
# ──────────────────────────────────────────────────────────────
TOTAL_TESTS=$((TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP))

printf "\n${C_BOLD}╔══════════════════════════════════════════════════╗${C_RESET}\n"
printf "${C_BOLD}║              Aggregate Results                  ║${C_RESET}\n"
printf "${C_BOLD}╚══════════════════════════════════════════════════╝${C_RESET}\n"
printf "\n"
printf "  Total tests:    %d\n" "$TOTAL_TESTS"
printf "  ${C_GREEN}Passed:         %d${C_RESET}\n" "$TOTAL_PASS"
printf "  ${C_RED}Failed:         %d${C_RESET}\n" "$TOTAL_FAIL"
printf "  ${C_YELLOW}Skipped:        %d${C_RESET}\n" "$TOTAL_SKIP"
printf "\n"
printf "  Suites passed:  %d / %d\n" "$SUITES_PASSED" "$((SUITES_PASSED + SUITES_FAILED))"

if [ "${#FAILED_SUITES[@]}" -gt 0 ]; then
    printf "\n  ${C_RED}Failed suites:${C_RESET}\n"
    for s in "${FAILED_SUITES[@]}"; do
        printf "    ${C_RED}✗ %s${C_RESET}\n" "$s"
    done
fi

printf "\n"

if [ "$TOTAL_FAIL" -gt 0 ]; then
    printf "${C_RED}${C_BOLD}OVERALL: FAILED${C_RESET} (%d failures)\n\n" "$TOTAL_FAIL"
    exit 1
else
    printf "${C_GREEN}${C_BOLD}OVERALL: PASSED${C_RESET}\n\n"
    exit 0
fi
