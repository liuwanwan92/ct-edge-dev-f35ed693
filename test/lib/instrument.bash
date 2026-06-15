#!/usr/bin/env bash
# instrument.bash - produce a test copy of a production svc-check whose ONLY
# difference from the original is the hardcoded cache path:
#
#   /tmp/nedge-prom-<svc>-check.last
#       -> ${NEDGE_CHECK_STATE_DIR:?...}/nedge-prom-<svc>-check.last
#
# This is how the harness isolates the otherwise-shared cache per
# scenario/node/run WITHOUT editing production logic. assert_only_cache_path_changed
# is used by guard_instrumentation.bats to fail loudly if the production script
# drifts or the transform changes anything else.

set -u

_INSTRUMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$_INSTRUMENT_DIR/../.." && pwd)}"

# Path to the unmodified production check for a service (nfs|iscsi|s3).
prod_check_path() {
	printf '%s/prometheus/svc-checks/nedge-prom-%s-check' "$REPO_ROOT" "$1"
}

# instrument_check <svc> <dst>   (reads production check, writes instrumented copy)
instrument_check() {
	local svc="$1" dst="$2"
	local src; src="$(prod_check_path "$svc")"
	[ -f "$src" ] || { echo "instrument_check: production check not found: $src" >&2; return 1; }
	# Strip CR (the file may be CRLF on a Windows checkout) so the copy is
	# guaranteed LF and runs cleanly under bash, then redirect the cache path.
	sed -E 's/\r$//; s#/tmp/(nedge-prom-[a-z0-9]+-check\.last)#${NEDGE_CHECK_STATE_DIR:?NEDGE_CHECK_STATE_DIR must be set by test harness}/\1#' \
		"$src" > "$dst"
	chmod +x "$dst"
}

# assert_only_cache_path_changed <src> <dst> -> 0 if the sole change is the cache path
assert_only_cache_path_changed() {
	local src="$1" dst="$2"
	grep -Eq '/tmp/nedge-prom-[a-z0-9]+-check\.last' "$src" \
		|| { echo "FAIL: production script has no hardcoded /tmp cache path: $src"; return 1; }
	if grep -Eq '/tmp/nedge-prom-[a-z0-9]+-check\.last' "$dst"; then
		echo "FAIL: instrumented copy still contains the hardcoded /tmp cache path"; return 1
	fi
	grep -q 'NEDGE_CHECK_STATE_DIR' "$dst" \
		|| { echo "FAIL: instrumented copy is missing NEDGE_CHECK_STATE_DIR"; return 1; }
	# Any changed content line that is NOT the cache line means drift.
	# Compare CR-insensitively: the copy is LF while the checkout may be CRLF,
	# and that normalization is intentional, not drift.
	local bad
	bad="$(diff <(tr -d '\r' < "$src") <(tr -d '\r' < "$dst") | grep -E '^[<>] ' | grep -vE 'nedge-prom-[a-z0-9]+-check\.last' || true)"
	if [ -n "$bad" ]; then
		echo "FAIL: instrumentation changed lines other than the cache path:"
		printf '%s\n' "$bad"
		return 1
	fi
	return 0
}
