#!/usr/bin/env bash
# harness.bash - regression/diagnostic harness for the NexentaEdge svc-checks.
#
# It exercises the REAL check scripts the same way socat does (feeding a
# `GET /metrics` request on stdin), but with the external commands shadowed by
# the fakes in lib/fakes so every transitional state can be reproduced
# deterministically. The hardcoded /tmp cache is redirected per (scenario,node)
# via instrument.bash, which is the isolation boundary between the post-install
# and post-upgrade scenarios.
#
# Public API (used by fixtures and bats tests):
#   harness_setup
#   sandbox_init <scenario> <node>      # fresh per-node sandbox; sets SB_* globals
#   fake_set <cmd> <key> <directive...> # set behaviour for the current step
#   fake_blob <name> <<<'...'           # provide canned multi-line output
#   fake_release <gate>                 # unblock a parked fake (after wait_for_file)
#   fake_clear_entered <cmd>            # forget a previous "entered" marker
#   wait_for_file <path> [timeout_s]
#   wait_for_nonempty <path> [timeout_s]
#   run_scrape <step-label> <svc>       # one /metrics scrape; echoes the value;
#                                       # appends an evidence event. Value is one
#                                       # of a number, MISSING, or PARTIAL.
#   last_cache_file <svc>               # path to that node's .last for a svc
#
# Isolation model: state/ (the .last cache) and fakestate/ (plans, counters,
# fifos, call logs) are shared across a node's consecutive scrapes - that shared
# cache is precisely what makes the previous run bias the next. They are NOT
# shared across nodes or scenarios.

set -u

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HARNESS_DIR/instrument.bash"

FAKES_SRC="$HARNESS_DIR/fakes"
FAKE_CMDS=(mount showmount df rpcinfo sleep iscsi-ls curl hostname)
SVCS=(nfs iscsi s3)

# strip CR so anything we execute is LF regardless of the checkout's settings
_normalize() { sed 's/\r$//' "$1" > "$2"; }

harness_setup() {
	HARNESS_WORK="${HARNESS_WORK:-$(mktemp -d)}"
	mkdir -p "$HARNESS_WORK"
}

_stage_fakebin() {   # $1 = sandbox dir
	local sb="$1" c
	mkdir -p "$sb/fakebin"
	for c in "${FAKE_CMDS[@]}"; do
		_normalize "$FAKES_SRC/$c" "$sb/fakebin/$c"
		chmod +x "$sb/fakebin/$c"
	done
	# the shared library the shims source (kept out of PATH name collisions)
	_normalize "$FAKES_SRC/_fakelib.bash" "$sb/_fakelib.bash"
}

sandbox_init() {     # $1 scenario, $2 node
	: "${HARNESS_WORK:?call harness_setup first}"
	SB_SCENARIO="$1"
	SB_NODE="$2"
	SB_HOST="${1}-${2}"
	SB_DIR="$HARNESS_WORK/$SB_SCENARIO/$SB_NODE"
	SB_STATE="$SB_DIR/state"
	SB_FAKESTATE="$SB_DIR/fakestate"
	SB_EVID="$SB_DIR/evidence"
	SB_SCRAPE_N=0

	rm -rf "$SB_DIR"
	mkdir -p "$SB_STATE" "$SB_FAKESTATE" "$SB_EVID" "$SB_DIR/checks"
	_stage_fakebin "$SB_DIR"
	FAKE_LIB="$SB_DIR/_fakelib.bash"

	local svc
	for svc in "${SVCS[@]}"; do
		instrument_check "$svc" "$SB_DIR/checks/nedge-prom-$svc-check"
	done
	: > "$SB_EVID/events.ndjson"
}

last_cache_file() { printf '%s/nedge-prom-%s-check.last' "$SB_STATE" "$1"; }

# ---- plan / fake control (operate on the current sandbox) -------------------

fake_set() {         # <cmd> <key> <directive...>  (single-line plan for this step)
	local cmd="$1" key="$2"; shift 2
	printf '%s\n' "$*" > "$SB_FAKESTATE/plan.$cmd.$key"
}

fake_blob() {        # <name> ; content on stdin
	mkdir -p "$SB_FAKESTATE/blob"
	cat > "$SB_FAKESTATE/blob/$1"
}

fake_clear_entered() { rm -f "$SB_FAKESTATE/entered/$1" 2>/dev/null || true; }

