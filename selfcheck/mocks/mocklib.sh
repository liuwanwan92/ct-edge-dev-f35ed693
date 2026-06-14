#!/usr/bin/env bash
# selfcheck/mocks/mocklib.sh -- shared helpers for the mock commands.
# Each mock sources this, records its invocation (for assertions), then decides
# output from MOCK_* environment variables. Default (unset) = healthy service.
mock_log() {
	[ -n "${SELFCHECK_TMP:-}" ] || return 0
	printf '%s %s\n' "${0##*/}" "$*" >> "$SELFCHECK_TMP/mock-calls.log" 2>/dev/null || true
}
