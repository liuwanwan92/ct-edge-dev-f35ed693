#!/usr/bin/env bash
#
# test_scrape_config.sh - fear #1: the scrape config must not point at a probe
# that does not exist, a renamed metric, or the wrong port. Runs the real
# check against the live config (must pass) and against temp-mutated broken
# copies (must fail), so a future config edit that breaks scraping is caught.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROM_DIR="$(cd "$SELF_DIR/.." && pwd)"
LIB="$SELF_DIR/lib"
source "$LIB/common.sh"
source "$LIB/checks.sh"
source "$LIB/mockenv.sh"

begin_category "test_scrape_config"

if ( check_scrape "$PROM_DIR" ) >/dev/null 2>&1; then
  pass "check_scrape passes on the real config"
else
  fail "check_scrape should pass on the real config"
fi

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT

c1="$ROOT/wrongport"; copy_monitoring_tree "$PROM_DIR" "$c1"
sed -i 's/172.20.1.20:8881/172.20.1.20:9999/' "$c1/prometheus.yml"
if ( check_scrape "$c1" ) >/dev/null 2>&1; then
  fail "check_scrape should FAIL when the nexentaedge target port drifts"
else
  pass "check_scrape catches a wrong nexentaedge target port"
fi

c2="$ROOT/missingprobe"; copy_monitoring_tree "$PROM_DIR" "$c2"
rm -f "$c2/svc-checks/nedge-prom-s3-check"
if ( check_scrape "$c2" ) >/dev/null 2>&1; then
  fail "check_scrape should FAIL when a referenced probe script is missing"
else
  pass "check_scrape catches a missing probe script"
fi

c3="$ROOT/renamedmetric"; copy_monitoring_tree "$PROM_DIR" "$c3"
sed -i 's/nedge_s3_service_status/nedge_s3_renamed/g' "$c3/svc-checks/nedge-prom-s3-check"
if ( check_scrape "$c3" ) >/dev/null 2>&1; then
  fail "check_scrape should FAIL when a probe's metric name drifts"
else
  pass "check_scrape catches a drifted probe metric name"
fi

finish
exit $?
