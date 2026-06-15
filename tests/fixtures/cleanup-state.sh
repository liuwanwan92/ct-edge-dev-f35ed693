#!/usr/bin/env bash
# Usage: cleanup-state.sh <sandbox_tmp>
# Removes all health check cache files from the sandbox
SANDBOX_TMP="$1"
count=0
for f in "${SANDBOX_TMP}"/nedge-prom-*-check.last; do
    if [[ -f "$f" ]]; then
        rm -f "$f"
        count=$((count + 1))
    fi
done
echo "Cleaned ${count} cache file(s) from ${SANDBOX_TMP}"
