#!/usr/bin/env bash
# state-trace.sh - Full execution tracer for health check diagnostics
#
# Runs health checks with complete tracing, producing a detailed log of
# every state transition, mock invocation, and cache file change.
#
# Usage: ./state-trace.sh [nfs|iscsi|s3|all] [scenario-name]
# Output: trace-YYYYMMDD-HHMMSS.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source framework libraries (standalone mode, not via bats)
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

SERVICE="${1:-all}"
SCENARIO="${2:-all-healthy}"
NUM_RUNS=5

run_trace() {
    local svc_type="$1"
    local script scenario_name

    case "${svc_type}" in
        nfs)
            script="$(get_nfs_script)"
            scenario_name="nfs/${SCENARIO}"
            ;;
        iscsi)
            script="$(get_iscsi_script)"
            scenario_name="iscsi/${SCENARIO}"
            ;;
        s3)
            script="$(get_s3_script)"
            scenario_name="s3/${SCENARIO}"
            ;;
        *)
            echo "Unknown service: ${svc_type}" >&2
            return 1
            ;;
    esac

    echo "=== Tracing ${svc_type} with scenario ${SCENARIO} ==="
    echo "Runs: ${NUM_RUNS}"
    echo ""

    # Try to load scenario; if not found, use convenience mock
    if [[ -f "${MOCK_ROOT}/scenarios/${scenario_name}.sh" ]]; then
        mock_load_scenario "$(echo "${scenario_name}" | cut -d/ -f1)" \
                           "$(echo "${scenario_name}" | cut -d/ -f2)"
    else
        case "${svc_type}" in
            nfs)   mock_nfs_healthy ;;
            iscsi) mock_iscsi_healthy ;;
            s3)    mock_s3_healthy ;;
        esac
    fi

    mock_ps_fast_fail
    mock_set_response sleep "" 0
    mock_set_response hostname "trace-host"

    local run
    for ((run = 1; run <= NUM_RUNS; run++)); do
        echo "--- Run ${run}/${NUM_RUNS} ---"

        # Record pre-state
        local cache_before="(missing)"
        if sandbox_cache_exists "${svc_type}"; then
            cache_before="$(sandbox_cache_size "${svc_type}") bytes"
        fi
        echo "  Pre-cache:  ${cache_before}"

        # Run the check
        local response
        response="$(http_get_metrics "${script}")"
        local body
        body="$(http_extract_body "${response}")"

        # Extract metric values
        local metric_name="nedge_${svc_type}_service_status"
        local values
        values="$(prom_metric_values "${body}" "${metric_name}" 2>/dev/null || echo "(none)")"

        echo "  Response:   $(echo "${body}" | wc -l | tr -d ' ') lines"
        echo "  Metrics:    ${values}"

        # Wait for background and record post-state
        _sandbox_wait_background
        local cache_after="(missing)"
        if sandbox_cache_exists "${svc_type}"; then
            cache_after="$(sandbox_cache_size "${svc_type}") bytes"
        fi
        echo "  Post-cache: ${cache_after}"
        echo ""
    done
}

# Main
sandbox_create
mock_reset_all
trace_init

OUTPUT_FILE="trace-$(date +%Y%m%d-%H%M%S).log"

{
    echo "NexentaEdge Health Check State Trace"
    echo "Date: $(date)"
    echo "Service: ${SERVICE}"
    echo "Scenario: ${SCENARIO}"
    echo "Runs per service: ${NUM_RUNS}"
    echo "========================================"
    echo ""

    if [[ "${SERVICE}" == "all" ]]; then
        run_trace "nfs"
        echo ""
        run_trace "iscsi"
        echo ""
        run_trace "s3"
    else
        run_trace "${SERVICE}"
    fi

    echo "========================================"
    echo ""
    trace_summary
} 2>&1 | tee "${OUTPUT_FILE}"

echo ""
echo "Trace written to: ${OUTPUT_FILE}"

# Cleanup
sandbox_destroy
