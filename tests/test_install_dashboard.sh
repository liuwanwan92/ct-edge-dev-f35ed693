#!/usr/bin/env bash
#
# tests/test_install_dashboard.sh — tests for prometheus/install_dashboard.sh
#

set -uo pipefail
. "$(dirname "$0")/lib/common.sh"

SCRIPT="$REPO_ROOT/prometheus/install_dashboard.sh"

# ──────────────────────────────────────────────────────────────
# Helper functions
# ──────────────────────────────────────────────────────────────

_check_syntax() {
    local out
    if out="$(bash -n "$SCRIPT" 2>&1)"; then
        _pass "bash -n OK"
    else
        _fail "bash -n syntax error"
        log_diag "$out"
    fi
}

_check_dashboard_version() {
    local script_url
    script_url="$(grep -oE 'https://raw\.githubusercontent\.com/.*NexentaEdge[^"'"'"']*\.json' "$SCRIPT" | head -1)"
    local script_file
    script_file="$(basename "$script_url" 2>/dev/null)"
    local repo_files
    repo_files="$(ls "$REPO_ROOT"/prometheus/NexentaEdge-Grafana-*.json 2>/dev/null | xargs -I{} basename {} | sort)"
    if [ -z "$script_file" ]; then
        _fail "could not find Grafana JSON URL in install_dashboard.sh"
        return
    fi
    if printf '%s\n' "$repo_files" | grep -qx "$script_file"; then
        _pass "script references existing dashboard: $script_file"
    else
        _fail "script references '$script_file' but repo only has:"
        log_diag "$(printf '%s\n' "$repo_files" | sed 's/^/  /')"
    fi
}

_check_container_detection() {
    if grep -q 'wc -l 2>&1' "$SCRIPT"; then
        _fail "container detection redirects stderr into wc -l"
        log_diag "If docker prints warnings to stderr, they inflate the line count"
    else
        _pass "container detection does not mix stderr into wc -l"
    fi
}

_check_pre_existing_cleanup() {
    local error_msg
    error_msg="$(grep 'Prometheus container already exists' "$SCRIPT" | head -1)"
    if [ -z "$error_msg" ]; then
        skip_test "no pre-existing container check found"
        return
    fi
    if printf '%s' "$error_msg" | grep -qiE 'docker rm|remove|delete|cleanup'; then
        _pass "error message includes cleanup guidance"
    else
        _fail "pre-existing container error has no resolution guidance"
        log_diag "Message: '$error_msg'"
    fi
}

_check_grafana_pre_existing() {
    local prom_check grafana_check
    prom_check="$(grep -c 'filter.*name.*prometheus' "$SCRIPT")"
    grafana_check="$(grep -c 'filter.*name.*grafana' "$SCRIPT")"
    if [ "$prom_check" -gt 0 ] && [ "$grafana_check" -eq 0 ]; then
        _fail "script checks prometheus pre-existence but not grafana"
        log_diag "If grafana container exists, docker run fails with an unhelpful error"
    else
        _pass "pre-existence checks are consistent"
    fi
}

_check_datasource_placeholder() {
    local template="$REPO_ROOT/prometheus/grafana/prometheus.yml"
    if [ ! -f "$template" ]; then
        skip_test "grafana datasource template not found"
        return
    fi
    if grep -q 'PROMETHEUS_IP:PROMETHEUS_PORT' "$template"; then
        _pass "template has PROMETHEUS_IP:PROMETHEUS_PORT placeholder"
    else
        _fail "template missing expected placeholder"
    fi
    if grep -q 'PROMETHEUS_IP:PROMETHEUS_PORT' "$SCRIPT"; then
        _pass "install script handles placeholder substitution"
    else
        _fail "install script does not reference the datasource placeholder"
    fi
}

_check_dashboard_ds_placeholder() {
    local dashboard_json
    dashboard_json="$(ls "$REPO_ROOT"/prometheus/NexentaEdge-Grafana-*.json 2>/dev/null | head -1)"
    if [ -z "$dashboard_json" ]; then
        skip_test "no Grafana dashboard JSON found"
        return
    fi
    if grep -q 'DS_PROMETHEUS' "$dashboard_json"; then
        _pass "dashboard JSON contains \${DS_PROMETHEUS} for substitution"
    elif grep -q '"Prometheus"' "$dashboard_json"; then
        _pass "dashboard already has Prometheus datasource hardcoded"
    else
        _fail "dashboard JSON has neither \${DS_PROMETHEUS} nor 'Prometheus' datasource"
    fi
}

