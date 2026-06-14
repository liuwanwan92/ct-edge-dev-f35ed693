#!/usr/bin/env bash
#
# selfcheck/lib/json.sh
#
# Backend-agnostic JSON queries. Prefers jq; falls back to the python helper
# (lib/jsonq.py). Both backends implement identical semantics so checks are
# written once and run anywhere. Callers should gate on sc_json_available
# first and emit skip_dep when it is false (never silently pass).
#
# Helper contract (all): rc 0 = true/found, rc 1 = false/absent, rc 2 = error.
# Path is a dot-separated chain of object keys, e.g. ccow.tenant.failure_domain.

if [ -n "${_SC_JSON_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_SC_JSON_LOADED=1

_SC_JSON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_SC_JSON_DIR/common.sh"
# shellcheck source=/dev/null
. "$_SC_JSON_DIR/deps.sh"

sc_json_available() { [ "$(sc_json_backend)" != none ]; }

sc_json_valid() {
	local f=$1 be; be=$(sc_json_backend)
	case "$be" in
		jq)   jq -e . "$f" >/dev/null 2>&1 && return 0 || return 2 ;;
		py:*) "$(sc_pybin)" "$_SC_JSON_DIR/jsonq.py" "$f" valid; return $? ;;
		*)    return 2 ;;
	esac
}

sc_json_get() {
	local f=$1 p=$2 be out; be=$(sc_json_backend)
	case "$be" in
		jq)
			out=$(jq -r --arg p "$p" '
				getpath($p|split(".")) as $v
				| if $v==null then "__SC_ABSENT__"
				  elif ($v|type)=="array" or ($v|type)=="object" then "__SC_CONTAINER__"
				  else ($v|tostring) end' "$f" 2>/dev/null) || return 2
			[ "$out" = "__SC_ABSENT__" ] && return 1
			[ "$out" = "__SC_CONTAINER__" ] && return 1
			printf '%s\n' "$out"; return 0 ;;
		py:*) "$(sc_pybin)" "$_SC_JSON_DIR/jsonq.py" "$f" get "$p"; return $? ;;
		*)    return 2 ;;
	esac
}

sc_json_type() {
	local f=$1 p=$2 be out; be=$(sc_json_backend)
	case "$be" in
		jq)
			out=$(jq -r --arg p "$p" 'getpath($p|split(".")) as $v
				| if $v==null then "absent" else ($v|type) end' "$f" 2>/dev/null) || return 2
			printf '%s\n' "$out"
			[ "$out" = absent ] && return 1 || return 0 ;;
		py:*) "$(sc_pybin)" "$_SC_JSON_DIR/jsonq.py" "$f" type "$p"; return $? ;;
		*)    return 2 ;;
	esac
}

sc_json_arr_len() {
	local f=$1 p=$2 be out; be=$(sc_json_backend)
	case "$be" in
		jq)
			out=$(jq -r --arg p "$p" 'getpath($p|split(".")) as $v
				| if ($v|type)=="array" then ($v|length) else -1 end' "$f" 2>/dev/null) || return 2
			printf '%s\n' "$out"
			[ "$out" = -1 ] && return 1 || return 0 ;;
		py:*) "$(sc_pybin)" "$_SC_JSON_DIR/jsonq.py" "$f" len "$p"; return $? ;;
		*)    return 2 ;;
	esac
}

sc_json_is_int() {
	local f=$1 p=$2 be; be=$(sc_json_backend)
	case "$be" in
		jq)   jq -e --arg p "$p" 'getpath($p|split(".")) as $v
				| ($v|type)=="number" and ($v == ($v|floor))' "$f" >/dev/null 2>&1 \
				&& return 0 || return 1 ;;
		py:*) "$(sc_pybin)" "$_SC_JSON_DIR/jsonq.py" "$f" isint "$p"; return $? ;;
		*)    return 2 ;;
	esac
}

sc_json_nonempty_str() {
	local f=$1 p=$2 be; be=$(sc_json_backend)
	case "$be" in
		jq)   jq -e --arg p "$p" 'getpath($p|split(".")) as $v
				| ($v|type)=="string" and ($v|length)>0' "$f" >/dev/null 2>&1 \
				&& return 0 || return 1 ;;
		py:*) "$(sc_pybin)" "$_SC_JSON_DIR/jsonq.py" "$f" nonemptystr "$p"; return $? ;;
		*)    return 2 ;;
	esac
}

# sc_json_all_have <file> <path> <key...>  -- every array element is an object
# containing all keys (empty array => true; callers guard length separately).
sc_json_all_have() {
	local f=$1 p=$2 be; shift 2; be=$(sc_json_backend)
	case "$be" in
		jq)   jq -e --arg p "$p" '
				getpath($p|split(".")) as $v
				| ($v|type)=="array"
				  and (all($v[]; . as $e
				      | ($ARGS.positional | all(. as $k | ($e|type)=="object" and ($e|has($k))))))
			' --args "$@" < "$f" >/dev/null 2>&1 && return 0 || return 1 ;;
		py:*) "$(sc_pybin)" "$_SC_JSON_DIR/jsonq.py" "$f" allhave "$p" "$@"; return $? ;;
		*)    return 2 ;;
	esac
}

# sc_json_profile_facts <file> -- emit all facts check-config needs as
# eval-safe KEY=VALUE lines, in ONE python call (jq backend assembles them from
# the per-call helpers). rc 2 if no backend.
sc_json_profile_facts() {
	local f=$1 be; be=$(sc_json_backend)
	case "$be" in
		py:*) "$(sc_pybin)" "$_SC_JSON_DIR/jsonq.py" "$f" facts; return $? ;;
		jq)
			local fdisint=0 fd broker=0 server=0 tlen agg dtype dlen hnd=0 hj=0 ht=0
			sc_json_is_int "$f" ccow.tenant.failure_domain && fdisint=1
			fd=$(sc_json_get "$f" ccow.tenant.failure_domain 2>/dev/null) || fd=""
			sc_json_nonempty_str "$f" ccow.network.broker_interfaces && broker=1
			sc_json_nonempty_str "$f" ccowd.network.server_interfaces && server=1
			tlen=$(sc_json_arr_len "$f" ccowd.transport 2>/dev/null) || tlen=-1
			agg=$(sc_json_get "$f" auditd.is_aggregator 2>/dev/null) || agg="_absent_"
			dtype=$(sc_json_type "$f" rtrd.devices 2>/dev/null) || dtype="absent"
			dlen=$(sc_json_arr_len "$f" rtrd.devices 2>/dev/null) || dlen=-1
			sc_json_all_have "$f" rtrd.devices name device && hnd=1
			sc_json_all_have "$f" rtrd.devices journal && hj=1
			sc_json_all_have "$f" rtrd.devices readahead wal_disabled sync && ht=1
			printf 'FD_ISINT=%s\nFD_VALUE=%s\nBROKER_OK=%s\nSERVER_OK=%s\nTRANSPORT_LEN=%s\nIS_AGG=%s\nDEVICES_TYPE=%s\nDEVICES_LEN=%s\nHAVE_NAME_DEVICE=%s\nHAVE_JOURNAL=%s\nHAVE_TUNING=%s\n' \
				"$fdisint" "$fd" "$broker" "$server" "$tlen" "${agg:-_absent_}" "$dtype" "$dlen" "$hnd" "$hj" "$ht"
			return 0 ;;
		*) return 2 ;;
	esac
}
