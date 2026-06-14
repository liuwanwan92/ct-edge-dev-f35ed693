#!/usr/bin/env bash
#
# tests/test_script_health.sh — static analysis for all shell scripts in repo
#

set -uo pipefail
. "$(dirname "$0")/lib/common.sh"

# Discover all shell scripts
SCRIPTS=()
while IFS= read -r -d '' f; do
    SCRIPTS+=("$f")
done < <(find "$REPO_ROOT" -type f \( -name '*.sh' -o -perm /111 \) \
              ! -path '*/.git/*' ! -path '*/tests/*' \
              -print0 2>/dev/null)

for f in "$REPO_ROOT"/prometheus/svc-checks/nedge-prom-*; do
    [ -f "$f" ] && SCRIPTS+=("$f")
done
[ -f "$REPO_ROOT/scripts/nestart" ] && SCRIPTS+=("$REPO_ROOT/scripts/nestart")
mapfile -t SCRIPTS < <(printf '%s\n' "${SCRIPTS[@]}" | sort -u)

INSTALL_SCRIPT="$REPO_ROOT/prometheus/install_dashboard.sh"
NESTART="$REPO_ROOT/scripts/nestart"
HAS_SHELLCHECK=0
command -v shellcheck >/dev/null 2>&1 && HAS_SHELLCHECK=1

# ──────────────────────────────────────────────────────────────
# Helper functions
# ──────────────────────────────────────────────────────────────

_check_syntax() {
    local script="$1" rel="$2"
    local output
    if output="$(bash -n "$script" 2>&1)"; then
        _pass "bash -n OK"
    else
        _fail "bash -n syntax error in $rel"
        log_diag "$output"
    fi
}

_check_shebang() {
    local script="$1" rel="$2"
    local first_line
    first_line="$(head -1 "$script")"
    if printf '%s' "$first_line" | grep -qE '^#!.*bash'; then
        _pass "shebang present"
    elif printf '%s' "$first_line" | grep -qE '^#!'; then
        _pass "shebang present (non-bash)"
    else
        _fail "missing shebang in $rel (first line: '$first_line')"
    fi
}

_check_shellcheck() {
    local script="$1" rel="$2"
    if [ "$HAS_SHELLCHECK" -eq 0 ]; then
        skip_test "shellcheck not installed"
        return
    fi
    local output rc=0
    output="$(shellcheck -S warning -e SC1091,SC2086,SC2154 "$script" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        _pass "shellcheck clean"
    else
        _fail "shellcheck warnings in $rel"
        log_diag "$(printf '%s\n' "$output" | head -10)"
    fi
}

_check_grafana_json_ref() {
    local referenced_url
    referenced_url="$(grep -oE 'https://raw\.githubusercontent\.com/.*\.json' "$INSTALL_SCRIPT" | head -1)"
    local referenced_file
    referenced_file="$(printf '%s' "$referenced_url" | grep -oE '[^/]+\.json$')"
    if [ -z "$referenced_file" ]; then
        _fail "no Grafana JSON URL found in install_dashboard.sh"
        return
    fi
    if [ -f "$REPO_ROOT/prometheus/$referenced_file" ]; then
        _pass "referenced Grafana dashboard exists: $referenced_file"
    else
        local available
        available="$(ls "$REPO_ROOT"/prometheus/NexentaEdge-Grafana-*.json 2>/dev/null | xargs -I{} basename {})"
        _fail "install_dashboard.sh references '$referenced_file' but it does not exist in repo"
        log_diag "Available dashboards: $available"
    fi
}

_check_container_detection() {
    local detection_line
    detection_line="$(grep -n 'docker ps.*filter.*name.*wc -l' "$INSTALL_SCRIPT" | head -1)"
    if [ -n "$detection_line" ]; then
        if printf '%s' "$detection_line" | grep -q 'wc -l'; then
            _fail "container detection uses fragile 'wc -l' approach"
            log_diag "Line: $detection_line"
            log_diag "docker ps always outputs a header line, so wc -l >= 1 even with 0 containers"
        else
            _pass "container detection looks robust"
        fi
    else
        _pass "no wc -l based container detection found"
    fi
}

_check_pre_existing_container() {
    if grep -q 'docker rm' "$INSTALL_SCRIPT"; then
        _pass "script mentions docker rm for cleanup"
    else
        _fail "script does not offer container cleanup on pre-existing container"
        log_diag "When 'container already exists' error fires, user has no automated cleanup path"
    fi
}

_check_grafana_version_mismatch() {
    local grafana_container_ver
    grafana_container_ver="$(grep -oE 'grafana/grafana:[0-9.]+' "$INSTALL_SCRIPT" | head -1 | cut -d: -f2)"
    if [ -z "$grafana_container_ver" ]; then
        skip_test "could not parse Grafana container version"
        return
    fi
    local major
    major="$(printf '%s' "$grafana_container_ver" | cut -d. -f1)"
    if [ "$major" -le 5 ] 2>/dev/null; then
        _fail "Grafana container version $grafana_container_ver is very old (5.x)"
        log_diag "Dashboard JSON files reference newer features"
    else
        _pass "Grafana container version $grafana_container_ver is current enough"
    fi
}

_check_nestart_output() {
    local replicast_line
    replicast_line="$(grep -n 'ReplicastNet' "$NESTART" | head -1)"
    if printf '%s' "$replicast_line" | grep -q 'CCOW_CLNET'; then
        _fail "nestart prints CCOW_CLNET for ReplicastNet line"
        log_diag "Line: $replicast_line"
        log_diag "Should reference CCOW_REPNET, not CCOW_CLNET"
    else
        _pass "ReplicastNet output references correct variable"
    fi
}

