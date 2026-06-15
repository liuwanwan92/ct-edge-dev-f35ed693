#!/usr/bin/env bash
# http.bash - HTTP request simulation for socat-based scripts
#
# The production health check scripts implement a minimal HTTP/1.0 server
# that reads from stdin and writes to stdout. Normally they are invoked
# via socat which handles TCP connections.
#
# IMPORTANT - PIPE HANG WORKAROUND:
# The production scripts use process substitution internally:
#   send_response_ok_exit < <(nfs_last_result)
# Where nfs_last_result does: cat $cache; nfs_prom_export &
# The background nfs_prom_export inherits the pipe fd,
# preventing EOF and causing the `while read` loop in send_response to hang.
#
# To work around this, we:
#   1. Write the HTTP request to a temp file
#   2. Run `cat request_file | patched_script > response_file` in the background
#   3. Poll response_file for data to appear and stabilize
#   4. Kill the background process (stuck on the pipe hang)
#   5. Read and return the response

# Internal: create the patched script and run an HTTP request
# Args: $1 = request_file  $2 = script_path  $3 = response_file
_http_exec() {
    local request_file="$1"
    local script="$2"
    local response_file="$3"

    # Create patched script (same as sandbox_exec)
    local name
    name="$(basename "${script}")"
    local patched="${SANDBOX_BIN}/${name}"
    sed "s|/tmp/nedge-prom-|${SANDBOX_TMP}/nedge-prom-|g" \
        "${script}" > "${patched}"
    # CRITICAL FIX: Run prom_export in FOREGROUND instead of background.
    # The production script uses `*_prom_export &` which causes two bugs:
    #   1. The background process inherits the pipe fd from process
    #      substitution, preventing EOF (the "pipe hang")
    #   2. The background process is orphaned when the script exits,
    #      and may be killed before writing the cache
    # By removing the `&`, prom_export runs synchronously. The cache is
    # fully written before the response body is sent. No pipe hang, no
    # orphan. The response includes the freshly-computed metrics.
    sed -i 's/_prom_export &/_prom_export/' "${patched}"
    chmod +x "${patched}"

    # Run in background: cat request file piped to script
    cat "${request_file}" | "${patched}" > "${response_file}" 2>/dev/null &
    local script_pid=$!

    # Poll for response to complete. With foreground prom_export (no &),
    # the script completes naturally: cache is written, then the response
    # body is sent from cache, then the script exits. No pipe hang.
    # We poll for the response file to stabilize (headers + body written).
    local max_wait=300  # 300 iterations, script may take 10-30s for complex scenarios
    local prev_size=-1
    local stable_count=0
    local i

    for ((i = 0; i < max_wait; i++)); do
        sleep 0.1
        if [[ -f "${response_file}" ]]; then
            local current_size
            current_size=$(wc -c < "${response_file}" 2>/dev/null || echo 0)
            current_size="${current_size//[^0-9]/}"
            if [[ "${current_size}" -eq "${prev_size}" && "${current_size}" -gt 0 ]]; then
                stable_count=$(( stable_count + 1 ))
                if [[ "${stable_count}" -ge 5 ]]; then
                    break
                fi
            else
                stable_count=0
            fi
            prev_size="${current_size}"
        fi
    done

    # Kill if still running (shouldn't be with foreground prom_export, but safety net)
    kill "${script_pid}" 2>/dev/null || true
    wait "${script_pid}" 2>/dev/null || true
}

# Send a GET /metrics request to a health check script
# Usage: http_get_metrics <script_path>
# Returns: full HTTP response (headers + body)
http_get_metrics() {
    local script="$1"
    trace_check_start "$(basename "${script}")" "${_HTTP_RUN_NUM:-1}"

    # Record pre-state
    local svc_name
    svc_name="$(_detect_service_name "${script}")"
    if sandbox_cache_exists "${svc_name}"; then
        trace_cache_state "PRE" "${svc_name}" \
            "nedge-prom-${svc_name}-check.last" \
            "$(sandbox_cache_size "${svc_name}")"
    else
        trace_cache_state "PRE" "${svc_name}" \
            "nedge-prom-${svc_name}-check.last" "MISSING"
    fi

    # Write request to temp file (avoids variable mangling of \r\n)
    local req_file="${SANDBOX_BASE}/http_req.$$"
    local resp_file="${SANDBOX_BASE}/http_resp.$$"
    printf 'GET /metrics HTTP/1.0\r\n\r\n' > "${req_file}"

    # Execute request
    _http_exec "${req_file}" "${script}" "${resp_file}"

    # Read response
    local response=""
    if [[ -f "${resp_file}" ]]; then
        response="$(cat "${resp_file}")"
    fi
    rm -f "${req_file}" "${resp_file}" 2>/dev/null

    # Wait for background cache writes to complete
    _sandbox_wait_background

    # Record post-state
    if sandbox_cache_exists "${svc_name}"; then
        trace_cache_state "POST" "${svc_name}" \
            "nedge-prom-${svc_name}-check.last" \
            "$(sandbox_cache_size "${svc_name}")"
    fi

    local result="EMPTY"
    local body
    body="$(http_extract_body "${response}")"
    if [[ -n "$(echo "${body}" | tr -d '[:space:]')" ]]; then
        result="HAS_DATA"
    fi
    trace_check_end "$(basename "${script}")" "${_HTTP_RUN_NUM:-1}" "${result}"

    echo "${response}"
}

