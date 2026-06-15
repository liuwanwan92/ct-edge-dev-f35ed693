#!/usr/bin/env bash
# Usage: inject-state.sh <sandbox_tmp> <service> <fixture_name>
# Copies a fixture file into the sandbox as the service's cache file
SANDBOX_TMP="$1"
SERVICE="$2"
FIXTURE="$3"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "${SCRIPT_DIR}/sample-cache/${FIXTURE}" "${SANDBOX_TMP}/nedge-prom-${SERVICE}-check.last"
echo "Injected ${FIXTURE} as ${SERVICE} cache in ${SANDBOX_TMP}"
