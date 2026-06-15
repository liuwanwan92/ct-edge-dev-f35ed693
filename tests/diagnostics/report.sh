#!/usr/bin/env bash
# report.sh - Generate test reports from bats TAP output
#
# Usage: ./report.sh [format]
# Formats: text (default), tap, summary
#
# Runs all tests and produces a formatted report.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORMAT="${1:-text}"
REPORT_DIR="${SCRIPT_DIR}/reports"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

BATS="${SCRIPT_DIR}/vendor/bats-core/bin/bats"

if [[ ! -x "${BATS}" ]]; then
    echo "ERROR: bats-core not found at ${BATS}" >&2
    echo "Run: cd tests && make install-bats" >&2
    exit 1
fi

mkdir -p "${REPORT_DIR}"

run_tests() {
    "${BATS}" --tap \
        "${SCRIPT_DIR}/unit/" \
        "${SCRIPT_DIR}/integration/" \
        "${SCRIPT_DIR}/scenarios/" \
        2>&1
}

case "${FORMAT}" in
    tap)
        OUTPUT_FILE="${REPORT_DIR}/test-${TIMESTAMP}.tap"
        echo "Running tests (TAP format)..."
        run_tests | tee "${OUTPUT_FILE}"
        echo ""
        echo "Report: ${OUTPUT_FILE}"
        ;;
    summary)
        OUTPUT_FILE="${REPORT_DIR}/test-${TIMESTAMP}.summary"
        echo "Running tests..."
        TAP_OUTPUT="$(run_tests)"
        {
            echo "=== Test Summary ==="
            echo "Date: $(date)"
            echo ""
            total="$(echo "${TAP_OUTPUT}" | grep '^1\.\.' | head -1 | sed 's/1\.\.//')"
            passed="$(echo "${TAP_OUTPUT}" | grep -c '^ok ' || true)"
            failed="$(echo "${TAP_OUTPUT}" | grep -c '^not ok ' || true)"
            echo "Total:  ${total:-?}"
            echo "Passed: ${passed}"
            echo "Failed: ${failed}"
            echo ""
            if [[ "${failed}" -gt 0 ]]; then
                echo "=== FAILURES ==="
                echo "${TAP_OUTPUT}" | grep '^not ok '
            fi
        } | tee "${OUTPUT_FILE}"
        echo ""
        echo "Report: ${OUTPUT_FILE}"
        ;;
    text|*)
        OUTPUT_FILE="${REPORT_DIR}/test-${TIMESTAMP}.txt"
        echo "Running tests..."
        TAP_OUTPUT="$(run_tests)"
        {
            echo "========================================"
            echo " NexentaEdge Test Report"
            echo " $(date)"
            echo "========================================"
            echo ""

            total="$(echo "${TAP_OUTPUT}" | grep '^1\.\.' | head -1 | sed 's/1\.\.//')"
            passed="$(echo "${TAP_OUTPUT}" | grep -c '^ok ' || true)"
            failed="$(echo "${TAP_OUTPUT}" | grep -c '^not ok ' || true)"

            echo "Results: ${passed}/${total:-?} passed, ${failed} failed"
            echo ""

            if [[ "${failed}" -gt 0 ]]; then
                echo "FAILED TESTS:"
                echo "${TAP_OUTPUT}" | grep '^not ok ' | while IFS= read -r line; do
                    echo "  [FAIL] ${line#not ok }"
                done
                echo ""
            fi

            echo "ALL TEST RESULTS:"
            echo "${TAP_OUTPUT}" | grep '^\(ok\|not ok\) ' | while IFS= read -r line; do
                if [[ "${line}" =~ ^ok ]]; then
                    echo "  [PASS] ${line#ok }"
                else
                    echo "  [FAIL] ${line#not ok }"
                fi
            done
            echo ""
            echo "========================================"
        } | tee "${OUTPUT_FILE}"
        echo ""
        echo "Report: ${OUTPUT_FILE}"
        ;;
esac