# Send a GET /metrics request and also run synchronously (wait for bg)
# Usage: http_get_metrics_sync <script_path>
http_get_metrics_sync() {
    local script="$1"
    local req_file="${SANDBOX_BASE}/http_req.$$"
    local resp_file="${SANDBOX_BASE}/http_resp.$$"
    printf 'GET /metrics HTTP/1.0\r\n\r\n' > "${req_file}"

    _http_exec "${req_file}" "${script}" "${resp_file}"

    local response=""
    if [[ -f "${resp_file}" ]]; then
        response="$(cat "${resp_file}")"
    fi
    rm -f "${req_file}" "${resp_file}" 2>/dev/null

    _sandbox_wait_background
    echo "${response}"
}

# Send a custom HTTP request
# Usage: http_request <script_path> <method> <uri>
http_request() {
    local script="$1" method="$2" uri="$3"
    local req_file="${SANDBOX_BASE}/http_req.$$"
    local resp_file="${SANDBOX_BASE}/http_resp.$$"
    printf '%s %s HTTP/1.0\r\nHost: localhost\r\n\r\n' \
        "${method}" "${uri}" > "${req_file}"

    _http_exec "${req_file}" "${script}" "${resp_file}"

    local response=""
    if [[ -f "${resp_file}" ]]; then
        response="$(cat "${resp_file}")"
    fi
    rm -f "${req_file}" "${resp_file}" 2>/dev/null
    echo "${response}"
}

# Send a malformed request
# Usage: http_malformed_request <script_path>
http_malformed_request() {
    local script="$1"
    local req_file="${SANDBOX_BASE}/http_req.$$"
    local resp_file="${SANDBOX_BASE}/http_resp.$$"
    printf 'GARBAGE DATA\r\n\r\n' > "${req_file}"

    _http_exec "${req_file}" "${script}" "${resp_file}"

    local response=""
    if [[ -f "${resp_file}" ]]; then
        response="$(cat "${resp_file}")"
    fi
    rm -f "${req_file}" "${resp_file}" 2>/dev/null
    echo "${response}"
}

# Extract HTTP status code from response
# Usage: http_status_code <response>
http_status_code() {
    local response="$1"
    echo "${response}" | head -1 | sed 's/HTTP\/1\.[01] \([0-9]*\).*/\1/'
}

# Check if response has HTTP 200 status
# Usage: assert_http_200 <response>
assert_http_200() {
    local response="$1"
    local code
    code="$(http_status_code "${response}")"
    if [[ "${code}" != "200" ]]; then
        echo "Expected HTTP 200, got ${code}" >&2
        echo "Response:" >&2
        echo "${response}" >&2
        return 1
    fi
}

# Extract body from HTTP response (everything after the blank line)
# Usage: http_extract_body <response>
http_extract_body() {
    local response="$1"
    # HTTP headers end with \r\n followed by a blank line.
    # The production script uses \r\n line endings (send function uses printf '%s\r\n').
    # We strip \r first, then find the blank line separator.
    local cleaned
    cleaned="$(echo "${response}" | tr -d '\r')"
    # Everything after the first blank line is the body
    echo "${cleaned}" | sed -n '/^$/,$ p' | tail -n +2
}

# Extract just the Prometheus metrics from the body (skip HELP/TYPE comments)
# Usage: http_extract_metrics <response>
http_extract_metrics() {
    local response="$1"
    local body
    body="$(http_extract_body "${response}")"
    echo "${body}" | grep -v '^#' | grep -v '^$'
}

# Count metric lines in response (excluding comments and empty lines)
# Usage: http_metric_count <response> <metric_name>
http_metric_count() {
    local response="$1"
    local metric_name="$2"
    local body
    body="$(http_extract_body "${response}")"
    echo "${body}" | grep -c "^${metric_name}{" 2>/dev/null || echo "0"
}

# Run multiple consecutive scrapes and collect all responses
# Usage: http_consecutive_scrapes <script_path> <count>
# Output: one response per line, separated by "---"
http_consecutive_scrapes() {
    local script="$1"
    local count="$2"
    local i

    for ((i = 1; i <= count; i++)); do
        _HTTP_RUN_NUM="${i}" http_get_metrics "${script}"
        echo "---SEPARATOR---"
    done
}

# Detect which service type a script handles (nfs/iscsi/s3)
_detect_service_name() {
    local script="$1"
    local name
    name="$(basename "${script}")"
    case "${name}" in
        *nfs*)    echo "nfs" ;;
        *iscsi*)  echo "iscsi" ;;
        *s3*)     echo "s3" ;;
        *)        echo "unknown" ;;
    esac
}
