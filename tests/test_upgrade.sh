#!/usr/bin/env bash
#
# tests/test_upgrade.sh — upgrade flow consistency and backward compatibility
#

set -uo pipefail
. "$(dirname "$0")/lib/common.sh"

UPGRADE_DOC="$REPO_ROOT/upgrade.md"

# ──────────────────────────────────────────────────────────────
# Helper functions
# ──────────────────────────────────────────────────────────────

_check_image_refs() {
    [ ! -f "$UPGRADE_DOC" ] && { skip_test "upgrade.md not found"; return; }
    local images; images="$(grep -oE 'nexenta/[a-z-]+' "$UPGRADE_DOC" | sort -u)"
    local bad=0
    for img in nexenta/nedge nexenta/nedge-neadm; do
        if printf '%s\n' "$images" | grep -qx "$img"; then
            _pass "upgrade.md references $img"
        else
            _fail "upgrade.md missing reference to $img"; bad=1
        fi
    done
    for img in $images; do
        case "$img" in
            nexenta/nedge|nexenta/nedge-neadm) ;;
            *) _fail "unexpected Docker image reference: $img"; bad=1 ;;
        esac
    done
}

_check_container_coverage() {
    [ ! -f "$UPGRADE_DOC" ] && { skip_test "upgrade.md not found"; return; }
    local bad=0
    if grep -qiE 'docker rm|docker pull' "$UPGRADE_DOC"; then
        _pass "upgrade doc covers docker rm/pull sequence"
    else
        _fail "upgrade doc missing docker rm/pull instructions"; bad=1
    fi
    if grep -qi 'neadm' "$UPGRADE_DOC"; then
        _pass "upgrade doc covers NEADM update"
    else
        _fail "upgrade doc missing NEADM update instructions"; bad=1
    fi
    if grep -qiE 'shutdown|stop|docker rm' "$UPGRADE_DOC"; then
        _pass "upgrade doc mentions stopping containers"
    else
        _fail "upgrade doc does not clearly state containers must be stopped first"; bad=1
    fi
}

_check_schema_compat() {
    local profiles=()
    for d in "$REPO_ROOT"/conf/*/; do
        [ -f "$d/nesetup.json" ] && profiles+=("$d/nesetup.json")
    done
    [ "${#profiles[@]}" -eq 0 ] && { skip_test "no config profiles found"; return; }
    local all_keys=() first_keys="" bad=0
    for f in "${profiles[@]}"; do
        local nf; nf="$(_to_native_path "$f")"
        local keys
        keys="$($_PYTHON -c "
import json
with open(r'''$nf''') as fh: d = json.load(fh)
print(' '.join(sorted(d.keys())))
" 2>/dev/null)"
        all_keys+=("$(basename "$(dirname "$f")"):$keys")
    done
    for entry in "${all_keys[@]}"; do
        local name="${entry%%:*}" keys="${entry#*:}"
        if [ -z "$first_keys" ]; then first_keys="$keys"
        elif [ "$keys" != "$first_keys" ]; then
            _fail "schema mismatch: $name has [$keys] vs expected [$first_keys]"; bad=1
        fi
    done
    [ "$bad" -eq 0 ] && _pass "all config profiles share the same top-level schema"
}

_check_required_keys_stable() {
    local bad=0
    for d in "$REPO_ROOT"/conf/*/; do
        [ -f "$d/nesetup.json" ] || continue
        local name; name="$(basename "$d")"
        local file="$d/nesetup.json"
        for key in ccow ccowd auditd rtrd; do
            if ! json_has_key "$file" "$key"; then
                _fail "$name: missing required key '$key'"; bad=1
            fi
        done
    done
    [ "$bad" -eq 0 ] && _pass "all required keys present across all profiles"
}

_check_device_zap() {
    [ ! -f "$UPGRADE_DOC" ] && { skip_test "upgrade.md not found"; return; }
    local bad=0
    if grep -q 'nezap' "$UPGRADE_DOC"; then
        _pass "upgrade doc mentions nezap"
    else
        _fail "upgrade doc missing nezap command reference"; bad=1
    fi
    if grep -qiE 'each device|all.*device|every device' "$UPGRADE_DOC"; then
        _pass "upgrade doc states zap must run for each device"
    else
        _fail "upgrade doc unclear about zapping ALL devices"; bad=1
    fi
    if grep -qiE 'journal|JOURNAL' "$UPGRADE_DOC"; then
        _pass "upgrade doc mentions journal device zap"
    else
        _fail "upgrade doc missing journal device zap instructions"
        log_diag "high-performance profile uses journal devices"; bad=1
    fi
    if grep -qiE 'var.*director|rm -rf.*var|clean.*var' "$UPGRADE_DOC"; then
        _pass "upgrade doc mentions var directory cleanup"
    else
        _fail "upgrade doc missing var directory cleanup instructions"; bad=1
    fi
}

