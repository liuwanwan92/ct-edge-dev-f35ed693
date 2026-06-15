#!/usr/bin/env bash
# _fakelib.bash - shared logic for the fake external commands used by the
# svc-check regression harness. Each fake shim (df, showmount, mount, ...) sets
# FAKE_CMD then sources this file and calls fake_dispatch.
#
# Behaviour for the Nth invocation of a command is read from a per-command
# "plan" file. This lets a single test drive a command differently on
# consecutive calls (call #1 hangs, call #2 succeeds, ...) which is exactly how
# we reproduce the "first scrape fails, second recovers" transitional states.
#
# Plan file: $FAKE_STATE_DIR/plan.<cmd>.<key>
#   - one directive line per call; line N is used on call N; if there are fewer
#     lines than N, the last line repeats (steady state).
#   - directive tokens (space separated):
#       rc=<int>      exit code (default 0)
#       echo=<token>  print a single whitespace-free token to stdout
#       cat=<path>    cat a file to stdout (relative to $FAKE_STATE_DIR unless absolute)
#       block=<name>  park on FIFO $FAKE_STATE_DIR/fifo/<name> until the harness
#                     releases it (used for timeout branches and the cache race)
#   - <key> lets one command keep independent plans/counters for different call
#     sites (curl uses object/bucket/plain); most commands pass key "_".
#
# Diagnosability: every call is appended to $FAKE_STATE_DIR/log/<cmd>.log with
# its call number, key and argv, so evidence can show exactly what each check
# invoked and in what order.

set -u

_fake_lock() {   # $1 = lock name; atomic via mkdir
	local l="$FAKE_STATE_DIR/.lock.$1"
	local tries=0
	until mkdir "$l" 2>/dev/null; do
		tries=$((tries + 1))
		# contention is brief (one background export at a time); bail out
		# loudly rather than hang forever if a lock is somehow stuck.
		if [ "$tries" -gt 100000 ]; then
			echo "fakelib: stuck lock $1" >&2
			return 1
		fi
	done
}

_fake_unlock() { rmdir "$FAKE_STATE_DIR/.lock.$1" 2>/dev/null || true; }

_fake_next_call() {   # $1 cmd, $2 key -> prints the (1-based) call number
	local cnt="$FAKE_STATE_DIR/cnt.$1.$2" n
	_fake_lock "$1.$2"
	if [ -f "$cnt" ]; then n=$(cat "$cnt"); else n=0; fi
	n=$((n + 1))
	printf '%s' "$n" > "$cnt"
	_fake_unlock "$1.$2"
	printf '%s' "$n"
}

_fake_plan_line() {   # $1 cmd, $2 key, $3 n -> prints the directive for call n
	local plan="$FAKE_STATE_DIR/plan.$1.$2"
	[ -f "$plan" ] || return 0
	local -a lines=()
	local ln
	while IFS= read -r ln || [ -n "$ln" ]; do lines+=("$ln"); done < "$plan"
	local total=${#lines[@]}
	[ "$total" -eq 0 ] && return 0
	local idx=$(( $3 - 1 ))
	[ "$idx" -ge "$total" ] && idx=$((total - 1))
	printf '%s' "${lines[$idx]}"
}

fake_dispatch() {     # $1 = selector key (default "_"); remaining args = real argv
	local key="${1:-_}"
	[ $# -gt 0 ] && shift
	local cmd="$FAKE_CMD"
	: "${FAKE_STATE_DIR:?FAKE_STATE_DIR must be set by the harness}"

	local n; n="$(_fake_next_call "$cmd" "$key")"

	mkdir -p "$FAKE_STATE_DIR/log"
	printf '%s call=%s key=%s argv=[%s]\n' \
		"$(date +%s 2>/dev/null || echo 0)" "$n" "$key" "$*" \
		>> "$FAKE_STATE_DIR/log/$cmd.log"

	local line; line="$(_fake_plan_line "$cmd" "$key" "$n")"

	local rc=0 out_cat="" out_echo="" blk="" tok
	for tok in $line; do
		case "$tok" in
			rc=*)    rc="${tok#rc=}" ;;
			cat=*)   out_cat="${tok#cat=}" ;;
			echo=*)  out_echo="${tok#echo=}" ;;
			block=*) blk="${tok#block=}" ;;
		esac
	done

	if [ -n "$blk" ]; then
		mkdir -p "$FAKE_STATE_DIR/entered" "$FAKE_STATE_DIR/fifo"
		local fifo="$FAKE_STATE_DIR/fifo/$blk"
		[ -p "$fifo" ] || mkfifo "$fifo"
		# Mark that we reached the blocking point. At this instant the caller's
		# `( ... ) > $tmpfile` has already truncated the cache file but not yet
		# written a value, so the harness can now observe a half-written read.
		: > "$FAKE_STATE_DIR/entered/$cmd"
		# Park with no CPU spin until the harness opens the write end.
		read -r _ < "$fifo" || true
	fi

	if [ -n "$out_cat" ]; then
		local p="$out_cat"
		case "$p" in /*) : ;; *) p="$FAKE_STATE_DIR/$p" ;; esac
		[ -f "$p" ] && cat "$p"
	elif [ -n "$out_echo" ]; then
		printf '%s\n' "$out_echo"
	fi

	exit "$rc"
}
