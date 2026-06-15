#!/usr/bin/env bash
#
# checks.sh - the actual monitoring config validations, grouped by category.
#
# Every check function takes a single PROM_DIR (the directory holding the
# monitoring config, normally the repo's prometheus/ dir) and derives the rest:
#
#   $PROM_DIR/prometheus.yml                 scrape config
#   $PROM_DIR/install_dashboard.sh           dashboard installer
#   $PROM_DIR/grafana/prometheus.yml         grafana datasource
#   $PROM_DIR/grafana/NexentaEdge.yml        grafana dashboard provider
#   $PROM_DIR/NexentaEdge-Grafana-*.json     dashboards
#   $PROM_DIR/svc-checks/<probe>             service probes
#
# Functions emit pass/fail via common.sh AND return nonzero iff they recorded a
# failure, so they can be driven both by selfcheck.sh (human report) and by the
# test suite (subshell exit-code assertions).
#
# Requires common.sh to be sourced first.

# ----- canonical values (single source of truth) -----
SC_METRIC_PORT=8881      # NexentaEdge built-in exporter (scraped by the 'nexentaedge' job)
SC_PROM_PORT=9090        # Prometheus
SC_GRAFANA_HOSTPORT=3001 # Grafana host port
SC_GRAFANA_CONTPORT=3000 # Grafana container port
SC_PROBE_SOCAT_PORT=8090 # port the probe scripts are served on via socat

# Probe manifest: proto  script_basename  metric_name  socat_port  tools(csv)
sc_manifest_rows() {
  cat <<'EOF'
iscsi nedge-prom-iscsi-check nedge_iscsi_service_status 8090 iscsi-ls
nfs nedge-prom-nfs-check nedge_nfs_service_status 8090 mount,showmount,df,rpcinfo
s3 nedge-prom-s3-check nedge_s3_service_status 8090 curl,openssl,base64
EOF
}

# Documented state set each probe must still emit (contract pinning).
sc_states_for() {
  case "$1" in
    iscsi) echo "1 0 -1" ;;
    nfs)   echo "1 0 -1 -2 -3" ;;
    s3)    echo "1 0 -1 -2" ;;
  esac
}

# Validate JSON with whatever is available; rc 0 = valid, 1 = invalid, 2 = no validator.
#
# Two portability hazards are handled here:
#  - JSON is fed on STDIN, never as a path argument, so a cygwin path like
#    /e/work/... is never handed to a Windows interpreter that can't open it.
#  - Each candidate engine is probed with a trivial '{}' first; an engine that
#    can't even validate '{}' (e.g. the Windows Store 'python3' app-execution
#    alias, which returns a bogus code) is skipped rather than trusted.
_sc_json_engine=""

_sc_json_run() { # $1=engine; reads JSON from stdin
  case "$1" in
    node)    node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' ;;
    jq)      jq -e . >/dev/null ;;
    python3) python3 -c 'import json,sys; json.load(sys.stdin)' ;;
    python)  python  -c 'import json,sys; json.load(sys.stdin)' ;;
    *)       return 2 ;;
  esac
}

_sc_probe_engine() {
  local e
  for e in node jq python3 python; do
    command -v "$e" >/dev/null 2>&1 || continue
    if printf '{}' | _sc_json_run "$e" >/dev/null 2>&1; then
      printf '%s' "$e"; return 0
    fi
  done
  return 1
}

sc_validate_json() {
  local f="$1"
  if [ -z "$_sc_json_engine" ]; then
    _sc_json_engine="$(_sc_probe_engine || true)"
  fi
  [ -n "$_sc_json_engine" ] || return 2
  _sc_json_run "$_sc_json_engine" < "$f" 2>/dev/null
}

# Extract the port of the 'nexentaedge' scrape job's target (empty if not found).
sc_nexentaedge_port() {
  local yml="$1"
  awk '
    /job_name:.*nexentaedge/ { f=1 }
    f && /job_name:/ && !/nexentaedge/ { f=0 }
    f && /targets:/ {
      if (match($0, /:[0-9]+/)) { print substr($0, RSTART+1, RLENGTH-1); exit }
    }
  ' "$yml"
}

