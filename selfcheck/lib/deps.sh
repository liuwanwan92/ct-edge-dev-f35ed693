#!/usr/bin/env bash
#
# selfcheck/lib/deps.sh
#
# Dependency detection. The JSON backend is resolved by ACTUALLY RUNNING a
# candidate interpreter, not merely by `command -v` -- on some systems a
# `python3` shim exists on PATH but fails when executed (e.g. the Windows
# Store stub), so a presence check alone is not enough.
#
# Resolution order (honors the approved "jq -> python3 -> skip" policy):
#   jq  ->  a python that can `import json`  ->  none
# A backend of "none" must make JSON-dependent checks emit SKIP_DEP (never a
# silent pass).

if [ -n "${_SC_DEPS_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_SC_DEPS_LOADED=1

sc_have() { command -v "$1" >/dev/null 2>&1; }

# sc_json_backend -> echoes one of: "jq" | "py:<interpreter>" | "none"
# Result is memoized in _SC_JSON_BACKEND for the life of the process.
sc_json_backend() {
	# Test hook: SELFCHECK_FORCE_JSON_BACKEND overrides detection (e.g. "none").
	[ -n "${SELFCHECK_FORCE_JSON_BACKEND:-}" ] && { echo "$SELFCHECK_FORCE_JSON_BACKEND"; return 0; }
	if [ -n "${_SC_JSON_BACKEND:-}" ]; then echo "$_SC_JSON_BACKEND"; return 0; fi
	local b=none p
	if sc_have jq; then
		b=jq
	else
		for p in python3 python; do
			if sc_have "$p" && "$p" -c 'import json,sys' >/dev/null 2>&1; then
				b="py:$p"; break
			fi
		done
	fi
	_SC_JSON_BACKEND="$b"
	echo "$b"
}

# sc_pybin -> echoes the working python interpreter, or empty if none.
sc_pybin() {
	local b; b=$(sc_json_backend)
	case "$b" in py:*) echo "${b#py:}" ;; *) echo "" ;; esac
}
