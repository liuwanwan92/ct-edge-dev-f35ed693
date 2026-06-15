#!/usr/bin/env bash
# race-detector.sh - Detect concurrent file access race conditions
#
# Actively probes for race conditions by running concurrent check
# invocations and comparing outputs for inconsistencies.
#
# Usage: ./race-detector.sh <service-type> <iterations>
# Example: ./race-detector.sh nfs 50

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export TESTS_ROOT="${SCRIPT_DIR}"
export REPO_ROOT
export LIB_ROOT="${SCRIPT_DIR}/lib"
export MOCK_ROOT="${SCRIPT_DIR}/mocks"
export FIXTURE_ROOT="${SCRIPT_DIR}/fixtures"
export SVC_CHECK_DIR="${REPO_ROOT}/prometheus/svc-checks"
export SCRIPTS_DIR="${REPO_ROOT}/scripts"

source "${LIB_ROOT}/sandbox.bash"
source "${LIB_ROOT}/trace.bash"
source "${LIB_ROOT}/mock.bash"
source "${LIB_ROOT}/assert.bash"
source "${LIB_ROOT}/http.bash"
source "${LIB_ROOT}/services.bash"

SERVICE="${1:-nfs}"
ITERATIONS="${2:-20}"

echo "=== Race Condition Detector ==="
echo "Service:    ${SERVICE}"
echo "Iterations: ${ITERATIONS}"
echo ""

# Counters
empty_count=0
stale_count=0
correct_count=0
race_detected=0
error_count=0

case "${SERVICE}" in
    nfs)
        script="$(get_nfs_script)"
        metric_name="nedge_nfs_service_status"
        mock_nfs_healthy
        ;;
    iscsi)
        script="$(get_iscsi_script)"
        metric_name="nedge_iscsi_service_status"
        mock_iscsi_healthy
        ;;
    s3)
        script="$(get_s3_script)"
        metric_name="nedge_s3_service_status"
        mock_s3_healthy
        ;;
    *)
        echo "Unknown service: ${SERVICE}" >&2
        exit 1
        ;;
esac

mock_ps_fast_fail
mock_set_response sleep "" 0
mock_set_response hostname "race-host"

for ((i = 1; i <= ITERATIONS; i++)); do
    # Reset sandbox for each iteration
    rm -rf "${SANDBOX_TMP:?}/"*  2>/dev/null || true

    # Run two concurrent scrapes (no wait between)
    local resp1 resp2
    resp1="$(http_get_metrics "${script}")" &
    local pid1=$!
    resp2="$(http_get_metrics "${script}")" &
    local pid2=$!

    wait ${pid1} 2>/dev/null || { resp1="ERROR"; error_count=$((error_count + 1)); }
    wait ${pid2} 2>/dev/null || { resp2="ERROR"; error_count=$((error_count + 1)); }

    local body1 body2
    body1="$(http_extract_body "${resp1}")"
    body2="$(http_extract_body "${resp2}")"

    local trim1 trim2
    trim1="$(echo "${body1}" | tr -d '[:space:]')"
    trim2="$(echo "${body2}" | tr -d '[:space:]')"

    # Analyze results
    if [[ -z "${trim1}" && -z "${trim2}" ]]; then
        empty_count=$((empty_count + 1))
    elif [[ "${trim1}" != "${trim2}" ]]; then
        race_detected=$((race_detected + 1))
        echo "  [RACE] Iteration ${i}: responses differ"
        echo "    resp1: $(echo "${trim1}" | head -c 60)..."
        echo "    resp2: $(echo "${trim2}" | head -c 60)..."
    elif [[ -n "${trim1}" ]]; then
        correct_count=$((correct_count + 1))
    fi

    # Also test stale cache scenario
    sandbox_inject_fixture "${SERVICE}" "${SERVICE}-healthy.prom" 2>/dev/null || \
        sandbox_inject_cache "${SERVICE}" "# HELP test
# TYPE test gauge
${metric_name}{service=\"test\",hostname=\"test\"} 1"

    # Switch to error state
    case "${SERVICE}" in
        nfs)   mock_nfs_not_mounted ;;
        iscsi) mock_iscsi_no_targets ;;
        s3)    mock_s3_service_down ;;
    esac

    local stale_resp
    stale_resp="$(http_get_metrics "${script}")"
    local stale_body
    stale_body="$(http_extract_body "${stale_resp}")"

    # Check if stale healthy value is served despite error state
    if echo "${stale_body}" | grep -q "} 1$" 2>/dev/null; then
        stale_count=$((stale_count + 1))
    fi

    # Reset mocks for next iteration
    mock_clear
    mock_reset_all
    case "${SERVICE}" in
        nfs)   mock_nfs_healthy ;;
        iscsi) mock_iscsi_healthy ;;
        s3)    mock_s3_healthy ;;
    esac
    mock_ps_fast_fail
    mock_set_response sleep "" 0
    mock_set_response hostname "race-host"
done

echo ""
echo "=== Results ==="
echo "Total iterations:       ${ITERATIONS}"
echo "Both empty (race):      ${empty_count}"
echo "Different responses:    ${race_detected}"
echo "Both correct:           ${correct_count}"
echo "Stale cache served:     ${stale_count}/${ITERATIONS}"
echo "Errors:                 ${error_count}"
echo ""

if [[ $((empty_count + race_detected)) -gt 0 ]]; then
    echo "VERDICT: Race conditions CONFIRMED"
    echo "  - First-invocation empty responses: ${empty_count} times"
    echo "  - Concurrent response differences:  ${race_detected} times"
    echo "  - Stale cache masking:              ${stale_count} times"
else
    echo "VERDICT: No race conditions detected"
    echo "  (Note: may need more iterations or different timing)"
fi

sandbox_destroy
