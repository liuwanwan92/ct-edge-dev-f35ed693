#!/usr/bin/env bash
# tests/suites/test_grafana_provisioning.sh — Validate Grafana provisioning YAML files
SUITE_FILE="prometheus/grafana/"

describe "GRAFANA_PROVISIONING"

DASH_PROV="${PROJECT_ROOT}/prometheus/grafana/NexentaEdge.yml"
DS_PROV="${PROJECT_ROOT}/prometheus/grafana/prometheus.yml"

# ── NexentaEdge.yml (dashboard provider) ──────────────────

# 1. File exists
it "dashboard provider file exists"
assert_file_exists "$DASH_PROV"
end_it

# 2. Valid YAML
it "dashboard provider is valid YAML"
assert_valid_yaml "$DASH_PROV"
end_it

# 3. apiVersion: 1
it "dashboard provider has apiVersion: 1"
val=$(yaml_get_value "$DASH_PROV" "apiVersion")
assert_eq "1" "$val" "apiVersion should be 1, got '$val'"
end_it

# 4. providers section exists
it "dashboard provider has 'providers' section"
if yaml_has_top_key "$DASH_PROV" "providers"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "missing 'providers:' key" )
    _assert_fail
fi
end_it

# 5. name: default
it "dashboard provider name is 'default'"
val=$(yaml_get_value "$DASH_PROV" "name")
assert_eq "default" "$val" "provider name should be 'default', got '$val'"
end_it

# 6. orgId present
it "dashboard provider has orgId"
if yaml_has_key "$DASH_PROV" "orgId"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "missing 'orgId'" )
    _assert_fail
fi
end_it

# 7. type: file
it "dashboard provider type is 'file'"
val=$(yaml_get_value "$DASH_PROV" "type")
assert_eq "file" "$val" "type should be 'file', got '$val'"
end_it

# 8. options.path = /etc/grafana/provisioning/dashboards/
it "dashboard provider path is /etc/grafana/provisioning/dashboards/"
val=$(yaml_get_value "$DASH_PROV" "path")
assert_eq "/etc/grafana/provisioning/dashboards/" "$val" \
    "options.path should be '/etc/grafana/provisioning/dashboards/', got '$val'"
end_it

# ── prometheus.yml (datasource provider) ──────────────────

# 9. File exists
it "datasource provider file exists"
assert_file_exists "$DS_PROV"
end_it

# 10. Valid YAML
it "datasource provider is valid YAML"
assert_valid_yaml "$DS_PROV"
end_it

# 11. apiVersion: 1
it "datasource provider has apiVersion: 1"
val=$(yaml_get_value "$DS_PROV" "apiVersion")
assert_eq "1" "$val" "apiVersion should be 1, got '$val'"
end_it

# 12. datasources section exists
it "datasource provider has 'datasources' section"
if yaml_has_top_key "$DS_PROV" "datasources"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "missing 'datasources:' key" )
    _assert_fail
fi
end_it

# 13. name: Prometheus
it "datasource name is 'Prometheus'"
val=$(yaml_get_value "$DS_PROV" "name")
assert_eq "Prometheus" "$val" "datasource name should be 'Prometheus', got '$val'"
end_it

# 14. type: prometheus
it "datasource type is 'prometheus'"
val=$(yaml_get_value "$DS_PROV" "type")
assert_eq "prometheus" "$val" "type should be 'prometheus', got '$val'"
end_it

# 15. access: proxy
it "datasource access is 'proxy'"
val=$(yaml_get_value "$DS_PROV" "access")
assert_eq "proxy" "$val" "access should be 'proxy', got '$val'"
end_it

# 16. URL contains PROMETHEUS_IP:PROMETHEUS_PORT placeholder
it "datasource URL has PROMETHEUS_IP:PROMETHEUS_PORT placeholder"
url_val=$(yaml_get_value "$DS_PROV" "url")
assert_contains "$url_val" "PROMETHEUS_IP:PROMETHEUS_PORT" \
    "URL should contain 'PROMETHEUS_IP:PROMETHEUS_PORT', got '$url_val'"
end_it

# 17. URL starts with http://
it "datasource URL uses http://"
assert_match '^http://' "$url_val" "URL should start with http://, got '$url_val'"
end_it

# 18. isDefault: true
it "datasource isDefault is true"
val=$(yaml_get_value "$DS_PROV" "isDefault")
assert_eq "true" "$val" "isDefault should be true, got '$val'"
end_it

# 19. version: 1
it "datasource version is 1"
val=$(yaml_get_value "$DS_PROV" "version")
assert_eq "1" "$val" "version should be 1, got '$val'"
end_it

# 20. editable: true
it "datasource is editable"
val=$(yaml_get_value "$DS_PROV" "editable")
assert_eq "true" "$val" "editable should be true, got '$val'"
end_it
