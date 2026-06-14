#!/usr/bin/env bash
#
# tests/test_monitoring_mismatch.sh — detect mismatches between monitoring
# configurations, templates, and actual service endpoints
#

set -uo pipefail
. "$(dirname "$0")/lib/common.sh"

PROM_DIR="$REPO_ROOT/prometheus"

# ──────────────────────────────────────────────────────────────
# Helper functions
# ──────────────────────────────────────────────────────────────

_check_prom_target() {
    local file="$PROM_DIR/prometheus.yml"
    if [ ! -f "$file" ]; then skip_test "prometheus.yml not found"; return; fi
    local target
    target="$(grep -A2 "job_name.*nexentaedge" "$file" | grep 'targets' | head -1)"
    if [ -z "$target" ]; then
        _fail "nexentaedge scrape target not found in prometheus.yml"
        return
    fi
    if printf '%s' "$target" | grep -qE '172\.20\.|192\.168\.|10\.'; then
        _pass "target uses example private IP (needs per-deployment override)"
        if grep -q 'targets.*8881' "$PROM_DIR/README.md" 2>/dev/null; then
            _pass "README documents the target configuration"
        else
            _fail "prometheus README does not clearly document that targets must be updated"
        fi
    fi
    if printf '%s' "$target" | grep -q ':8881'; then
        _pass "target uses metric port 8881"
    else
        _fail "target does not use expected metric port 8881"
    fi
}

_check_install_target_sub() {
    local script="$PROM_DIR/install_dashboard.sh"
    local prom_file="$PROM_DIR/prometheus.yml"
    if [ ! -f "$script" ] || [ ! -f "$prom_file" ]; then
        skip_test "required files not found"; return
    fi
    local actual_target
    actual_target="$(grep -oE "'[0-9.]+:8881'" "$prom_file" | head -1)"
    local script_pattern
    script_pattern="$(grep -oE "'[0-9.]+:8881'" "$script" | head -1)"
    if [ "$actual_target" = "$script_pattern" ]; then
        _pass "install script and prometheus.yml have matching target placeholder"
    else
        _fail "TARGET MISMATCH between install script and prometheus.yml"
        log_diag "prometheus.yml has: $actual_target"
        log_diag "install script expects: $script_pattern"
        log_diag "The sed substitution will silently fail"
    fi
}

_check_grafana_ds_placeholder() {
    local template="$PROM_DIR/grafana/prometheus.yml"
    if [ ! -f "$template" ]; then skip_test "grafana template not found"; return; fi
    if grep -q 'PROMETHEUS_IP:PROMETHEUS_PORT' "$template"; then
        _pass "datasource template has unsubstituted placeholder"
    else
        _fail "datasource template may already be substituted"
    fi
    local script="$PROM_DIR/install_dashboard.sh"
    if grep -q 'PROMETHEUS_IP:PROMETHEUS_PORT' "$script"; then
        _pass "install script substitutes datasource placeholder"
    else
        _fail "install script does not substitute PROMETHEUS_IP:PROMETHEUS_PORT"
    fi
}

_check_provisioning_path() {
    local yml="$PROM_DIR/grafana/NexentaEdge.yml"
    if [ ! -f "$yml" ]; then skip_test "NexentaEdge.yml not found"; return; fi
    local path
    path="$(grep 'path:' "$yml" | grep -oE '/[^\s]+' | head -1)"
    if [ -z "$path" ]; then
        _fail "no provisioning path found in NexentaEdge.yml"; return
    fi
    local script="$PROM_DIR/install_dashboard.sh"
    if grep -q "$path" "$script"; then
        _pass "install script mounts to correct provisioning path: $path"
    else
        _fail "install script may not mount dashboards to $path"
    fi
}

_check_metric_port() {
    local expected_port=8881 bad=0
    if grep -q ":$expected_port" "$PROM_DIR/prometheus.yml" 2>/dev/null; then
        _pass "prometheus.yml uses port $expected_port"
    else
        _fail "prometheus.yml does not reference port $expected_port"; bad=1
    fi
    local script="$PROM_DIR/install_dashboard.sh"
    if grep -q "METRICPORT=$expected_port" "$script" 2>/dev/null; then
        _pass "install_dashboard.sh uses METRICPORT=$expected_port"
    else
        local actual; actual="$(grep 'METRICPORT=' "$script" | head -1)"
        _fail "install_dashboard.sh metric port mismatch"
        log_diag "Expected METRICPORT=$expected_port, found: $actual"; bad=1
    fi
    if grep -q "$expected_port" "$PROM_DIR/README.md" 2>/dev/null; then
        _pass "README documents port $expected_port"
    else
        _fail "README does not document metric port $expected_port"; bad=1
    fi
}

