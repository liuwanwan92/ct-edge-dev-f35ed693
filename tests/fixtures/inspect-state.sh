#!/usr/bin/env bash
# Usage: inspect-state.sh <sandbox_base>
# Dumps all cache files with their sizes and content
SANDBOX_BASE="$1"
SANDBOX_TMP="${SANDBOX_BASE}/tmp"
echo "=== Sandbox State Inspection ==="
echo "Sandbox: ${SANDBOX_BASE}"
echo "Time: $(date)"
echo ""
echo "--- Cache files in ${SANDBOX_TMP} ---"
for f in "${SANDBOX_TMP}"/nedge-prom-*-check.last; do
    if [[ -f "$f" ]]; then
        echo ""
        echo "File: $(basename "$f")"
        echo "Size: $(wc -c < "$f") bytes"
        echo "Content:"
        cat "$f"
        echo "---"
    fi
done
echo ""
echo "--- Trace log (last 50 lines) ---"
if [[ -f "${SANDBOX_BASE}/trace.log" ]]; then
    tail -50 "${SANDBOX_BASE}/trace.log"
else
    echo "(no trace log)"
fi
echo "=== End Inspection ==="
