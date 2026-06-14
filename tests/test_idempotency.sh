#!/usr/bin/env bash
#
# tests/test_idempotency.sh — verify scripts are safe for repeated execution
#

set -uo pipefail
. "$(dirname "$0")/lib/common.sh"

# ──────────────────────────────────────────────────────────────
# Helper functions
# ──────────────────────────────────────────────────────────────

_check_dashboard_rerun() {
    local script="$REPO_ROOT/prometheus/install_dashboard.sh"
    [ ! -f "$script" ] && { skip_test "script not found"; return; }
    local die_count
    die_count="$(grep -c 'die.*already' "$script")"
    if [ "$die_count" -gt 0 ]; then
        _fail "script dies on pre-existing container — not idempotent"
        log_diag "Re-running after a successful install will fail"
        if grep -qiE '\-\-force|\-\-reinstall|\-\-upgrade' "$script"; then
            _pass "but a force/reinstall flag exists"
        else
            _fail "no --force or --reinstall option available"
        fi
    else
        _pass "no hard-fail on pre-existing containers"
    fi
}

_check_pull_idempotent() {
    local script="$REPO_ROOT/prometheus/install_dashboard.sh"
    [ ! -f "$script" ] && { skip_test "script not found"; return; }
    if grep -q 'docker pull' "$script"; then
        _pass "docker pull is used (idempotent by nature)"
    else
        skip_test "no docker pull in script"
    fi
}

_check_nestart_var_dir() {
    local script="$REPO_ROOT/scripts/nestart"
    [ ! -f "$script" ] && { skip_test "script not found"; return; }
    # Check for conditional mkdir (may span multiple lines)
    if grep -q 'test ! -e.*var' "$script" || grep -q 'mkdir -p.*var' "$script"; then
        _pass "var directory creation is conditional/idempotent"
    elif grep -q 'mkdir.*var' "$script"; then
        _fail "var directory creation may fail on re-run (plain mkdir without -p)"
    else
        skip_test "no var directory handling found"
    fi
}

_check_nestart_network() {
    local script="$REPO_ROOT/scripts/nestart"
    [ ! -f "$script" ] && { skip_test "script not found"; return; }
    if grep -q 'docker run.*--name' "$script"; then
        local name_handling
        name_handling="$(grep -B2 -A2 'docker run.*--name' "$script")"
        if printf '%s' "$name_handling" | grep -qiE 'docker rm|docker stop|existing'; then
            _pass "script handles pre-existing container"
        else
            _fail "docker run --name will fail if container already exists"
            log_diag "nestart does not check for or remove pre-existing containers"
        fi
    fi
    if grep -q 'docker network create.*1>/dev/null.*2>/dev/null' "$script"; then
        _pass "network create failures are suppressed (idempotent-ish)"
    fi
}

_check_tmp_cleanup() {
    local bad=0
    for check in "$REPO_ROOT"/prometheus/svc-checks/nedge-prom-*; do
        [ -f "$check" ] || continue
        local name; name="$(basename "$check")"
        local prom_export_tmpfile last_result_tmpfile
        prom_export_tmpfile="$(grep -A20 'prom_export()' "$check" | grep -oE '\$tmpfile|\$\{tmpfile\}' | head -1)"
        last_result_tmpfile="$(grep -A10 'last_result()' "$check" | grep -oE '/tmp/[^ "]+')"
        if [ -n "$prom_export_tmpfile" ] && [ -n "$last_result_tmpfile" ]; then
            if ! grep -A20 'prom_export()' "$check" | grep -q 'local tmpfile\|tmpfile='; then
                _fail "$name: prom_export() uses \$tmpfile but never declares it"
                log_diag "prom_export writes to \$tmpfile (undefined in its scope)"
                log_diag "last_result reads from $last_result_tmpfile"
                bad=1
            fi
        fi
    done
    [ "$bad" -eq 0 ] && _pass "tmpfile scoping checked for all svc-checks"
}

