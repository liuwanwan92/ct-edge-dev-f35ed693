#!/usr/bin/env bash
# trace.bash - Structured execution tracing
#
# Every mock call and significant event is logged with:
#   TIMESTAMP LEVEL COMPONENT #SEQNUM EVENT DETAILS
#
# Format is human-readable + grep/awk-friendly.

_TRACE_SEQ=0
_TRACE_ACTIVE=""

# Initialize tracing for the current test
trace_init() {
    _TRACE_SEQ=0
    _TRACE_ACTIVE=1
    if [[ -n "${SANDBOX_TRACE:-}" ]]; then
        export NEDGE_TRACE_FILE="${SANDBOX_TRACE}"
        : > "${NEDGE_TRACE_FILE}"
    fi
}

# Log a trace event
# Usage: trace_event LEVEL COMPONENT EVENT [DETAILS...]
trace_event() {
    local level="${1:-INFO}"
    local component="${2:-TEST}"
    local event="${3:-EVENT}"
    shift 3 2>/dev/null || true
    local details="$*"

    _TRACE_SEQ=$((_TRACE_SEQ + 1))
    local ts
    ts="$(date +%s.%N 2>/dev/null || date +%s)"
    local seq
    seq="$(printf '%05d' ${_TRACE_SEQ})"

    local line="${ts} ${level} ${component} #${seq} ${event} ${details}"

    if [[ -n "${NEDGE_TRACE_FILE:-}" ]]; then
        echo "${line}" >> "${NEDGE_TRACE_FILE}"
    fi
}

# Convenience: log an INFO event
trace_info() {
    trace_event "INFO" "$@"
}

# Convenience: log a DEBUG event
trace_debug() {
    trace_event "DEBUG" "$@"
}

# Convenience: log a WARN event
trace_warn() {
    trace_event "WARN" "$@"
}

# Convenience: log an ERROR event
trace_error() {
    trace_event "ERROR" "$@"
}

# Log mock invocation (called from mock shims)
# Usage: trace_mock CMD_NAME ARGS...
trace_mock() {
    local cmd="$1"; shift
    trace_event "MOCK" "MOCK" "${cmd}" "ARGS=[$*]"
}

# Log check execution start
# Usage: trace_check_start SERVICE RUN_NUM
trace_check_start() {
    local service="$1" run="${2:-1}"
    trace_event "INFO" "CHECK" "START" "service=${service} run=${run}"
}

# Log check execution end
# Usage: trace_check_end SERVICE RUN_NUM RESULT
trace_check_end() {
    local service="$1" run="${2:-1}" result="${3:-unknown}"
    trace_event "INFO" "CHECK" "END" "service=${service} run=${run} result=${result}"
}

# Log cache state before/after a check
# Usage: trace_cache_state PRE|POST SERVICE FILE SIZE
trace_cache_state() {
    local phase="$1" service="$2" file="$3" size="${4:-0}"
    trace_event "DEBUG" "CACHE" "${phase}_STATE" \
        "service=${service} file=${file} size=${size}"
}

# Dump the entire trace log to a file descriptor or stdout
# Usage: trace_dump [FD]
trace_dump() {
    local fd="${1:-1}"
    if [[ -n "${NEDGE_TRACE_FILE:-}" && -f "${NEDGE_TRACE_FILE}" ]]; then
        cat "${NEDGE_TRACE_FILE}" >&${fd}
    fi
}

# Get the trace log content as a string
trace_get_log() {
    if [[ -n "${NEDGE_TRACE_FILE:-}" && -f "${NEDGE_TRACE_FILE}" ]]; then
        cat "${NEDGE_TRACE_FILE}"
    fi
}

# Count events matching a pattern in the trace log
# Usage: trace_count PATTERN
trace_count() {
    local pattern="$1"
    if [[ -n "${NEDGE_TRACE_FILE:-}" && -f "${NEDGE_TRACE_FILE}" ]]; then
        grep -c "${pattern}" "${NEDGE_TRACE_FILE}" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Check if any events match a pattern
# Usage: trace_has PATTERN
trace_has() {
    local pattern="$1"
    [[ "$(trace_count "${pattern}")" -gt 0 ]]
}

# Extract all events matching a pattern
# Usage: trace_find PATTERN
trace_find() {
    local pattern="$1"
    if [[ -n "${NEDGE_TRACE_FILE:-}" && -f "${NEDGE_TRACE_FILE}" ]]; then
        grep "${pattern}" "${NEDGE_TRACE_FILE}" 2>/dev/null || true
    fi
}

# Get the sequence of mock calls (command names only)
trace_mock_sequence() {
    trace_find "MOCK MOCK" | awk '{print $5}'
}

# Print a summary of the trace
trace_summary() {
    if [[ -z "${NEDGE_TRACE_FILE:-}" || ! -f "${NEDGE_TRACE_FILE}" ]]; then
        echo "(no trace)"
        return
    fi
    echo "=== Trace Summary ==="
    echo "Total events: $(wc -l < "${NEDGE_TRACE_FILE}")"
    echo "Mock calls:   $(trace_count 'MOCK MOCK')"
    echo "Check starts: $(trace_count 'START')"
    echo "Check ends:   $(trace_count 'END')"
    echo "Warnings:     $(trace_count 'WARN')"
    echo "Errors:       $(trace_count 'ERROR')"
    echo "===================="
}
