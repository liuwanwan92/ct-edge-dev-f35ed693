#!/usr/bin/env bash
#
# selfcheck/lib/common.sh
#
# Core of the NexentaEdge self-check harness: the three-state result model
# (PASS / FAIL / SKIP) and the exit-code aggregation that guarantees a
# degraded or incomplete run can NEVER be reported as success.
#
# Result kinds (the label is independent of --strict):
#   PASS      a check was performed and the condition held
#   FAIL      a check was performed and the condition did NOT hold
#   SKIP_NA   the check did not apply here (e.g. a live check while not --live).
#             Never fatal, never promoted by --strict ("disabled" != "expected").
#   SKIP_DEP  the check could not run because a dependency/environment is missing
#             (no jq/python, tool absent, fixture unreadable). Tolerated locally,
#             but PROMOTED to a failure under --strict (it is "expected-but-unrun").
#
# Severity -> exit-code mapping (the whole anti-false-success engine):
#   PASS / SKIP_NA -> sev 0
#   SKIP_DEP       -> sev 1  (sev 2 when SELFCHECK_STRICT=1)
#   FAIL           -> sev 2
# The worst severity seen maps to the process exit code. No branch maps a
# non-PASS result to 0.

# Re-source guard (sourcing twice must be a no-op, not a reset).
if [ -n "${_SC_COMMON_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_SC_COMMON_LOADED=1

# --- Process exit codes (the CI contract) -----------------------------------
EX_OK=0      # all applicable checks passed
EX_FAIL=1    # >=1 FAIL, or (under --strict) >=1 promoted SKIP_DEP
EX_SKIP=2    # no FAIL but >=1 SKIP_DEP -- verification incomplete, tolerated locally
EX_USAGE=3   # the harness itself broke (bad args, missing target dir, crashed check)

# --- Tunables (overridable via environment) ---------------------------------
SELFCHECK_STRICT="${SELFCHECK_STRICT:-0}"   # 1 => promote SKIP_DEP to failure
SELFCHECK_TARGET="${SELFCHECK_TARGET:-global}"  # tag attached to every result line

# --- Per-process accounting -------------------------------------------------
SC_WORST=0
SC_PASS_N=0
SC_FAIL_N=0
SC_SKIP_NA_N=0
SC_SKIP_DEP_N=0

# Reset accounting (used by tests that source this lib repeatedly in one shell).
sc_reset() {
	SC_WORST=0; SC_PASS_N=0; SC_FAIL_N=0; SC_SKIP_NA_N=0; SC_SKIP_DEP_N=0
}

# sc_sev_of <KIND> -> echoes 0|1|2  (the single source of truth for severity)
sc_sev_of() {
	case "$1" in
		PASS|SKIP_NA|NOTE) echo 0 ;;
		SKIP_DEP)     if [ "$SELFCHECK_STRICT" = 1 ]; then echo 2; else echo 1; fi ;;
		FAIL)         echo 2 ;;
		*)            echo 2 ;;  # unknown kind: treat as failure, never as success
	esac
}

_sc_bump() {
	local sev=$1
	[ "$sev" -gt "$SC_WORST" ] && SC_WORST="$sev"
	return 0
}

# _sc_emit <KIND> <id> <loc> <msg> <fix>
# Prints ONE line whose first whitespace token is the KIND, so the same line is
# both human-readable and machine-aggregatable (see sc_aggregate_file).
_sc_emit() {
	local kind=$1 id=$2 loc=$3 msg=$4 fix=$5
	local line="$kind id=$id at=$loc target=$SELFCHECK_TARGET :: $msg"
	[ -n "$fix" ] && line="$line || fix: $fix"
	printf '%s\n' "$line"
	_sc_bump "$(sc_sev_of "$kind")"
	case "$kind" in
		PASS)     SC_PASS_N=$((SC_PASS_N+1)) ;;
		FAIL)     SC_FAIL_N=$((SC_FAIL_N+1)) ;;
		SKIP_NA)  SC_SKIP_NA_N=$((SC_SKIP_NA_N+1)) ;;
		SKIP_DEP) SC_SKIP_DEP_N=$((SC_SKIP_DEP_N+1)) ;;
	esac
	return 0
}

# Public emitters. `loc` is captured from the CALLER's frame so a FAIL points at
# the exact rule that raised it.
pass()     { local _l="${BASH_SOURCE[1]:-?}"; _sc_emit PASS     "$1" "${_l##*/}:${BASH_LINENO[0]:-0}" "$2" ""; }
fail()     { local _l="${BASH_SOURCE[1]:-?}"; _sc_emit FAIL     "$1" "${_l##*/}:${BASH_LINENO[0]:-0}" "$2" "${3:-}"; }
skip_na()  { local _l="${BASH_SOURCE[1]:-?}"; _sc_emit SKIP_NA  "$1" "${_l##*/}:${BASH_LINENO[0]:-0}" "$2" ""; }
skip_dep() { local _l="${BASH_SOURCE[1]:-?}"; _sc_emit SKIP_DEP "$1" "${_l##*/}:${BASH_LINENO[0]:-0}" "$2" "${3:-}"; }
# note: a non-fatal advisory (severity 0, ignored by aggregation). Use for
# pre-existing issues the harness should surface without reddening CI.
note()     { local _l="${BASH_SOURCE[1]:-?}"; _sc_emit NOTE     "$1" "${_l##*/}:${BASH_LINENO[0]:-0}" "$2" ""; }

# sc_exit_code -> echoes the process exit code derived from the worst severity.
sc_exit_code() {
	case "$SC_WORST" in
		0) echo "$EX_OK" ;;
		1) echo "$EX_SKIP" ;;
		*) echo "$EX_FAIL" ;;
	esac
}

# sc_summary -> one-line tally to stderr (kept off stdout so it never pollutes
# the result stream the runner aggregates).
sc_summary() {
	local strict=off
	[ "$SELFCHECK_STRICT" = 1 ] && strict=on
	printf 'SUMMARY pass=%d fail=%d skip_na=%d skip_dep=%d (strict=%s) exit=%d\n' \
		"$SC_PASS_N" "$SC_FAIL_N" "$SC_SKIP_NA_N" "$SC_SKIP_DEP_N" "$strict" "$(sc_exit_code)" >&2
}

# sc_aggregate_file <logfile> -> echoes the overall exit code computed from a
# stream of result lines (the runner's authoritative source of truth). Honors
# the CURRENT SELFCHECK_STRICT, so strict promotion is applied at aggregation
# time regardless of how the child processes ran.
sc_aggregate_file() {
	local f=$1 worst=0 kind sev
	if [ ! -f "$f" ]; then echo "$EX_OK"; return 0; fi
	while IFS= read -r line || [ -n "$line" ]; do
		kind=${line%% *}
		case "$kind" in
			PASS|FAIL|SKIP_NA|SKIP_DEP) ;;
			*) continue ;;
		esac
		sev=$(sc_sev_of "$kind")
		[ "$sev" -gt "$worst" ] && worst="$sev"
	done < "$f"
	case "$worst" in
		0) echo "$EX_OK" ;;
		1) echo "$EX_SKIP" ;;
		*) echo "$EX_FAIL" ;;
	esac
}

# Convenience for standalone check scripts: finish with the derived exit code.
sc_finish() { sc_summary; exit "$(sc_exit_code)"; }
