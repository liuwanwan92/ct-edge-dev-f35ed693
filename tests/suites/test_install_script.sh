#!/usr/bin/env bash
# tests/suites/test_install_script.sh — Validate install_dashboard.sh structure
SUITE_FILE="prometheus/install_dashboard.sh"

describe "INSTALL_SCRIPT"

INSTALL="${PROJECT_ROOT}/prometheus/install_dashboard.sh"
CONTENT=""
if [[ -f "$INSTALL" ]]; then
    CONTENT=$(< "$INSTALL")
fi

# 1. File exists
it "install_dashboard.sh exists"
assert_file_exists "$INSTALL"
end_it

# 2. Non-empty
it "install_dashboard.sh is non-empty"
assert_file_not_empty "$INSTALL"
end_it

# 3. Bash shebang
it "has bash shebang"
first_line=$(head -1 "$INSTALL")
assert_match 'bash' "$first_line" "first line should contain bash, got: $first_line"
end_it

# 4. Valid bash syntax
it "bash syntax check passes (bash -n)"
assert_bash_syntax "$INSTALL"
end_it

# 5. die() function exists and exits 1
it "die() function calls exit 1"
if grep -qE 'die\(\).*\{.*exit 1' "$INSTALL" 2>/dev/null || \
   grep -A3 '^die()' "$INSTALL" | grep -q 'exit 1'; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "die() should call 'exit 1'" )
    _assert_fail
fi
end_it

# 6. Checks for docker prerequisite
it "checks for docker prerequisite (which docker)"
assert_contains "$CONTENT" "which docker" "should check 'which docker'"
end_it

# 7. Checks for curl prerequisite
it "checks for curl prerequisite (which curl)"
assert_contains "$CONTENT" "which curl" "should check 'which curl'"
end_it

# 8. References prometheus.yml
it "references prometheus.yml config file"
assert_contains "$CONTENT" "prometheus.yml" "should reference prometheus.yml"
end_it

# 9. References NexentaEdge.yml dashboard provisioning
it "references NexentaEdge.yml provisioning config"
assert_contains "$CONTENT" "NexentaEdge.yml" "should reference NexentaEdge.yml"
end_it

# 10. References grafana/prometheus.yml datasource provisioning
it "references grafana/prometheus.yml provisioning config"
assert_contains "$CONTENT" "grafana/prometheus.yml" "should reference grafana/prometheus.yml"
end_it

# 11. sed substitutes DS_PROMETHEUS
it "sed substitutes \${DS_PROMETHEUS}"
assert_contains "$CONTENT" "DS_PROMETHEUS" "should sed-replace DS_PROMETHEUS"
end_it

# 12. sed substitutes PROMETHEUS_IP:PROMETHEUS_PORT
it "sed substitutes PROMETHEUS_IP:PROMETHEUS_PORT"
assert_contains "$CONTENT" "PROMETHEUS_IP:PROMETHEUS_PORT" "should sed-replace PROMETHEUS_IP:PROMETHEUS_PORT"
end_it

# 13. Port mapping 9090:9090
it "docker run maps port 9090:9090 for Prometheus"
assert_contains "$CONTENT" "9090:9090" "should map port 9090:9090"
end_it

# 14. Port mapping 3001:3000
it "docker run maps port 3001:3000 for Grafana"
assert_contains "$CONTENT" "3001:3000" "should map port 3001:3000"
end_it

# 15. METRICPORT=8881
it "sets METRICPORT=8881"
assert_contains "$CONTENT" "METRICPORT=8881" "should set METRICPORT=8881"
end_it

# 16. docker pull commands
it "contains docker pull commands"
assert_contains "$CONTENT" "docker pull" "should pull docker images"
end_it

# 17. Container names: prometheus and grafana
it "names containers 'prometheus' and 'grafana'"
assert_contains "$CONTENT" '--name="prometheus"' "should name prometheus container"
assert_contains "$CONTENT" '--name="grafana"' "should name grafana container"
end_it

# 18. Volume mounts reference provisioning paths
it "docker volume mounts match Grafana provisioning paths"
assert_contains "$CONTENT" "/etc/grafana/provisioning/dashboards/" "should mount dashboard provisioning dir"
assert_contains "$CONTENT" "/etc/grafana/provisioning/datasources/" "should mount datasource provisioning dir"
end_it

# 19. Prometheus config mount matches /etc/prometheus/prometheus.yml
it "docker volume mounts Prometheus config to /etc/prometheus/prometheus.yml"
assert_contains "$CONTENT" "/etc/prometheus/prometheus.yml" "should mount prometheus config"
end_it

# 20. WARNING: GitHub URL references v1.0 dashboard (stale?)
it "WARN: GitHub download URL references existing dashboard version"
if grep -q 'NexentaEdge-Grafana-v1.0.json' "$INSTALL"; then
    # Check if the referenced file actually exists in the repo
    if [[ ! -f "${PROJECT_ROOT}/prometheus/NexentaEdge-Grafana-v1.0.json" ]]; then
        _CURRENT_TEST_MESSAGES+=( "install_dashboard.sh downloads 'NexentaEdge-Grafana-v1.0.json' from GitHub but only v2.1.3-FP1/FP2 exist in repo — stale URL?" )
        _assert_fail
    fi
fi
end_it

# 21. mkdir -p for dashboard directory
it "creates dashboard directory with mkdir -p"
assert_contains "$CONTENT" "mkdir -p" "should use mkdir -p for directory creation"
end_it

# 22. PASSWORD variable defined
it "defines PASSWORD variable for Grafana admin"
assert_contains "$CONTENT" 'PASSWORD=' "should define PASSWORD variable"
end_it

# 23. Mock test: docker missing → exit 1 with error message
it "exits with code 1 and 'Docker' message when docker is missing"
setup_mock_env
remove_mock "docker"
# Prepend mock dir so mock 'which' intercepts docker/curl checks
_out=$(PATH="$_MOCK_DIR/bin:$PATH" bash "$INSTALL" 2>&1) || _rc=$?
_rc=${_rc:-0}
teardown_mock_env
if (( _rc == 1 )) && [[ "$_out" == *"Docker"* || "$_out" == *"docker"* ]]; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "expected exit 1 + 'Docker' message when docker missing, got rc=$_rc" )
    _assert_fail
fi
end_it

# 24. Mock test: curl missing → exit 1 with error message
it "exits with code 1 and 'curl' message when curl is missing"
setup_mock_env
remove_mock "curl"
_out=$(PATH="$_MOCK_DIR/bin:$PATH" bash "$INSTALL" 2>&1) || _rc=$?
_rc=${_rc:-0}
teardown_mock_env
if (( _rc == 1 )) && [[ "$_out" == *"curl"* ]]; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "expected exit 1 + 'curl' message when curl missing, got rc=$_rc" )
    _assert_fail
fi
end_it