# =====================================================================
# SCRAPE - fear #1: scrape config points at a probe that does not exist
#          or at the wrong port.
# =====================================================================
check_scrape() {
  local dir="$1"
  local _before=$_SC_FAIL_TOTAL
  local yml="$dir/prometheus.yml" install="$dir/install_dashboard.sh" svc="$dir/svc-checks"

  assert_file_exists "$yml" "scrape config present (prometheus.yml)"
  if [ -f "$yml" ]; then
    assert_grep_re "$yml" 'scrape_configs:' "prometheus.yml has scrape_configs"
    assert_grep_re "$yml" "job_name:[[:space:]]*['\"]?nexentaedge" "scrape config defines 'nexentaedge' job"
    local port; port="$(sc_nexentaedge_port "$yml")"
    assert_eq "$SC_METRIC_PORT" "${port:-<none>}" "nexentaedge job target port is $SC_METRIC_PORT"
  fi

  # Every probe referenced by the monitoring setup must exist and emit its metric,
  # so a scrape target can never silently point at a vanished/renamed probe.
  local proto base metric sport tools
  while read -r proto base metric sport tools; do
    [ -z "$proto" ] && continue
    assert_file_exists "$svc/$base" "probe '$proto' script present ($base)"
    if [ -f "$svc/$base" ]; then
      assert_grep_fixed "$svc/$base" "$metric" "probe '$proto' emits metric $metric"
    fi
  done < <(sc_manifest_rows)

  # install's metric port must agree with the scrape target port.
  assert_grep_fixed "$install" "METRICPORT=$SC_METRIC_PORT" \
    "install_dashboard.sh METRICPORT matches scrape port ($SC_METRIC_PORT)"

  [ "$_SC_FAIL_TOTAL" -gt "$_before" ] && return 1 || return 0
}

# =====================================================================
# PROBES (a) - fear #2: pin each probe's metric name and documented
#          state set so a future edit cannot silently change the contract.
# =====================================================================
check_probes_contract() {
  local dir="$1"
  local _before=$_SC_FAIL_TOTAL
  local svc="$dir/svc-checks"
  local proto base metric sport tools st
  while read -r proto base metric sport tools; do
    [ -z "$proto" ] && continue
    assert_file_exists "$svc/$base" "probe '$proto' script present ($base)"
    [ -f "$svc/$base" ] || continue
    assert_grep_fixed "$svc/$base" "$metric" "probe '$proto' metric pinned: $metric"
    for st in $(sc_states_for "$proto"); do
      assert_grep_re "$svc/$base" "echo[[:space:]]+\"?${st}\"?" \
        "probe '$proto' still emits state '$st'"
    done
  done < <(sc_manifest_rows)
  [ "$_SC_FAIL_TOTAL" -gt "$_before" ] && return 1 || return 0
}

# =====================================================================
# PROBES (b) - fear #2: each probe's required external tools must be
#          present on THIS host, otherwise a missing dependency is
#          reported by the probe as a normal service state (e.g. -1).
#          Skipped on bare CI runners via --no-deps / SELFCHECK_SKIP_DEPS.
# =====================================================================
check_probe_deps() {
  local dir="$1"
  local _before=$_SC_FAIL_TOTAL
  local svc="$dir/svc-checks"
  local proto base metric sport tools tool
  while read -r proto base metric sport tools; do
    [ -z "$proto" ] && continue
    local oldifs="$IFS"; IFS=','
    for tool in $tools; do
      IFS="$oldifs"
      if command -v "$tool" >/dev/null 2>&1; then
        pass "probe '$proto' dependency present: $tool"
      else
        fail "DEP MISSING: '$tool' required by $base not found on PATH (probe would mis-report this as a service state)"
      fi
      IFS=','
    done
    IFS="$oldifs"
  done < <(sc_manifest_rows)
  [ "$_SC_FAIL_TOTAL" -gt "$_before" ] && return 1 || return 0
}

# ---- validate a single dashboard JSON (reused by check_dashboards + tests) ----
check_dashboard_json() {
  local json="$1"
  local _before=$_SC_FAIL_TOTAL
  local name; name="$(basename "$json")"

  assert_file_exists "$json" "dashboard present ($name)"
  if [ -f "$json" ]; then
    sc_validate_json "$json"; local rc=$?
    case "$rc" in
      0) pass "dashboard $name is valid JSON" ;;
      2) warn "no JSON validator (python/node/jq) found - degraded check for $name"
         case "$(tr -d '[:space:]' < "$json" | head -c1)" in
           '{') pass "dashboard $name looks structurally like JSON (degraded check)" ;;
           *)   fail "dashboard $name does not start with '{' (degraded check)" ;;
         esac ;;
      *) fail "dashboard $name is NOT valid JSON (would fail Grafana import)" ;;
    esac
    assert_grep_fixed "$json" '${DS_PROMETHEUS}' \
      "dashboard $name references \${DS_PROMETHEUS} datasource placeholder"
    assert_grep_re "$json" 'nedge_[a-z_]+' "dashboard $name queries nedge_* metrics"
  fi
  [ "$_SC_FAIL_TOTAL" -gt "$_before" ] && return 1 || return 0
}

