#!/usr/bin/env bash
#
# test_dashboards.sh - fear #3: dashboards must be importable. The real
# dashboards must validate; an invalid JSON or a renamed ${DS_PROMETHEUS}
# datasource placeholder (which would silently break Grafana import / the
# installer's sed) must be caught.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROM_DIR="$(cd "$SELF_DIR/.." && pwd)"
LIB="$SELF_DIR/lib"
source "$LIB/common.sh"
source "$LIB/checks.sh"

begin_category "test_dashboards"

for j in "$PROM_DIR"/NexentaEdge-Grafana-*.json; do
  [ -f "$j" ] || continue
  if ( check_dashboard_json "$j" ) >/dev/null 2>&1; then
    pass "check_dashboard_json passes on $(basename "$j")"
  else
    fail "check_dashboard_json should pass on $(basename "$j")"
  fi
done

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT

printf '%s\n' '{ this is not, valid json ' > "$ROOT/bad.json"
if ( check_dashboard_json "$ROOT/bad.json" ) >/dev/null 2>&1; then
  fail "check_dashboard_json should FAIL on invalid JSON"
else
  pass "check_dashboard_json catches invalid JSON (would fail Grafana import)"
fi

cp "$PROM_DIR"/NexentaEdge-Grafana-v2.1.3-FP1.json "$ROOT/renamed.json"
sed -i 's/DS_PROMETHEUS/DS_WRONG/g' "$ROOT/renamed.json"
if ( check_dashboard_json "$ROOT/renamed.json" ) >/dev/null 2>&1; then
  fail "check_dashboard_json should FAIL when the \${DS_PROMETHEUS} placeholder is renamed"
else
  pass "check_dashboard_json catches a renamed \${DS_PROMETHEUS} placeholder"
fi

if ( check_dashboards "$PROM_DIR" ) >/dev/null 2>&1; then
  pass "check_dashboards passes on the real config"
else
  fail "check_dashboards should pass on the real config"
fi

finish
exit $?