fake_release() {     # <gate> ; unblock a fake parked on this gate
	local fifo="$SB_FAKESTATE/fifo/$1"
	mkdir -p "$SB_FAKESTATE/fifo"
	[ -p "$fifo" ] || mkfifo "$fifo"
	# reader is already parked (caller waited on entered/<cmd>), so this returns
	echo go > "$fifo"
}

fake_reset_plans() { rm -f "$SB_FAKESTATE"/plan.* "$SB_FAKESTATE"/cnt.* 2>/dev/null || true; }

# ---- synchronization (real sleeps; harness PATH is not shadowed) ------------

wait_for_file() {    # <path> [timeout_s]
	local p="$1" iters=$(( ${2:-5} * 50 )) i
	for (( i=0; i<iters; i++ )); do
		[ -e "$p" ] && return 0
		sleep 0.02
	done
	return 1
}

wait_for_nonempty() {  # <path> [timeout_s]
	local p="$1" iters=$(( ${2:-5} * 50 )) i
	for (( i=0; i<iters; i++ )); do
		[ -s "$p" ] && return 0
		sleep 0.02
	done
	return 1
}

# ---- the scrape -------------------------------------------------------------

run_scrape() {       # <step-label> <svc> -> echoes value (number|MISSING|PARTIAL)
	local step="$1" svc="$2"
	SB_SCRAPE_N=$(( SB_SCRAPE_N + 1 ))
	local run="$SB_SCRAPE_N"
	local check="$SB_DIR/checks/nedge-prom-$svc-check"
	local lastf; lastf="$(last_cache_file "$svc")"
	local out="$SB_EVID/${run}.${step}.${svc}.metrics"
	local trace="$SB_EVID/${run}.${step}.${svc}.trace"

	local before; before=$( [ -f "$lastf" ] && echo yes || echo no )

	# Capture stdout to a FILE (never a pipe): the orphaned background export
	# keeps the fd open, and a pipe would make us block until it finishes -
	# defeating the whole point of the async cache.
	(
		export PATH="$SB_DIR/fakebin:$PATH"
		export NEDGE_CHECK_STATE_DIR="$SB_STATE"
		export FAKE_STATE_DIR="$SB_FAKESTATE"
		export FAKE_LIB="$FAKE_LIB"
		export FAKE_HOSTNAME="$SB_HOST"
		bash "$check"
	) > "$out" 2> "$trace" < <(printf 'GET /metrics HTTP/1.0\r\n\r\n')

	# parse the metric value (take the last matching line; nfs has 2 instances
	# which behave identically under a single-line plan)
	local metric_re="nedge_${svc}_service_status\{"
	local line value verdict
	line="$(grep -E "$metric_re" "$out" | tail -1 | tr -d '\r')"
	# grep -c already prints 0 (and exits 1) when there are no matches, so a
	# `|| echo 0` fallback would emit a SECOND 0 and corrupt the JSON. Only
	# default when the file is entirely absent (substitution yields empty).
	local nlines; nlines="$(grep -cE "$metric_re" "$out" 2>/dev/null)"; nlines="${nlines:-0}"
	if [ -z "$line" ]; then
		value="MISSING"; verdict="MISSING"
	else
		value="$(printf '%s' "$line" | awk '{print $NF}')"
		if printf '%s' "$value" | grep -qE '^-?[0-9]+$'; then
			verdict="VALUE"
		else
			value="PARTIAL"; verdict="PARTIAL"
		fi
	fi

	local http_status after_bytes
	http_status="$(grep -oE 'HTTP/1\.[01] [0-9]+' "$out" | head -1 | awk '{print $2}')"
	after_bytes=$( [ -f "$lastf" ] && wc -c < "$lastf" | tr -d ' ' || echo 0 )

	printf '{"ts":%s,"scenario":"%s","node":"%s","run":%s,"step":"%s","svc":"%s","http_status":"%s","metric_value":"%s","metric_lines":%s,"last_existed_before":"%s","last_bytes_after":%s,"verdict":"%s"}\n' \
		"$(date +%s 2>/dev/null || echo 0)" \
		"$SB_SCENARIO" "$SB_NODE" "$run" "$step" "$svc" \
		"${http_status:-?}" "$value" "${nlines:-0}" "$before" "$after_bytes" "$verdict" \
		>> "$SB_EVID/events.ndjson"

	printf '%s\n' "$value"
}
