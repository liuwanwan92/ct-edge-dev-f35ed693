#!/usr/bin/env bash
# run.sh - entrypoint for the NexentaEdge svc-check regression/diagnostic suite.
#
#   ./run.sh                 # run the whole suite
#   ./run.sh nfs_states      # run one suite by name (with or without .bats)
#   ./run.sh bats/foo.bats   # or by path
#
# It verifies bats-core is installed, runs every suite against a single shared
# work dir so all evidence lands in one inspectable place, and prints where to
# find it. Exit status is bats' status (0 = all green).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$TEST_DIR"

if ! command -v bats >/dev/null 2>&1; then
	cat >&2 <<'EOF'
ERROR: bats-core is required but was not found on PATH.

Install it one of these ways:
  - Debian/Ubuntu : sudo apt-get install -y bats
  - RHEL/CentOS   : sudo yum install -y bats        (or: dnf install bats)
  - macOS         : brew install bats-core
  - from source   : git clone https://github.com/bats-core/bats-core
                    cd bats-core && sudo ./install.sh /usr/local

Then re-run:  ./run.sh
EOF
	exit 127
fi

# Pick the suites to run: all of bats/*.bats (guard first for fail-fast), or the
# specific ones named on the command line.
declare -a SUITES
if [ "$#" -gt 0 ]; then
	for a in "$@"; do
		case "$a" in
			*/*.bats) SUITES+=("$a") ;;
			*.bats)   SUITES+=("bats/$a") ;;
			*)        SUITES+=("bats/$a.bats") ;;
		esac
	done
else
	SUITES=(
		bats/guard_instrumentation.bats
		bats/nfs_states.bats
		bats/iscsi_states.bats
		bats/s3_states.bats
		bats/install_scenario.bats
		bats/upgrade_scenario.bats
		bats/cache_race.bats
		bats/isolation.bats
		bats/evidence.bats
	)
fi

# One shared work dir for the whole run; load.bash/harness_setup honor this, so
# every scenario/node/run writes its evidence under here.
ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
HARNESS_WORK="$TEST_DIR/.work/run-$ts"
mkdir -p "$HARNESS_WORK"
export HARNESS_WORK

echo "== svc-check regression suite =="
echo "bats:     $(bats --version 2>&1 | head -1)"
echo "work dir: $HARNESS_WORK"
echo "suites:   ${#SUITES[@]}"
echo

rc=0
bats "${SUITES[@]}" || rc=$?

echo
if [ "$rc" -eq 0 ]; then
	echo "RESULT: all suites green."
else
	echo "RESULT: failures (bats exit $rc)."
fi
cat <<EOF

Evidence (per scenario/node, NDJSON + per-scrape stdout/stderr) is under:
  $HARNESS_WORK/<scenario>/<node>/evidence/

  events.ndjson        one JSON object per scrape: scenario,node,run,step,svc,
                       http_status,metric_value,metric_lines,verdict
  <run>.<step>.<svc>.metrics   the HTTP body that scrape returned
  <run>.<step>.<svc>.trace     the check's own recv/send/redirect trace
EOF

exit "$rc"
