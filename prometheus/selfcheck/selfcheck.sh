#!/usr/bin/env bash
#
# selfcheck.sh - self-check entry point for NexentaEdge monitoring config.
#
# Scans the monitoring config (scrape config, service probes, dashboards and
# the dashboard installer) and reports WHICH CATEGORY broke. No real cluster is
# required. Designed to run locally and in CI.
#
# Usage:
#   bash prometheus/selfcheck/selfcheck.sh [--no-deps] [--dir DIR]
#
#   --no-deps   Skip the host probe-dependency check (use on bare CI runners
#               that don't have iscsi-ls/curl/openssl/... installed). Config
#               consistency is still fully validated.
#               Equivalent to env SELFCHECK_SKIP_DEPS=1.
#   --dir DIR   Validate the monitoring config under DIR (default: the
#               prometheus/ dir next to this script).
#   -h|--help   Show this help.
#
# Exit code: 0 if all categories pass, non-zero otherwise. The final line lists
# the failed categories so CI logs show the broken class at a glance.
#
# Typical CI step (config consistency, no host tools needed):
#   bash prometheus/selfcheck/selfcheck.sh --no-deps
# On a target node before/after an upgrade (also verifies host probe deps):
#   bash prometheus/selfcheck/selfcheck.sh
# Regression test suite:
#   bash prometheus/selfcheck/tests/run-tests.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib"
PROM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKIP_DEPS="${SELFCHECK_SKIP_DEPS:-0}"

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-deps) SKIP_DEPS=1 ;;
    --dir) shift; PROM_DIR="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# shellcheck source=lib/common.sh
source "$LIB/common.sh"
# shellcheck source=lib/checks.sh
source "$LIB/checks.sh"

info "monitoring config under test: $PROM_DIR"
[ "$SKIP_DEPS" = "1" ] && info "host dependency check: SKIPPED (--no-deps)"

begin_category "SCRAPE"
check_scrape "$PROM_DIR"
end_category

begin_category "PROBES"
check_probes_contract "$PROM_DIR"
if [ "$SKIP_DEPS" != "1" ]; then
  check_probe_deps "$PROM_DIR"
fi
end_category

begin_category "DASHBOARD"
check_dashboards "$PROM_DIR"
end_category

begin_category "INSTALL"
check_install "$PROM_DIR"
end_category

finish
exit $?
