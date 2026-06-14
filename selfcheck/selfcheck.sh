#!/usr/bin/env bash
#
# selfcheck/selfcheck.sh -- NexentaEdge deployment / upgrade self-check.
#
# One entry point that runs the same checks across every example config dir,
# produces ONE consistent exit code with locatable diagnostics, and leaves the
# environment exactly as it found it (idempotent).
#
#   ./selfcheck.sh [--target <conf-dir>|all] [--live] [--strict]
#                  [--targets-file <file>] [-h]
#
# Layers:
#   static/mock (always): check-config (per profile), check-monitoring,
#       check-scripts. No docker/root needed -- safe in CI.
#   live (--live, host only): verify-deploy / verify-upgrade / verify-partial
#       run read-only oracles against a reachable cluster.
#
# Exit codes:  0 ok | 1 failure (or strict-promoted skip) | 2 incomplete
#              (skipped deps, tolerated locally) | 3 harness/usage error.

set -u

SC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_ROOT="$(cd "$SC_DIR/.." && pwd)"
CHECKS="$SC_DIR/checks"
# Self-heal the mock exec bit: a Windows commit may drop it, which would break
# bare-name PATH lookup of the probe stubs on a Linux runner.
chmod +x "$SC_DIR"/mocks/* 2>/dev/null || true
# shellcheck source=/dev/null
. "$SC_DIR/lib/common.sh"
# shellcheck source=/dev/null
. "$SC_DIR/lib/discover.sh"
# shellcheck source=/dev/null
. "$SC_DIR/lib/svccheck.sh"

usage() {
	sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

LIVE=0 STRICT=0 TARGET=all TARGETS_FILE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--live) LIVE=1; shift ;;
		--strict) STRICT=1; shift ;;
		--target) TARGET="${2:-}"; shift 2 ;;
		--target=*) TARGET="${1#*=}"; shift ;;
		--targets-file) TARGETS_FILE="${2:-}"; shift 2 ;;
		--targets-file=*) TARGETS_FILE="${1#*=}"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'selfcheck: unknown argument: %s\n\n' "$1" >&2; usage >&2; exit "$EX_USAGE" ;;
	esac
done

cd "$SC_ROOT" || { echo "selfcheck: cannot cd to repo root $SC_ROOT" >&2; exit "$EX_USAGE"; }

# --- resolve target profile directories -------------------------------------
declare -a targets=()
if [ "$TARGET" = all ]; then
	while IFS= read -r p; do targets+=("$SC_ROOT/conf/$p"); done < <(sc_discover_profiles "$SC_ROOT/conf")
	if [ "${#targets[@]}" -eq 0 ]; then
		echo "selfcheck: no profiles (conf/*/nesetup.json) found under $SC_ROOT/conf" >&2
		exit "$EX_USAGE"
	fi
else
	td="$TARGET"; [ -d "$td" ] || td="$SC_ROOT/$TARGET"
	if [ ! -f "$td/nesetup.json" ]; then
		echo "selfcheck: --target '$TARGET' is not a profile dir (no nesetup.json)" >&2
		exit "$EX_USAGE"
	fi
	targets+=("$td")
fi

# --- environment for child checks -------------------------------------------
export SELFCHECK_STRICT="$STRICT"
export SELFCHECK_LIVE="$LIVE"
# NB: SELFCHECK_MOCKS is intentionally NOT exported. check-monitoring/check-scripts
# self-default it for their mock-driven assertions; live verify-* use the REAL
# tools unless a caller (e.g. the bats suite) sets SELFCHECK_MOCKS explicitly.

SELFCHECK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/selfcheck.XXXXXX")"
RESULTS="$SELFCHECK_TMP/results.log"
ERRLOG="$SELFCHECK_TMP/checks.err"
: > "$RESULTS"; : > "$ERRLOG"

