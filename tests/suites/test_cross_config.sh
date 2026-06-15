#!/usr/bin/env bash
# tests/suites/test_cross_config.sh — Cross-config consistency + conf/* scanning
SUITE_FILE="cross-config"

describe "CROSS_CONFIG"

PROM_YML="${PROJECT_ROOT}/prometheus/prometheus.yml"
INSTALL="${PROJECT_ROOT}/prometheus/install_dashboard.sh"
DS_PROV="${PROJECT_ROOT}/prometheus/grafana/prometheus.yml"
DASH_PROV="${PROJECT_ROOT}/prometheus/grafana/NexentaEdge.yml"
FP1="${PROJECT_ROOT}/prometheus/NexentaEdge-Grafana-v2.1.3-FP1.json"
FP2="${PROJECT_ROOT}/prometheus/NexentaEdge-Grafana-v2.1.3-FP2.json"
ISCSI_CHECK="${PROJECT_ROOT}/prometheus/svc-checks/nedge-prom-iscsi-check"
NFS_CHECK="${PROJECT_ROOT}/prometheus/svc-checks/nedge-prom-nfs-check"
S3_CHECK="${PROJECT_ROOT}/prometheus/svc-checks/nedge-prom-s3-check"

INSTALL_CONTENT=""
PROM_CONTENT=""
if [[ -f "$INSTALL" ]]; then INSTALL_CONTENT=$(< "$INSTALL"); fi
if [[ -f "$PROM_YML" ]]; then PROM_CONTENT=$(< "$PROM_YML"); fi

# ── Port consistency ──────────────────────────────────────

# 1. Port 9090 consistent
it "port 9090 consistent: prometheus.yml + install_dashboard.sh + docker -p"
assert_contains "$PROM_CONTENT" "9090" "prometheus.yml should reference port 9090"
assert_contains "$INSTALL_CONTENT" "9090:9090" "install_dashboard.sh should map 9090:9090"
end_it

# 2. Port 8881 consistent
it "port 8881 consistent: prometheus.yml targets + install_dashboard.sh METRICPORT"
assert_contains "$PROM_CONTENT" "8881" "prometheus.yml should reference port 8881 in targets"
assert_contains "$INSTALL_CONTENT" "METRICPORT=8881" "install_dashboard.sh should set METRICPORT=8881"
end_it

# 3. Port 3001 in docker -p
it "port 3001 mapped for Grafana in install_dashboard.sh"
assert_contains "$INSTALL_CONTENT" "3001:3000" "install_dashboard.sh should map 3001:3000"
end_it

# 4. Port 8090 in all three svc-checks
it "port 8090 referenced consistently in all svc-check scripts"
for script in "$ISCSI_CHECK" "$NFS_CHECK" "$S3_CHECK"; do
    if ! grep -q "8090" "$script"; then
        _CURRENT_TEST_MESSAGES+=( "$(basename "$script") missing port 8090 reference" )
        _assert_fail
        break
    fi
done
end_it

# 5. Port 3000 (Grafana internal) in install script
it "port 3000 referenced for Grafana internal in install_dashboard.sh"
assert_contains "$INSTALL_CONTENT" "3000" "should reference Grafana internal port 3000"
end_it

# ── Datasource consistency ────────────────────────────────

# 6. Datasource name "Prometheus" aligned
it "datasource name 'Prometheus' aligned between provisioning and install sed"
ds_content=""
if [[ -f "$DS_PROV" ]]; then ds_content=$(< "$DS_PROV"); fi
assert_contains "$ds_content" "name: Prometheus" "grafana/prometheus.yml should name datasource 'Prometheus'"
assert_contains "$INSTALL_CONTENT" "DS_PROMETHEUS" "install_dashboard.sh should sed-replace DS_PROMETHEUS"
end_it