_check_grafana_compat() {
    local script="$PROM_DIR/install_dashboard.sh"
    local grafana_ver
    grafana_ver="$(grep -oE 'grafana/grafana:[0-9.]+' "$script" | head -1 | cut -d: -f2)"
    for json_file in "$PROM_DIR"/NexentaEdge-Grafana-*.json; do
        [ -f "$json_file" ] || continue
        local name; name="$(basename "$json_file")"
        local nf; nf="$(_to_native_path "$json_file")"
        local schema_ver
        schema_ver="$($_PYTHON -c "
import json
with open(r'''$nf''') as f: d = json.load(f)
print(d.get('schemaVersion', 'unknown'))
" 2>/dev/null)"
        if [ "$schema_ver" = "unknown" ]; then
            _fail "$name missing schemaVersion field"
        else
            _pass "$name schemaVersion=$schema_ver (Grafana: $grafana_ver)"
        fi
    done
}

_check_prom_self_scrape() {
    local file="$PROM_DIR/prometheus.yml"
    [ ! -f "$file" ] && { skip_test "prometheus.yml not found"; return; }
    if grep -q "job_name.*prometheus" "$file"; then
        local target
        target="$(grep -A10 "job_name.*'prometheus'" "$file" | grep 'targets' | head -1)"
        if printf '%s' "$target" | grep -q 'localhost:9090'; then
            _pass "Prometheus self-scrape targets localhost:9090"
        else
            _fail "Prometheus self-scrape target unexpected: $target"
        fi
    else
        _fail "no Prometheus self-scrape job found"
    fi
}

_check_scrape_interval() {
    local file="$PROM_DIR/prometheus.yml"
    [ ! -f "$file" ] && { skip_test "prometheus.yml not found"; return; }
    local interval
    interval="$(grep 'scrape_interval' "$file" | head -1 | grep -oE '[0-9]+s')"
    if [ -n "$interval" ]; then
        _pass "scrape_interval = $interval"
    else
        _fail "could not parse scrape_interval"
    fi
}

_check_svc_check_port() {
    local readme="$PROM_DIR/svc-checks/README.md"
    local expected_port=8090
    if grep -q "$expected_port" "$readme" 2>/dev/null; then
        _pass "svc-checks README documents port $expected_port"
    else
        _fail "svc-checks README does not document port $expected_port"
    fi
    for check in "$PROM_DIR"/svc-checks/nedge-prom-*; do
        [ -f "$check" ] || continue
        local name; name="$(basename "$check")"
        if grep -q "$expected_port" "$check"; then
            _pass "$name references port $expected_port"
        else
            _fail "$name does not reference expected port $expected_port"
        fi
    done
}

_check_prom_yaml() {
    local file="$PROM_DIR/prometheus.yml"
    [ ! -f "$file" ] && { skip_test "prometheus.yml not found"; return; }
    if $_PYTHON -c "import yaml; yaml.safe_load(open('$(_to_native_path "$file")'))" 2>/dev/null; then
        _pass "prometheus.yml is valid YAML"
    else
        if $_PYTHON -c "
with open('$(_to_native_path "$file")') as f: content = f.read()
for i, line in enumerate(content.split(chr(10)), 1):
    if line.startswith(chr(9)):
        import sys; print(f'Tab indentation on line {i}', file=sys.stderr); sys.exit(1)
" 2>/dev/null; then
            _pass "prometheus.yml passes basic YAML checks"
        else
            _fail "prometheus.yml has YAML issues"
        fi
    fi
}

# ──────────────────────────────────────────────────────────────
# Test execution
# ──────────────────────────────────────────────────────────────
begin_suite "monitoring-mismatch"

run_test "prom-target-placeholder" _check_prom_target
run_test "install-target-substitution" _check_install_target_sub
run_test "grafana-datasource-placeholder" _check_grafana_ds_placeholder
run_test "dashboard-provisioning-path" _check_provisioning_path
run_test "metric-port-consistency" _check_metric_port
run_test "grafana-version-compatibility" _check_grafana_compat
run_test "prom-self-scrape" _check_prom_self_scrape
run_test "scrape-interval" _check_scrape_interval
run_test "svc-check-port-consistency" _check_svc_check_port
run_test "prom-yaml-valid" _check_prom_yaml

end_suite
