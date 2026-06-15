#!/usr/bin/env bash
# assert.bash - Prometheus metric assertion helpers
#
# Parse Prometheus exposition format and assert on metric values.
# Format: metric_name{label="value",...} numeric_value

# Extract the numeric value of a Prometheus metric
# Usage: prom_metric_value <output> <metric_name> [label_filter]
# label_filter: optional "key=value" to match specific label
prom_metric_value() {
    local output="$1"
    local metric_name="$2"
    local label_filter="${3:-}"

    local line
    while IFS= read -r line; do
        # Skip comments
        [[ "${line}" =~ ^# ]] && continue
        [[ -z "${line}" ]] && continue

        # Check metric name
        if [[ "${line}" =~ ^${metric_name}\{ ]]; then
            # Apply label filter if specified
            if [[ -n "${label_filter}" ]]; then
                if [[ "${line}" == *"${label_filter}"* ]]; then
                    # Extract value (last field)
                    echo "${line}" | awk '{print $NF}'
                    return 0
                fi
            else
                echo "${line}" | awk '{print $NF}'
                return 0
            fi
        fi
    done <<< "${output}"
    return 1
}

# Extract all values for a metric (multi-service)
# Usage: prom_metric_values <output> <metric_name>
prom_metric_values() {
    local output="$1"
    local metric_name="$2"

    echo "${output}" | grep "^${metric_name}{" | awk '{print $NF}'
}

# Count how many metric lines exist for a given name
# Usage: prom_metric_count <output> <metric_name>
prom_metric_count() {
    local output="$1"
    local metric_name="$2"
    echo "${output}" | grep -c "^${metric_name}{" 2>/dev/null || echo "0"
}

# Extract label value from a metric line
# Usage: prom_label_value <metric_line> <label_name>
prom_label_value() {
    local line="$1"
    local label_name="$2"
    echo "${line}" | sed -n "s/.*${label_name}=\"\([^\"]*\)\".*/\1/p"
}

# Check if output contains valid Prometheus HELP line
# Usage: assert_prom_help <output> <metric_name>
assert_prom_help() {
    local output="$1"
    local metric_name="$2"
    echo "${output}" | grep -q "^# HELP ${metric_name}" || {
        echo "Missing HELP line for ${metric_name}" >&2
        return 1
    }
}

# Check if output contains valid Prometheus TYPE line
# Usage: assert_prom_type <output> <metric_name> <type>
assert_prom_type() {
    local output="$1"
    local metric_name="$2"
    local type="${3:-gauge}"
    echo "${output}" | grep -q "^# TYPE ${metric_name} ${type}" || {
        echo "Missing or wrong TYPE line for ${metric_name} (expected ${type})" >&2
        return 1
    }
}

# Assert that a metric exists with a specific value
# Usage: assert_metric_equals <output> <metric_name> <expected_value> [label_filter]
assert_metric_equals() {
    local output="$1"
    local metric_name="$2"
    local expected="$3"
    local label_filter="${4:-}"

    local actual
    actual="$(prom_metric_value "${output}" "${metric_name}" "${label_filter}")" || {
        echo "Metric ${metric_name} not found in output" >&2
        echo "Output was:" >&2
        echo "${output}" >&2
        return 1
    }

    if [[ "${actual}" != "${expected}" ]]; then
        echo "Expected ${metric_name}=${expected}, got ${actual}" >&2
        if [[ -n "${label_filter}" ]]; then
            echo "  (label filter: ${label_filter})" >&2
        fi
        return 1
    fi
}

# Assert that a metric does NOT exist in the output
# Usage: refute_metric <output> <metric_name>
refute_metric() {
    local output="$1"
    local metric_name="$2"
    if echo "${output}" | grep -q "^${metric_name}{"; then
        echo "Metric ${metric_name} unexpectedly found in output" >&2
        return 1
    fi
}

# Assert output has valid Prometheus exposition format (basic check)
# Usage: assert_valid_prom_format <output>
assert_valid_prom_format() {
    local output="$1"
    # Should have at least HELP and TYPE lines
    local metric_name
    metric_name="$(echo "${output}" | grep '^# HELP' | head -1 | awk '{print $3}')"
    if [[ -z "${metric_name}" ]]; then
        echo "No HELP line found" >&2
        return 1
    fi
    assert_prom_type "${output}" "${metric_name}" || return 1
    # Should have at least one metric line
    if ! echo "${output}" | grep -q "^${metric_name}{"; then
        echo "No metric lines found for ${metric_name}" >&2
        return 1
    fi
}

# Check if the output body (after HTTP headers) is empty
# Usage: assert_body_empty <http_response>
assert_body_empty() {
    local response="$1"
    local body
    body="$(http_extract_body "${response}")"
    # Body should be empty or contain only whitespace
    local trimmed
    trimmed="$(echo "${body}" | tr -d '[:space:]')"
    if [[ -n "${trimmed}" ]]; then
        echo "Expected empty body, got:" >&2
        echo "${body}" >&2
        return 1
    fi
}
