#!/usr/bin/env bash
# tests/check_monitoring.sh — Main entry point: orchestrates all monitoring config test suites
#
# Usage:
#   bash tests/check_monitoring.sh [--all] [--suite=<name>] [--verbose] [--help]
#
# Suites: prometheus, services, dashboards, install, grafana, cross
# Exit codes: 0=all pass, 1=failures, 2=framework error
set -uo pipefail

# ── Resolve paths ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-detect PROJECT_ROOT by walking up
PROJECT_ROOT="$SCRIPT_DIR"
for (( i=0; i<5; i++ )); do
    if [[ -f "$PROJECT_ROOT/prometheus/prometheus.yml" ]]; then
        break
    fi
    PROJECT_ROOT="$(dirname "$PROJECT_ROOT")"
done
if [[ ! -f "$PROJECT_ROOT/prometheus/prometheus.yml" ]]; then
    echo "ERROR: Cannot find project root (looking for prometheus/prometheus.yml)" >&2
    echo "       Set PROJECT_ROOT environment variable or run from project directory." >&2
    exit 2
fi
export PROJECT_ROOT

# ── Parse arguments ───────────────────────────────────────
RUN_ALL=0
SELECTED_SUITE=""
VERBOSE=0

for arg in "$@"; do
    case "$arg" in
        --all|-a)
            RUN_ALL=1
            ;;
        --suite=*)
            SELECTED_SUITE="${arg#--suite=}"
            ;;
        --verbose|-v)
            VERBOSE=1
            ;;
        --help|-h)
            cat << 'HELP'
Usage: check_monitoring.sh [OPTIONS]

Options:
  --all, -a          Run all test suites (default if no suite specified)
  --suite=NAME       Run a specific suite:
                       prometheus  - Prometheus scrape config validation
                       services    - Service probe script validation
                       dashboards  - Grafana dashboard JSON validation
                       install     - install_dashboard.sh validation
                       grafana     - Grafana provisioning config validation
                       cross       - Cross-config consistency + conf/* scan
  --verbose, -v      Verbose output
  --help, -h         Show this help

Exit codes:
  0  All tests passed
  1  Some tests failed
  2  Framework/setup error

Examples:
  bash tests/check_monitoring.sh --all
  bash tests/check_monitoring.sh --suite=prometheus
  CI=true bash tests/check_monitoring.sh --all
HELP
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Use --help for usage information." >&2
            exit 2
            ;;
    esac
done

# Default to --all if no suite specified
if [[ -z "$SELECTED_SUITE" ]]; then
    RUN_ALL=1
fi

# ── Source framework and helpers ──────────────────────────
LIB_DIR="${SCRIPT_DIR}/lib"
for lib in test_framework.sh yaml_helpers.sh json_helpers.sh mock_env.sh; do
    if [[ ! -f "$LIB_DIR/$lib" ]]; then
        echo "ERROR: Missing library: $LIB_DIR/$lib" >&2
        exit 2
    fi
    # shellcheck disable=SC1090
    source "$LIB_DIR/$lib"
done

# ── Suite mapping ─────────────────────────────────────────
declare -A SUITE_FILES=(
    [prometheus]="test_prometheus_config.sh"
    [services]="test_svc_checks.sh"
    [dashboards]="test_dashboard_json.sh"
    [install]="test_install_script.sh"
    [grafana]="test_grafana_provisioning.sh"
    [cross]="test_cross_config.sh"
)

# Ordered list for consistent output
SUITE_ORDER=(prometheus services dashboards install grafana cross)

# ── Run suites ────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  NexentaEdge Monitoring Config Self-Check"
echo "  Project root: $PROJECT_ROOT"
echo "================================================================"

_run_suite() {
    local name="$1"
    local suite_file="${SUITE_FILES[$name]:-}"

    if [[ -z "$suite_file" ]]; then
        echo "ERROR: Unknown suite '$name'" >&2
        echo "Available suites: ${SUITE_ORDER[*]}" >&2
        return 2
    fi

    local full_path="${SCRIPT_DIR}/suites/${suite_file}"
    if [[ ! -f "$full_path" ]]; then
        echo "ERROR: Suite file not found: $full_path" >&2
        return 2
    fi

    # Source the suite (it shares the framework's counters)
    # shellcheck disable=SC1090
    source "$full_path"
}

if (( RUN_ALL )); then
    for suite_name in "${SUITE_ORDER[@]}"; do
        _run_suite "$suite_name"
    done
else
    _run_suite "$SELECTED_SUITE"
fi

# ── Summary ───────────────────────────────────────────────
print_summary

exit "$(get_exit_code)"
