#!/usr/bin/env bash
# tests/suites/test_prometheus_config.sh — Validate prometheus/prometheus.yml
SUITE_FILE="prometheus/prometheus.yml"

describe "PROMETHEUS_CONFIG"

PROM_YML="${PROJECT_ROOT}/prometheus/prometheus.yml"

# 1. File exists
it "file exists: $SUITE_FILE"
assert_file_exists "$PROM_YML"
end_it

# 2. File not empty
it "file is non-empty"
assert_file_not_empty "$PROM_YML"
end_it

# 3. Valid YAML
it "valid YAML structure"
assert_valid_yaml "$PROM_YML"
end_it

# 4. No tab characters
it "no tab characters in YAML"
assert_no_tabs "$PROM_YML"
end_it

# 5. global: section exists
it "has 'global:' section"
if yaml_has_top_key "$PROM_YML" "global"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "missing top-level 'global:' key" )
    _assert_fail
fi
end_it

# 6. scrape_interval present
it "global contains scrape_interval"
if yaml_has_key "$PROM_YML" "scrape_interval"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "missing 'scrape_interval' under global" )
    _assert_fail
fi
end_it

# 7. evaluation_interval present
it "global contains evaluation_interval"
if yaml_has_key "$PROM_YML" "evaluation_interval"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "missing 'evaluation_interval' under global" )
    _assert_fail
fi
end_it

# 8. scrape_interval is valid time format
it "scrape_interval has valid time format (e.g. 15s)"
si_val=$(yaml_get_value "$PROM_YML" "scrape_interval")
assert_match '^[0-9]+(ms|s|m|h|d)$' "$si_val" "scrape_interval='$si_val' is not a valid duration"
end_it

# 9. scrape_configs: top-level key
it "has 'scrape_configs:' top-level key"
if yaml_has_top_key "$PROM_YML" "scrape_configs"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "missing top-level 'scrape_configs:' key" )
    _assert_fail
fi
end_it

# 10. At least 2 jobs
it "at least 2 scrape jobs defined"
job_count=$(yaml_count_pattern "$PROM_YML" "^[[:space:]]*- job_name:")
if (( job_count >= 2 )); then
    :
else
    _CURRENT_TEST_MESSAGES+=( "expected >= 2 jobs, found $job_count" )
    _assert_fail
fi
end_it

# 11. job 'prometheus' exists
it "job 'prometheus' exists"
if grep -qE "job_name:[[:space:]]*'?prometheus'?" "$PROM_YML"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "no job_name: 'prometheus' found" )
    _assert_fail
fi
end_it

# 12. job 'nexentaedge' exists
it "job 'nexentaedge' exists"
if grep -qE "job_name:[[:space:]]*'?nexentaedge'?" "$PROM_YML"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "no job_name: 'nexentaedge' found" )
    _assert_fail
fi
end_it

# 13. Job names unique
it "job names are unique (no duplicates)"
dupes=$(grep -oE "job_name:[[:space:]]*'?[^ ']+'?" "$PROM_YML" | sort | uniq -d)
if [[ -z "$dupes" ]]; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "duplicate job names: $dupes" )
    _assert_fail
fi
end_it

# 14. Targets match host:port format
it "all targets match host:port regex"
targets=$(grep -oE "'[^']*:[0-9]+'" "$PROM_YML" | tr -d "'")
all_ok=1
for t in $targets; do
    if ! [[ "$t" =~ ^[a-zA-Z0-9._-]+:[0-9]+$ ]]; then
        _CURRENT_TEST_MESSAGES+=( "invalid target format: '$t'" )
        all_ok=0
        break
    fi
done
if (( all_ok )); then :; else _assert_fail; fi
end_it

# 15. prometheus target contains :9090
it "prometheus job targets port 9090"
if grep -A20 "job_name:.*prometheus" "$PROM_YML" | grep -qE ":9090"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "prometheus job should target port 9090" )
    _assert_fail
fi
end_it

# 16. nexentaedge target contains :8881
it "nexentaedge job targets port 8881"
if grep -A5 "job_name:.*nexentaedge" "$PROM_YML" | grep -qE ":8881"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "nexentaedge job should target port 8881" )
    _assert_fail
fi
end_it

# 17. alerting: section exists
it "has 'alerting:' section"
if yaml_has_top_key "$PROM_YML" "alerting"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "missing top-level 'alerting:' key" )
    _assert_fail
fi
end_it

# 18. rule_files: section exists
it "has 'rule_files:' section"
if yaml_has_top_key "$PROM_YML" "rule_files"; then
    :
else
    _CURRENT_TEST_MESSAGES+=( "missing top-level 'rule_files:' key" )
    _assert_fail
fi
end_it