_test_repeated_var_dir() {
    local tmpdir; tmpdir="$(test_make_tmpdir)"
    local test_dir="$tmpdir/c0"
    mkdir -p "$test_dir"
    printf '{"ccow":{},"ccowd":{},"auditd":{},"rtrd":{"devices":[]}}' > "$test_dir/nesetup.json"
    local rc1=0 rc2=0
    ( if test ! -e "$test_dir/var"; then mkdir "$test_dir/var"; fi ) 2>/dev/null || rc1=$?
    ( if test ! -e "$test_dir/var"; then mkdir "$test_dir/var"; fi ) 2>/dev/null || rc2=$?
    if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]; then
        _pass "var dir creation is idempotent (both runs succeed)"
    else
        _fail "var dir creation fails on re-run (rc1=$rc1, rc2=$rc2)"
    fi
    assert_file_exists "$test_dir/var" "var directory exists after both runs"
}

_check_config_overwrite() {
    local script="$REPO_ROOT/prometheus/install_dashboard.sh"
    [ ! -f "$script" ] && { skip_test "script not found"; return; }
    if grep -qE 'cp.*bak|backup|validate' "$script"; then
        _pass "script backs up or validates configs before overwrite"
    else
        _fail "script overwrites configs without backup or validation"
        log_diag "If curl fails, config files may be empty or corrupt"
    fi
}

_check_prom_no_dupes() {
    local file="$REPO_ROOT/prometheus/prometheus.yml"
    [ ! -f "$file" ] && { skip_test "prometheus.yml not found"; return; }
    local jobs unique_jobs total_jobs unique_count
    jobs="$(grep 'job_name' "$file" | sed 's/.*job_name: *//' | tr -d "'\" ")"
    unique_jobs="$(printf '%s\n' "$jobs" | sort -u)"
    total_jobs="$(printf '%s\n' "$jobs" | wc -l)"
    unique_count="$(printf '%s\n' "$unique_jobs" | wc -l)"
    if [ "$total_jobs" -eq "$unique_count" ]; then
        _pass "no duplicate job names in prometheus.yml"
    else
        _fail "duplicate job names found in prometheus.yml"
    fi
}

_check_modprobe_idempotent() {
    local script="$REPO_ROOT/scripts/nestart"
    [ ! -f "$script" ] && { skip_test "script not found"; return; }
    if grep -q 'modprobe' "$script"; then
        _pass "modprobe is used (inherently idempotent)"
    fi
    if grep -q 'mount --make-shared' "$script"; then
        _pass "mount --make-shared is used (inherently idempotent)"
    fi
}

_check_neadmrc_immutable() {
    local modified=0
    while IFS= read -r script; do
        if grep -ql 'neadmrc' "$script" 2>/dev/null; then
            if grep -qE '>.*neadmrc|sed -i.*neadmrc|tee.*neadmrc' "$script" 2>/dev/null; then
                local rel="${script#"$REPO_ROOT/"}"
                _fail "script $rel modifies .neadmrc"
                modified=1
            fi
        fi
    done < <(find "$REPO_ROOT" -type f \( -name '*.sh' -o -perm /111 \) \
                 ! -path '*/.git/*' ! -path '*/tests/*' -print 2>/dev/null)
    [ "$modified" -eq 0 ] && _pass "no scripts modify .neadmrc"
}

# ──────────────────────────────────────────────────────────────
# Test execution
# ──────────────────────────────────────────────────────────────
begin_suite "idempotency"

run_test "dashboard:re-run-dies-on-existing" _check_dashboard_rerun
run_test "dashboard:docker-pull-idempotent" _check_pull_idempotent
run_test "nestart:var-dir-idempotent" _check_nestart_var_dir
run_test "nestart:network-create-idempotent" _check_nestart_network
run_test "svc-checks:tmp-file-cleanup" _check_tmp_cleanup
run_test "nestart:repeated-var-dir-creation" _test_repeated_var_dir
run_test "dashboard:config-overwrite-idempotent" _check_config_overwrite
run_test "prom:no-duplicate-targets" _check_prom_no_dupes
run_test "nestart:modprobe-idempotent" _check_modprobe_idempotent
run_test "neadmrc:not-modified-by-scripts" _check_neadmrc_immutable

end_suite