# Idempotency: clean the exporters' /tmp caches and our own temp on the way in
# and out, so a repeated run starts and ends from identical state.
cleanup() { svc_cache_clean; rm -rf "$SELFCHECK_TMP" 2>/dev/null || true; }
trap cleanup EXIT
svc_cache_clean

usage_err=0
run_check() {  # <target-label> <check-script> [args...]
	local label="$1"; shift
	SELFCHECK_TARGET="$label" bash "$@" 2>>"$ERRLOG" | tee -a "$RESULTS"
	local rc=${PIPESTATUS[0]}
	case "$rc" in
		0|1|2) : ;;
		"$EX_USAGE") usage_err=1
			printf 'selfcheck: %s reported a usage/IO error (exit 3); see %s\n' "$(basename "$2")" "$ERRLOG" >&2 ;;
		*) usage_err=1
			printf 'FAIL id=harness.crash at=selfcheck:0 target=%s :: %s crashed (exit %s)\n' "$label" "$(basename "$2")" "$rc" >> "$RESULTS"
			printf 'selfcheck: %s crashed (exit %s); see %s\n' "$(basename "$2")" "$rc" "$ERRLOG" >&2 ;;
	esac
}

printf '== NexentaEdge self-check (strict=%s live=%s) ==\n' \
	"$([ "$STRICT" = 1 ] && echo on || echo off)" "$([ "$LIVE" = 1 ] && echo on || echo off)"

# --- per-profile checks ------------------------------------------------------
for t in "${targets[@]}"; do
	label="$(basename "$t")"
	run_check "$label" "$CHECKS/check-config" --target "$t"
	if [ "$LIVE" = 1 ]; then
		run_check "$label" "$CHECKS/verify-deploy"  --target "$t"
		run_check "$label" "$CHECKS/verify-upgrade" --target "$t"
		run_check "$label" "$CHECKS/verify-partial" --target "$t"
	fi
done

# --- global checks (run once) ------------------------------------------------
mon_args=(); [ -n "$TARGETS_FILE" ] && mon_args+=(--targets-file "$TARGETS_FILE")
run_check global "$CHECKS/check-monitoring" "${mon_args[@]}"
run_check global "$CHECKS/check-scripts"

# --- summary + single exit code ---------------------------------------------
np=$(grep -c '^PASS'      "$RESULTS" 2>/dev/null); np=${np:-0}
nf=$(grep -c '^FAIL'      "$RESULTS" 2>/dev/null); nf=${nf:-0}
nna=$(grep -c '^SKIP_NA'  "$RESULTS" 2>/dev/null); nna=${nna:-0}
ndep=$(grep -c '^SKIP_DEP' "$RESULTS" 2>/dev/null); ndep=${ndep:-0}
nnote=$(grep -c '^NOTE'   "$RESULTS" 2>/dev/null); nnote=${nnote:-0}

if [ "$usage_err" = 1 ]; then
	code="$EX_USAGE"
else
	code="$(sc_aggregate_file "$RESULTS")"
fi

echo
echo "---- summary ----"
if [ "$nf" -gt 0 ]; then
	echo "Failures:"; grep '^FAIL' "$RESULTS" | sed 's/^/  /'
fi
if [ "$ndep" -gt 0 ] && [ "$STRICT" != 1 ]; then
	echo "Skipped (missing deps/env; --strict would fail these):"; grep '^SKIP_DEP' "$RESULTS" | sed 's/^/  /'
fi
printf 'PASS=%s FAIL=%s SKIP_NA=%s SKIP_DEP=%s NOTE=%s\n' "$np" "$nf" "$nna" "$ndep" "$nnote"
case "$code" in
	0) verdict="OK — all applicable checks passed" ;;
	2) verdict="INCOMPLETE — checks skipped for missing deps/env (tolerated; use --strict in CI to fail)" ;;
	1) verdict="FAILED — see failures above" ;;
	*) verdict="HARNESS ERROR — a check could not run (exit 3)" ;;
esac
printf 'RESULT: %s  (exit %s)\n' "$verdict" "$code"

exit "$code"
