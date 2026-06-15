#!/usr/bin/env bash
# tests/suites/test_dashboard_json.sh — Validate Grafana dashboard JSON files
SUITE_FILE="prometheus/*.json"

describe "DASHBOARD_JSON"

FP1="${PROJECT_ROOT}/prometheus/NexentaEdge-Grafana-v2.1.3-FP1.json"
FP2="${PROJECT_ROOT}/prometheus/NexentaEdge-Grafana-v2.1.3-FP2.json"

# ── Helper: per-file checks ───────────────────────────────
_check_dashboard() {
    local file="$1" label="$2"

    # exists
    it "$label: file exists"
    assert_file_exists "$file"
    end_it

    # not empty
    it "$label: file is non-empty"
    assert_file_not_empty "$file"
    end_it

    # valid JSON
    it "$label: valid JSON"
    assert_valid_json "$file"
    end_it

    # has title containing NexentaEdge
    it "$label: has title containing 'NexentaEdge'"
    title=$(json_get_value "$file" "title")
    assert_contains "$title" "NexentaEdge" "title='$title' should contain 'NexentaEdge'"
    end_it

    # has non-empty panels array
    it "$label: has non-empty panels array"
    panel_count=$(json_array_length "$file" "panels")
    if (( panel_count > 0 )); then
        :
    else
        _CURRENT_TEST_MESSAGES+=( "panels array is empty or missing (count=$panel_count)" )
        _assert_fail
    fi
    end_it

    # has __requires section
    it "$label: has __requires section"
    if json_has_key "$file" "__requires"; then
        :
    else
        _CURRENT_TEST_MESSAGES+=( "missing '__requires' section" )
        _assert_fail
    fi
    end_it

    # references DS_PROMETHEUS
    it "$label: references DS_PROMETHEUS datasource variable"
    content=$(< "$file")
    assert_contains "$content" "DS_PROMETHEUS" "should reference \${DS_PROMETHEUS}"
    end_it

    # has version field
    it "$label: has version field"
    if json_has_key "$file" "version"; then
        :
    else
        _CURRENT_TEST_MESSAGES+=( "missing 'version' field" )
        _assert_fail
    fi
    end_it

    # has uid field
    it "$label: has uid field"
    uid=$(json_get_value "$file" "uid")
    if [[ -n "$uid" ]]; then
        :
    else
        _CURRENT_TEST_MESSAGES+=( "missing or empty 'uid' field" )
        _assert_fail
    fi
    end_it
}

# Run checks for each file
_check_dashboard "$FP1" "FP1"
_check_dashboard "$FP2" "FP2"

# ── Cross-file checks ─────────────────────────────────────

# FP2 should have >= panels than FP1
it "FP2 panel count >= FP1 panel count"
fp1_panels=$(json_array_length "$FP1" "panels")
fp2_panels=$(json_array_length "$FP2" "panels")
if (( fp2_panels >= fp1_panels )); then
    :
else
    _CURRENT_TEST_MESSAGES+=( "FP2 panels ($fp2_panels) < FP1 panels ($fp1_panels)" )
    _assert_fail
fi
end_it

# uid should match between FP1 and FP2
it "FP1 and FP2 share the same uid"
uid1=$(json_get_value "$FP1" "uid")
uid2=$(json_get_value "$FP2" "uid")
assert_eq "$uid1" "$uid2" "FP1 uid='$uid1' != FP2 uid='$uid2'"
end_it