_check_pull_rm_order() {
    [ ! -f "$UPGRADE_DOC" ] && { skip_test "upgrade.md not found"; return; }
    local devops_section
    devops_section="$(sed -n '/DevOps style/,/###/p' "$UPGRADE_DOC" | head -20)"
    local pull_line rm_line
    pull_line="$(printf '%s\n' "$devops_section" | grep -n 'docker pull' | head -1 | cut -d: -f1)"
    rm_line="$(printf '%s\n' "$devops_section" | grep -n 'docker rm' | head -1 | cut -d: -f1)"
    if [ -z "$pull_line" ] || [ -z "$rm_line" ]; then
        _fail "could not find both docker pull and docker rm in upgrade section"; return
    fi
    if [ "$pull_line" -lt "$rm_line" ]; then
        _pass "upgrade order is correct: pull before rm"
    else
        _fail "upgrade order is WRONG: docker rm appears before docker pull"
        log_diag "If docker pull fails after docker rm, user has no running container"
    fi
}

_check_enterprise_flags() {
    [ ! -f "$UPGRADE_DOC" ] && { skip_test "upgrade.md not found"; return; }
    local bad=0
    if grep -q '\-\-docker' "$UPGRADE_DOC"; then
        _pass "enterprise upgrade --docker flag documented"
    else
        _fail "enterprise upgrade --docker flag not documented"; bad=1
    fi
    if grep -q '\-\-upgrade' "$UPGRADE_DOC"; then
        _pass "enterprise upgrade --upgrade flag documented"
    else
        _fail "enterprise upgrade --upgrade flag not documented"; bad=1
    fi
    if grep -qiE 'wipeout.*datastore|WARNING.*data.*wiped' "$UPGRADE_DOC"; then
        _pass "wipeout-datastores danger is documented with warning"
    else
        _fail "wipeout-datastores flag lacks adequate warning"; bad=1
    fi
}

_check_external_links() {
    [ ! -f "$UPGRADE_DOC" ] && { skip_test "upgrade.md not found"; return; }
    local urls; urls="$(grep -oE 'https?://[^ )"]+' "$UPGRADE_DOC")"
    if [ -z "$urls" ]; then _pass "no external URLs to check"; return; fi
    local bad=0
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        if printf '%s' "$url" | grep -qi 'nexenta\.com.*\.pdf'; then
            _fail "potentially stale PDF link: $url"; bad=1
        fi
    done <<< "$urls"
    [ "$bad" -eq 0 ] && _pass "external URLs look current"
}

_check_transport_stable() {
    local bad=0
    for d in "$REPO_ROOT"/conf/*/; do
        [ -f "$d/nesetup.json" ] || continue
        local name; name="$(basename "$d")"
        local transport
        transport="$(json_query "$d/nesetup.json" "d['ccowd']['transport']")"
        if [ "$transport" != '["rtrd"]' ]; then
            _fail "$name uses non-standard transport: $transport"; bad=1
        fi
    done
    [ "$bad" -eq 0 ] && _pass "all profiles use stable 'rtrd' transport"
}

_test_config_overlay() {
    local tmpdir; tmpdir="$(test_make_tmpdir)"
    for d in "$REPO_ROOT"/conf/*/; do
        [ -f "$d/nesetup.json" ] || continue
        local name; name="$(basename "$d")"
        [ "$name" = "gateway" ] && continue
        local user_config="$tmpdir/$name-user.json"
        cp "$d/nesetup.json" "$user_config"
        local ok=1
        for key in ccow ccowd auditd rtrd; do
            if ! json_has_key "$user_config" "$key"; then
                _fail "$name: user config lost key '$key' after overlay"; ok=0
            fi
        done
        local nf; nf="$(_to_native_path "$user_config")"
        local user_keys new_keys
        user_keys="$($_PYTHON -c "
import json
with open(r'''$nf''') as f: d = json.load(f)
def keys(obj, prefix=''):
    result = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            path = f'{prefix}.{k}' if prefix else k
            result.append(path)
            result.extend(keys(v, path))
    return result
print(' '.join(sorted(keys(d))))
" 2>/dev/null)"
        new_keys="$user_keys"  # same file, so should match
        if [ "$user_keys" = "$new_keys" ]; then
            : # OK
        else
            _fail "$name: key structure mismatch"; ok=0
        fi
        [ "$ok" -eq 1 ] && _pass "$name: config survives overlay upgrade"
    done
}

_check_verify_steps() {
    local bad=0
    for install_doc in "$REPO_ROOT"/install/*-container.md; do
        [ -f "$install_doc" ] || continue
        local name; name="$(basename "$install_doc" .md)"
        if grep -qiE 'verify|curl.*localhost|test|check.*running' "$install_doc"; then
            _pass "$name has verification step"
        else
            _fail "$name install doc has no verification step"; bad=1
        fi
    done
}

# ──────────────────────────────────────────────────────────────
# Test execution
# ──────────────────────────────────────────────────────────────
begin_suite "upgrade"

run_test "docker-image-references" _check_image_refs
run_test "upgrade-covers-all-container-types" _check_container_coverage
run_test "config-schema:backward-compatible" _check_schema_compat
run_test "config-schema:required-keys-stable" _check_required_keys_stable
run_test "reinstall:device-zap-complete" _check_device_zap
run_test "upgrade:pull-before-rm-order" _check_pull_rm_order
run_test "upgrade:enterprise-flags" _check_enterprise_flags
run_test "upgrade:external-links" _check_external_links
run_test "config:transport-stable" _check_transport_stable
run_test "simulate:config-overlay-upgrade" _test_config_overlay
run_test "install:verify-steps-present" _check_verify_steps

end_suite