# =====================================================================
# DASHBOARD - fear #3: dashboards must be importable (valid JSON +
#          expected placeholders) and the installer must reference a
#          dashboard file that actually exists.
# =====================================================================
check_dashboards() {
  local dir="$1"
  local _before=$_SC_FAIL_TOTAL
  local ds="$dir/grafana/prometheus.yml" prov="$dir/grafana/NexentaEdge.yml"
  local install="$dir/install_dashboard.sh"

  local found=0 json
  for json in "$dir"/NexentaEdge-Grafana-*.json; do
    [ -f "$json" ] || continue
    found=1
    check_dashboard_json "$json"
  done
  [ "$found" -eq 1 ] || fail "no dashboard JSON (NexentaEdge-Grafana-*.json) found in $dir"

  assert_grep_fixed "$ds" "PROMETHEUS_IP:PROMETHEUS_PORT" \
    "grafana datasource has IP/PORT placeholder the installer rewrites"
  assert_grep_fixed "$prov" "/etc/grafana/provisioning/dashboards/" \
    "grafana dashboard provider path present"

  # Loudly surface the installer/repo dashboard filename mismatch.
  if [ -f "$install" ]; then
    local ref; ref="$(grep -oE 'NexentaEdge-Grafana-[A-Za-z0-9._-]+\.json' "$install" | head -1)"
    if [ -n "$ref" ] && [ ! -f "$dir/$ref" ]; then
      warn "install_dashboard.sh downloads '$ref' which is NOT in the repo (repo ships: $(basename -a "$dir"/NexentaEdge-Grafana-*.json 2>/dev/null | tr '\n' ' ')) - import target may be stale"
    fi
  fi
  [ "$_SC_FAIL_TOTAL" -gt "$_before" ] && return 1 || return 0
}

# =====================================================================
# INSTALL - ports / exit codes / error messages, plus the anti-silent-
#          breakage guard: every literal token the installer rewrites
#          with sed MUST still exist in the file it rewrites, otherwise
#          the sed silently no-ops and ships a misconfigured stack.
# =====================================================================
check_install() {
  local dir="$1"
  local _before=$_SC_FAIL_TOTAL
  local install="$dir/install_dashboard.sh" yml="$dir/prometheus.yml"
  local ds="$dir/grafana/prometheus.yml"

  assert_file_exists "$install" "installer present (install_dashboard.sh)"
  if [ -f "$install" ]; then
    # dependency-guard contract (exit codes + messages live in die())
    assert_grep_fixed "$install" "ERROR: Docker not installed" "installer guards missing docker"
    assert_grep_fixed "$install" "ERROR: curl not installed" "installer guards missing curl"
    # port consistency
    assert_grep_fixed "$install" "METRICPORT=$SC_METRIC_PORT" "installer metric port = $SC_METRIC_PORT"
    assert_grep_fixed "$install" "-p $SC_PROM_PORT:$SC_PROM_PORT" "installer maps Prometheus port $SC_PROM_PORT"
    assert_grep_fixed "$install" "-p $SC_GRAFANA_HOSTPORT:$SC_GRAFANA_CONTPORT" \
      "installer maps Grafana port $SC_GRAFANA_HOSTPORT:$SC_GRAFANA_CONTPORT"
    # the transforms still exist in the installer
    assert_grep_fixed "$install" "172.20.1.20:$SC_METRIC_PORT" "installer still rewrites the prometheus.yml target"
    assert_grep_fixed "$install" "PROMETHEUS_IP:PROMETHEUS_PORT" "installer still rewrites the datasource URL"
  fi

  # sed targets must exist verbatim in the files being rewritten.
  assert_grep_fixed "$yml" "targets: ['172.20.1.20:$SC_METRIC_PORT']" \
    "prometheus.yml still contains the exact target the installer's sed rewrites"
  assert_grep_fixed "$ds" "PROMETHEUS_IP:PROMETHEUS_PORT" \
    "datasource yml still contains the exact token the installer's sed rewrites"
  local json hit=0
  for json in "$dir"/NexentaEdge-Grafana-*.json; do
    [ -f "$json" ] || continue
    if grep -Fq -- '${DS_PROMETHEUS}' "$json"; then hit=1; fi
  done
  if [ "$hit" -eq 1 ]; then
    pass "a dashboard JSON still contains \${DS_PROMETHEUS} the installer's sed rewrites"
  else
    fail "no dashboard JSON contains \${DS_PROMETHEUS} - installer's sed would no-op (broken import)"
  fi

  [ "$_SC_FAIL_TOTAL" -gt "$_before" ] && return 1 || return 0
}
