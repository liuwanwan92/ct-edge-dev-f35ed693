#!/usr/bin/env bash
#
# test_install_dashboard.sh - the installer's exit-code/error-message contract
# and the anti-silent-breakage guard.
#
#  - static: every literal token the installer rewrites with sed must still
#    exist in the file it rewrites (else the sed silently no-ops); the docker
#    dependency guard must remain.
#  - behavioral: with a dependency missing the installer must print the
#    documented ERROR and exit 1, and must STOP before pulling any container
#    (no network). Run in a mock environment - no real docker/curl/cluster.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROM_DIR="$(cd "$SELF_DIR/.." && pwd)"
LIB="$SELF_DIR/lib"
source "$LIB/common.sh"
source "$LIB/checks.sh"
source "$LIB/mockenv.sh"

INSTALL="$PROM_DIR/install_dashboard.sh"

begin_category "test_install_dashboard"

if ( check_install "$PROM_DIR" ) >/dev/null 2>&1; then
  pass "check_install passes on the real config"
else
  fail "check_install should pass on the real config"
fi

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT

# sed-token guard: prometheus.yml drifts so the installer's sed would no-op.
c1="$ROOT/drift"; copy_monitoring_tree "$PROM_DIR" "$c1"
sed -i 's/172.20.1.20:8881/10.0.0.1:8881/' "$c1/prometheus.yml"
if ( check_install "$c1" ) >/dev/null 2>&1; then
  fail "check_install should FAIL when prometheus.yml drifts from the installer's sed target"
else
  pass "check_install catches prometheus.yml drift that would silently break the installer's sed"
fi

# dependency guard removed from the installer.
c2="$ROOT/noguard"; copy_monitoring_tree "$PROM_DIR" "$c2"
sed -i '/ERROR: Docker not installed/d' "$c2/install_dashboard.sh"
if ( check_install "$c2" ) >/dev/null 2>&1; then
  fail "check_install should FAIL when the docker dependency guard is removed"
else
  pass "check_install catches removal of the docker dependency guard"
fi

# behavioral: docker missing => documented error + exit 1, stops before pulling.
out=$(
  mock_init; trap mock_cleanup EXIT
  mock_which_missing docker
  bash "$INSTALL" 1.2.3.4 "$MOCK_BIN/dash" 2>&1
  echo "RC=$?"
)
assert_contains "$out" "ERROR: Docker not installed" "install: docker missing => documented error message"
assert_contains "$out" "RC=1" "install: docker missing => exit code 1"
assert_not_contains "$out" "Pulling Docker container" "install: docker missing => stops before pulling containers (no network)"

# behavioral: curl missing => documented error + exit 1 (docker present so we reach the curl guard).
out=$(
  mock_init; trap mock_cleanup EXIT
  mock_tool docker 0
  mock_which_missing curl
  bash "$INSTALL" 1.2.3.4 "$MOCK_BIN/dash" 2>&1
  echo "RC=$?"
)
assert_contains "$out" "ERROR: curl not installed" "install: curl missing => documented error message"
assert_contains "$out" "RC=1" "install: curl missing => exit code 1"

finish
exit $?
