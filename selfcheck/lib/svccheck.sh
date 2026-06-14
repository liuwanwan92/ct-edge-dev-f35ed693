#!/usr/bin/env bash
#
# selfcheck/lib/svccheck.sh
#
# Drives the existing Prometheus exporter scripts
# (prometheus/svc-checks/nedge-prom-{iscsi,nfs,s3}-check) without socat, and
# neutralizes their /tmp cache so results are deterministic and idempotent.
#
# Why a settle-poll: each exporter prints the LAST cached body to stdout and
# refreshes the cache in a BACKGROUND job (serve-stale-then-refresh). So the
# trustworthy value is the one written to the cache file *after* the probe, not
# the first HTTP body. svc_check_status clears the cache, runs the probe, then
# waits for the freshly-written value -- so a service that merely "looks
# started" cannot leak a stale/empty success.
#
# Mocking: if SELFCHECK_MOCKS is set, it is prepended to PATH so the exporter's
# probe tools (iscsi-ls / showmount / curl / ...) resolve to the stubs in
# selfcheck/mocks. Unset => the real tools run (live mode).

if [ -n "${_SC_SVCCHECK_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_SC_SVCCHECK_LOADED=1

SVC_SETTLE_TRIES="${SELFCHECK_SETTLE_TRIES:-25}"   # * sleep = max wait
SVC_SETTLE_SLEEP="${SELFCHECK_SETTLE_SLEEP:-0.2}"

# svc_cache_path <script-path> -> the /tmp cache that exporter writes.
svc_cache_path() { echo "/tmp/$(basename "$1").last"; }

# svc_cache_clean -- remove the three exporter caches (cross-run residue that
# lives OUTSIDE our temp dir). Safe to call repeatedly; the harness calls it at
# start and on exit so a run leaves no /tmp footprint.
svc_cache_clean() {
	rm -f /tmp/nedge-prom-iscsi-check.last \
	      /tmp/nedge-prom-nfs-check.last \
	      /tmp/nedge-prom-s3-check.last 2>/dev/null || true
}

_svc_drive() {  # <script> -- run one /metrics request through the exporter
	local script=$1
	printf 'GET /metrics HTTP/1.0\r\n\r\n' \
		| PATH="${SELFCHECK_MOCKS:+$SELFCHECK_MOCKS:}$PATH" bash "$script" 2>/dev/null
}

# svc_check_status <script> <metric> [service]
#   Echoes the integer status from the freshly-refreshed cache and returns 0.
#   Returns 1 (no output) on timeout -> caller should emit skip_dep, never a
#   fabricated success. If [service] is given, the value is taken from the line
#   labelled service="<service>"; otherwise the first matching metric line.
svc_check_status() {
	local script=$1 metric=$2 service="${3:-}"
	local cache; cache=$(svc_cache_path "$script")
	rm -f "$cache"
	_svc_drive "$script" >/dev/null 2>&1
	local i s1 s2 line val=""
	for (( i=0; i<SVC_SETTLE_TRIES; i++ )); do
		if [ -f "$cache" ] && grep -q "${metric}{" "$cache" 2>/dev/null; then
			s1=$(wc -c < "$cache" 2>/dev/null || echo 0)
			sleep "$SVC_SETTLE_SLEEP"
			s2=$(wc -c < "$cache" 2>/dev/null || echo 0)
			if [ "$s1" = "$s2" ]; then
				if [ -n "$service" ]; then
					line=$(grep "${metric}{" "$cache" | grep "service=\"$service\"" | head -n1)
				else
					line=$(grep "${metric}{" "$cache" | head -n1)
				fi
				val=$(printf '%s\n' "$line" | awk '{print $NF}')
				[ -n "$val" ] && break
			fi
		else
			sleep "$SVC_SETTLE_SLEEP"
		fi
	done
	[ -n "$val" ] || return 1
	printf '%s\n' "$val"
}

# svc_http_once <script> -- a single raw drive, echoing the exporter's stdout
# body verbatim WITHOUT clearing the cache. Used only to demonstrate the
# serve-stale non-idempotency (first call empty, second serves prior result).
svc_http_once() { _svc_drive "$1"; }