_check_nestart_modprobe() {
    local modprobe_line
    modprobe_line="$(grep -n 'modprobe' "$NESTART" | head -1)"
    local line_num
    line_num="$(printf '%s' "$modprobe_line" | cut -d: -f1)"
    if [ -z "$line_num" ]; then
        skip_test "no modprobe found in nestart"
        return
    fi
    if printf '%s' "$modprobe_line" | grep -qE '\|\||&&'; then
        _pass "modprobe has inline error handling"
    else
        local context
        context="$(sed -n "$((line_num+1)),$((line_num+3))p" "$NESTART")"
        if printf '%s' "$context" | grep -qE '\$\?|if '; then
            _pass "modprobe result is checked afterwards"
        else
            _fail "modprobe nbd has no error handling"
            log_diag "If nbd kernel module is unavailable, container start will fail obscurely"
        fi
    fi
}

_check_nestart_docker() {
    local docker_run_line
    docker_run_line="$(grep -n 'docker run' "$NESTART" | tail -1)"
    if [ -z "$docker_run_line" ]; then
        skip_test "no docker run found in nestart"
        return
    fi
    local line_num
    line_num="$(printf '%s' "$docker_run_line" | cut -d: -f1)"
    local after
    after="$(sed -n "$((line_num+1)),$((line_num+3))p" "$NESTART" 2>/dev/null)"
    if printf '%s' "$after" | grep -qE '\$\?|if |exit|\|\|'; then
        _pass "docker run result is checked"
    else
        _fail "docker run failure is not detected"
        log_diag "If docker run fails, subsequent 'docker network connect' will fail with confusing errors"
    fi
}

_check_tmpfile_scope() {
    local script="$1" rel="$2"
    local prom_export_uses_tmpfile=0
    local prom_export_declares_tmpfile=0

    if grep -A20 'prom_export()' "$script" | grep -q '\$tmpfile\|> \$tmpfile'; then
        prom_export_uses_tmpfile=1
    fi
    if grep -A20 'prom_export()' "$script" | grep -q 'local tmpfile'; then
        prom_export_declares_tmpfile=1
    fi

    if [ "$prom_export_uses_tmpfile" -eq 1 ] && [ "$prom_export_declares_tmpfile" -eq 0 ]; then
        _fail "prom_export() uses \$tmpfile without declaring it"
        log_diag "Variable is declared as local in last_result(), not in prom_export()"
        log_diag "This works due to bash dynamic scoping but would fail under set -u"
    else
        _pass "tmpfile variable scoping OK"
    fi
}

_check_urls() {
    local script="$1" rel="$2"
    local urls
    urls="$(grep -oE 'https?://[^ "'"'"'>]+' "$script" 2>/dev/null || true)"
    if [ -z "$urls" ]; then
        _pass "no URLs to check"
        return
    fi
    local bad=0
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        if printf '%s' "$url" | grep -qi 'NexentaEdge-Grafana-v1\.0'; then
            _fail "stale URL reference: $url"
            log_diag "Repo has v2.1.3-FP1 and v2.1.3-FP2, not v1.0"
            bad=1
        fi
    done <<< "$urls"
    [ "$bad" -eq 0 ] && _pass "URLs look current"
}

_check_hardcoded_passwords() {
    local bad=0
    for script in "${SCRIPTS[@]}"; do
        local rel="${script#"$REPO_ROOT/"}"
        local matches
        matches="$(grep -n -v '^\s*#' "$script" | grep -iE 'PASSWORD="[^"]{3,}"' || true)"
        if [ -n "$matches" ]; then
            _fail "hardcoded password in $rel"
            log_diag "$matches"
            bad=1
        fi
    done
    [ "$bad" -eq 0 ] && _pass "no hardcoded passwords found"
}

# ──────────────────────────────────────────────────────────────
# Test execution
# ──────────────────────────────────────────────────────────────
begin_suite "script-health"

for script in "${SCRIPTS[@]}"; do
    rel="${script#"$REPO_ROOT/"}"
    run_test "syntax:$rel" _check_syntax "$script" "$rel"
done

for script in "${SCRIPTS[@]}"; do
    rel="${script#"$REPO_ROOT/"}"
    run_test "shebang:$rel" _check_shebang "$script" "$rel"
done

for script in "${SCRIPTS[@]}"; do
    rel="${script#"$REPO_ROOT/"}"
    run_test "shellcheck:$rel" _check_shellcheck "$script" "$rel"
done

if [ -f "$INSTALL_SCRIPT" ]; then
    run_test "dashboard:grafana-json-reference" _check_grafana_json_ref
    run_test "dashboard:container-detection-logic" _check_container_detection
    run_test "dashboard:die-on-pre-existing" _check_pre_existing_container
    run_test "dashboard:grafana-version-mismatch" _check_grafana_version_mismatch
fi

if [ -f "$NESTART" ]; then
    run_test "nestart:output-consistency" _check_nestart_output
    run_test "nestart:modprobe-error-handling" _check_nestart_modprobe
    run_test "nestart:docker-error-handling" _check_nestart_docker
fi

for check_script in "$REPO_ROOT"/prometheus/svc-checks/nedge-prom-*; do
    [ -f "$check_script" ] || continue
    rel="${check_script#"$REPO_ROOT/"}"
    run_test "svc-check:tmpfile-scope:$rel" _check_tmpfile_scope "$check_script" "$rel"
done

for script in "${SCRIPTS[@]}"; do
    rel="${script#"$REPO_ROOT/"}"
    run_test "urls:$rel" _check_urls "$script" "$rel"
done

run_test "security:hardcoded-passwords" _check_hardcoded_passwords

end_suite
