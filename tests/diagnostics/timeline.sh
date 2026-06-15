#!/usr/bin/env bash
# timeline.sh - Generate ASCII timeline from trace logs
#
# Parses a trace log file and produces a visual timeline showing:
#   - When each check was invoked
#   - Pre/post cache state
#   - Mock command invocations
#   - State transitions and anomalies
#
# Usage: ./timeline.sh <trace-file>

set -euo pipefail

TRACE_FILE="${1:-}"

if [[ -z "${TRACE_FILE}" || ! -f "${TRACE_FILE}" ]]; then
    echo "Usage: $0 <trace-file>" >&2
    echo "  Run state-trace.sh first to generate a trace file." >&2
    exit 1
fi

echo "================================================================"
echo " Timeline: ${TRACE_FILE}"
echo "================================================================"
echo ""

# Header
printf "%-18s %-6s %-10s %-12s %-30s\n" \
    "TIMESTAMP" "LEVEL" "COMPONENT" "EVENT" "DETAILS"
printf "%-18s %-6s %-10s %-12s %-30s\n" \
    "------------------" "------" "----------" "------------" "------------------------------"

# Parse each line
while IFS= read -r line; do
    # Extract fields: TIMESTAMP LEVEL COMPONENT #SEQNUM EVENT DETAILS
    ts="$(echo "${line}" | awk '{print $1}')"
    level="$(echo "${line}" | awk '{print $2}')"
    component="$(echo "${line}" | awk '{print $3}')"
    event="$(echo "${line}" | awk '{print $5}')"
    details="$(echo "${line}" | cut -d' ' -f6-)"

    # Color-code by level
    marker=""
    case "${level}" in
        INFO)  marker="  " ;;
        DEBUG) marker=". " ;;
        WARN)  marker="! " ;;
        ERROR) marker="X " ;;
        MOCK)  marker="> " ;;
    esac

    # Highlight state transitions
    highlight=""
    case "${event}" in
        START)
            highlight=" ──────────────── CHECK START ────────────────"
            ;;
        END)
            highlight=" ──────────────── CHECK END ─────────────────"
            ;;
        PRE_STATE)
            if echo "${details}" | grep -q "status=MISSING"; then
                marker="? "
            fi
            ;;
        POST_STATE)
            ;;
    esac

    printf "%s%-16s %-6s %-10s %-12s %s%s\n" \
        "${marker}" "${ts}" "${level}" "${component}" "${event}" \
        "${details}" "${highlight}"

done < "${TRACE_FILE}"

echo ""
echo "================================================================"

# Summary section
echo ""
echo "Summary:"
echo "  Total events:    $(wc -l < "${TRACE_FILE}")"
echo "  Check starts:    $(grep -c 'START' "${TRACE_FILE}" || echo 0)"
echo "  Check ends:      $(grep -c 'END' "${TRACE_FILE}" || echo 0)"
echo "  Mock calls:      $(grep -c 'MOCK MOCK' "${TRACE_FILE}" || echo 0)"
echo "  Cache reads:     $(grep -c 'PRE_STATE' "${TRACE_FILE}" || echo 0)"
echo "  Cache writes:    $(grep -c 'POST_STATE' "${TRACE_FILE}" || echo 0)"
echo "  Warnings:        $(grep -c 'WARN' "${TRACE_FILE}" || echo 0)"
echo "  Errors:          $(grep -c 'ERROR' "${TRACE_FILE}" || echo 0)"

# State transition analysis
echo ""
echo "State transitions:"
grep 'POST_STATE' "${TRACE_FILE}" | while IFS= read -r line; do
    svc="$(echo "${line}" | grep -o 'service=[^ ]*' | cut -d= -f2)"
    size="$(echo "${line}" | grep -o 'size=[^ ]*' | cut -d= -f2)"
    ts="$(echo "${line}" | awk '{print $1}')"
    echo "  ${ts}  ${svc}: cache size = ${size} bytes"
done