# 7. DS_PROMETHEUS in dashboard JSON and install script
it "DS_PROMETHEUS variable aligned between dashboard JSON and install script"
fp1_content=""
if [[ -f "$FP1" ]]; then fp1_content=$(< "$FP1"); fi
assert_contains "$fp1_content" "DS_PROMETHEUS" "dashboard JSON should reference DS_PROMETHEUS"
assert_contains "$INSTALL_CONTENT" "DS_PROMETHEUS" "install script should replace DS_PROMETHEUS"
end_it

# 8. Scrape target port matches METRICPORT
it "scrape target port (8881) matches METRICPORT variable"
assert_contains "$INSTALL_CONTENT" "METRICPORT=8881" "METRICPORT should be 8881"
assert_contains "$PROM_CONTENT" ":8881" "prometheus.yml targets should use port 8881"
end_it

# ── Path consistency ─────────────────────────────────────

# 9. Grafana dashboard provisioning path matches docker -v mount
it "Grafana dashboard provisioning path matches docker -v mount"
dash_prov_content=""
if [[ -f "$DASH_PROV" ]]; then dash_prov_content=$(< "$DASH_PROV"); fi
prov_path=$(yaml_get_value "$DASH_PROV" "path" 2>/dev/null || echo "")
assert_eq "/etc/grafana/provisioning/dashboards/" "$prov_path" "provisioning path mismatch"
assert_contains "$INSTALL_CONTENT" "/etc/grafana/provisioning/dashboards/" "docker -v should mount dashboard provisioning path"
end_it

# 10. Datasources provisioning path matches docker -v mount
it "Grafana datasources provisioning path matches docker -v mount"
assert_contains "$INSTALL_CONTENT" "/etc/grafana/provisioning/datasources/" "docker -v should mount datasources provisioning path"
end_it

# 11. Prometheus config path matches docker -v mount
it "Prometheus config path /etc/prometheus/prometheus.yml matches docker -v mount"
assert_contains "$INSTALL_CONTENT" "/etc/prometheus/prometheus.yml" "docker -v should mount prometheus config"
end_it

# ── Deployment config scanning (conf/*) ──────────────────

# Helper: validate a single nesetup.json
_check_nesetup() {
    local profile="$1"
    local json_file="${PROJECT_ROOT}/conf/${profile}/nesetup.json"

    it "conf/$profile/nesetup.json: exists and is valid JSON"
    assert_file_exists "$json_file"
    assert_valid_json "$json_file"
    end_it

    it "conf/$profile/nesetup.json: has required keys (ccow, ccowd, rtrd)"
    local content
    content=$(< "$json_file")
    for key in ccow ccowd rtrd; do
        if ! json_has_key "$json_file" "$key"; then
            _CURRENT_TEST_MESSAGES+=( "missing required key: '$key'" )
            _assert_fail
            return
        fi
    done
    end_it

    it "conf/$profile/nesetup.json: has broker_interfaces"
    if json_has_key "$json_file" "broker_interfaces"; then
        :
    else
        _CURRENT_TEST_MESSAGES+=( "missing 'broker_interfaces'" )
        _assert_fail
    fi
    end_it

    it "conf/$profile/nesetup.json: has transport rtrd"
    assert_contains "$content" "rtrd" "should reference 'rtrd' transport"
    end_it
}

# Scan all 5 profiles
for profile in default gateway high-performance large-object-throughput single-node; do
    _check_nesetup "$profile"
done

# Extra: gateway should have empty rtrd.devices
it "conf/gateway/nesetup.json: rtrd.devices is empty array (gateway has no disks)"
gw_json="${PROJECT_ROOT}/conf/gateway/nesetup.json"
if [[ -f "$gw_json" ]]; then
    dev_count=$(json_array_length "$gw_json" "devices")
    if [[ "$dev_count" == "0" ]]; then
        :
    else
        _CURRENT_TEST_MESSAGES+=( "gateway rtrd.devices should be empty, found $dev_count entries" )
        _assert_fail
    fi
else
    _CURRENT_TEST_MESSAGES+=( "gateway nesetup.json not found" )
    _assert_fail
fi
end_it