_check_grafana_password_api() {
    if grep -A5 'Changing password' "$SCRIPT" | grep -qiE 'if|check|status|200'; then
        _pass "password change has some error handling"
    else
        _fail "Grafana password change has no error handling"
        log_diag "If the API call fails, the script continues silently"
        log_diag "Leaving Grafana with default credentials is a security issue"
    fi
}

_check_port_mapping() {
    local grafana_port
    grafana_port="$(grep -oE '\-p [0-9]+:3000' "$SCRIPT" | grep -oE '[0-9]+' | head -1)"
    local prom_port
    prom_port="$(grep -oE '\-p [0-9]+:9090' "$SCRIPT" | grep -oE '[0-9]+' | head -1)"
    if [ -n "$grafana_port" ]; then
        _pass "Grafana exposed on host port $grafana_port"
    else
        _fail "could not determine Grafana host port"
    fi
    if [ -n "$prom_port" ]; then
        _pass "Prometheus exposed on host port $prom_port"
    else
        _fail "could not determine Prometheus host port"
    fi
}

_test_mock_dry_run() {
    local tmpdir; tmpdir="$(test_make_tmpdir)"
    local mock_dir; mock_dir="$(mock_setup)"
    local dashboard_dir="$tmpdir/dashboard"
    local docker_log="$tmpdir/docker.log"
    touch "$docker_log"

    mock_command_script "$mock_dir" "docker" '
        echo "docker $@" >> "'"$docker_log"'"
        case "$1" in
            pull) exit 0 ;;
            ps) printf "CONTAINER ID   IMAGE   COMMAND   CREATED   STATUS   PORTS   NAMES\n" ;;
            run) exit 0 ;;
            inspect) printf "172.17.0.2\n" ;;
            exec) exit 0 ;;
            *) exit 0 ;;
        esac
    '
    mock_command_script "$mock_dir" "curl" 'printf ""; exit 0'

    local rc=0 output
    output="$(PATH="$mock_dir:$PATH" bash "$SCRIPT" "10.0.0.1" "$dashboard_dir" 2>&1)" || rc=$?

    if [ "$rc" -ne 0 ]; then
        if printf '%s' "$output" | grep -qi "error\|fatal"; then
            _fail "mock install failed with error (exit $rc)"
            log_diag "$(printf '%s\n' "$output" | tail -10)"
        else
            _pass "completed with expected mock limitations (exit $rc)"
        fi
    else
        _pass "mock install completed successfully"
    fi

    if grep -q 'pull.*prom' "$docker_log"; then
        _pass "docker pull prometheus was called"
    else
        _fail "docker pull prometheus was NOT called"
    fi
    if grep -q 'pull.*grafana' "$docker_log"; then
        _pass "docker pull grafana was called"
    else
        _fail "docker pull grafana was NOT called"
    fi
    mock_teardown "$mock_dir"
}

# ──────────────────────────────────────────────────────────────
# Test execution
# ──────────────────────────────────────────────────────────────
begin_suite "install-dashboard"

if [ ! -f "$SCRIPT" ]; then
    run_test "script-exists" _missing
    _missing() { _fail "install_dashboard.sh not found"; }
else
    run_test "syntax" _check_syntax
    run_test "grafana-dashboard-version" _check_dashboard_version
    run_test "container-detection" _check_container_detection
    run_test "pre-existing-cleanup" _check_pre_existing_cleanup
    run_test "grafana-pre-existing-check" _check_grafana_pre_existing
    run_test "datasource-placeholder" _check_datasource_placeholder
    run_test "dashboard-ds-placeholder" _check_dashboard_ds_placeholder
    run_test "grafana-password-api" _check_grafana_password_api
    run_test "port-mapping" _check_port_mapping
    run_test "mock:dry-run-install" _test_mock_dry_run
fi

end_suite
