#!/usr/bin/env bash
#
# mockenv.sh - build a controllable fake environment so the probe scripts and
# install script can be exercised WITHOUT a real cluster, network, or the real
# external tools (iscsi-ls, curl, openssl, showmount, df, rpcinfo, docker...).
#
# Source this file, then (typically inside a subshell so PATH/overrides don't
# leak) call mock_init and the mock_* helpers.
#
# Helpers:
#   mock_init                     - create a temp bin dir, prepend it to PATH (sets MOCK_BIN)
#   mock_cleanup                  - remove the temp bin dir
#   mock_tool NAME RC [STDOUT]    - shim that prints STDOUT (one line) and exits RC
#   mock_tool_absent NAME         - shim that exits 127, reproducing "command not found"
#   mock_curl_seq TOK...          - curl shim; each call pops the next TOK in {200,403,none}
#   mock_ps_threshold N           - ps shim: first N calls report "dead" (exit1), later "alive" (exit0)
#   mock_sleep_noop / mock_kill_noop - instant no-op sleep/kill for timing loops
#   load_probe_funcs SCRIPT       - import a probe's *_check functions without starting socat

mock_init() {
  MOCK_BIN="$(mktemp -d)"
  export MOCK_BIN
  PATH="$MOCK_BIN:$PATH"
  export PATH
}

mock_cleanup() {
  [ -n "${MOCK_BIN:-}" ] && rm -rf "$MOCK_BIN"
  return 0
}

# mock_tool NAME RC [STDOUT]
mock_tool() {
  local name="$1" rc="$2" out="${3-}"
  local f="$MOCK_BIN/$name"
  {
    echo '#!/usr/bin/env bash'
    if [ -n "$out" ]; then
      echo "cat <<'__MOCKOUT__'"
      printf '%s\n' "$out"
      echo '__MOCKOUT__'
    fi
    echo "exit $rc"
  } > "$f"
  chmod 0755 "$f"
}

# A missing binary: real bash returns 127 for "command not found"; the probes
# only inspect the exit code, so a silent exit 127 faithfully reproduces it.
mock_tool_absent() {
  mock_tool "$1" 127
}

# curl shim driven by a token sequence (one token consumed per invocation).
# 200 -> "HTTP/1.1 200 OK", 403 -> "HTTP/1.1 403 Forbidden", none -> no output.
mock_curl_seq() {
  local f="$MOCK_BIN/curl"
  local seq="$MOCK_BIN/.curl_seq" idx="$MOCK_BIN/.curl_idx"
  : > "$seq"
  printf '%s\n' "$@" >> "$seq"
  echo 0 > "$idx"
  {
    echo '#!/usr/bin/env bash'
    echo "SEQ='$seq'"
    echo "IDX='$idx'"
    echo 'i=$(cat "$IDX" 2>/dev/null || echo 0)'
    echo 'i=$((i+1)); echo "$i" > "$IDX"'
    echo 'tok=$(sed -n "${i}p" "$SEQ")'
    echo 'case "$tok" in'
    echo '  200) echo "HTTP/1.1 200 OK" ;;'
    echo '  403) echo "HTTP/1.1 403 Forbidden" ;;'
    echo '  *) : ;;'
    echo 'esac'
    echo 'exit 0'
  } > "$f"
  chmod 0755 "$f"
}

# ps shim: model a background job that stays alive. The first N calls report
# "no such process" (exit 1 = finished), subsequent calls report "alive"
# (exit 0). N=0 => always alive; large N => always finished.
mock_ps_threshold() {
  local n="$1"
  local f="$MOCK_BIN/ps"
  local cnt="$MOCK_BIN/.ps_cnt"
  echo 0 > "$cnt"
  {
    echo '#!/usr/bin/env bash'
    echo "CNT='$cnt'"
    echo "N=$n"
    echo 'c=$(cat "$CNT" 2>/dev/null || echo 0)'
    echo 'c=$((c+1)); echo "$c" > "$CNT"'
    echo 'if [ "$c" -le "$N" ]; then exit 1; else exit 0; fi'
  } > "$f"
  chmod 0755 "$f"
}

mock_sleep_noop() { mock_tool sleep 0; }
mock_kill_noop()  { mock_tool kill 0; }

# install_dashboard.sh detects tools with `which <tool>`, not by calling them,
# so absence must be modelled at the `which` level (a 127-exit shim would still
# be "found" by which). This shim reports NAME as missing and delegates other
# lookups to the real resolver.
mock_which_missing() {
  local missing="$1" f="$MOCK_BIN/which"
  {
    echo '#!/usr/bin/env bash'
    echo "MISSING='$missing'"
    echo 'for a in "$@"; do'
    echo '  [ "$a" = "$MISSING" ] && exit 1'
    echo 'done'
    echo 'command -v "$1" >/dev/null 2>&1 && { echo "$1"; exit 0; } || exit 1'
  } > "$f"
  chmod 0755 "$f"
}

# Import a probe's pure logic (iscsi_check / nfs_check / s3_check and helpers)
# by stripping CR line endings and the trailing dispatch tail
# (process_http_req / on_uri_match / serve_http_req) before sourcing, so the
# socat HTTP server never starts and the original file is left untouched.
load_probe_funcs() {
  local script="$1" tmp
  tmp="$(mktemp)"
  sed 's/\r$//' "$script" | sed '/^process_http_req[[:space:]]*$/,$d' > "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

# Copy the monitoring config into DST so a test can mutate a file and prove a
# check fails on breakage, without touching the real repo files.
copy_monitoring_tree() {
  local src="$1" dst="$2"
  mkdir -p "$dst/grafana" "$dst/svc-checks"
  cp "$src/prometheus.yml"            "$dst/"          2>/dev/null
  cp "$src/install_dashboard.sh"      "$dst/"          2>/dev/null
  cp "$src/grafana/prometheus.yml"    "$dst/grafana/"  2>/dev/null
  cp "$src/grafana/NexentaEdge.yml"   "$dst/grafana/"  2>/dev/null
  cp "$src"/NexentaEdge-Grafana-*.json "$dst/"         2>/dev/null
  cp "$src"/svc-checks/nedge-prom-*   "$dst/svc-checks/" 2>/dev/null
  return 0
}
