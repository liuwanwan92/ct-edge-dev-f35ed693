#!/usr/bin/env bash
#
# tests/test_conf_validate.sh — validate all nesetup.json configuration profiles
#
# What this catches:
#   • Invalid JSON syntax
#   • Missing required top-level keys (ccow, ccowd, auditd, rtrd)
#   • Missing nested keys (ccow.tenant, ccow.network, ccowd.transport, rtrd.devices)
#   • Inconsistent failure_domain / is_aggregator across profiles
#   • Gateway profile: must have empty devices list
#   • Single-node profile: must have failure_domain=0, is_aggregator=1
#   • High-performance profile: devices must have journal field
#   • Large-object-throughput: must have wal_disabled=1
#   • Device paths must start with /dev/
#   • Duplicate device paths within a profile
#

set -uo pipefail
. "$(dirname "$0")/lib/common.sh"

CONF_DIR="$REPO_ROOT/conf"

# Collect all profile directories that contain a nesetup.json
PROFILES=()
for d in "$CONF_DIR"/*/; do
    [ -f "$d/nesetup.json" ] && PROFILES+=("${d%/}")
done

# ──────────────────────────────────────────────────────────────
# Helper functions (defined BEFORE run_test calls)
# ──────────────────────────────────────────────────────────────

_check_readme() {
    local dir="$1" name="$2"
    if [ -f "$dir/README.md" ]; then
        _pass "README.md present"
    else
        _fail "README.md missing in $dir"
    fi
}

_check_json_valid() {
    local dir="$1" name="$2"
    assert_valid_json_file "$dir/nesetup.json" "nesetup.json for $name"
}

_check_required_keys() {
    local dir="$1" name="$2"
    local file="$dir/nesetup.json"
    local missing=0
    for key in ccow ccowd auditd rtrd; do
        if ! json_has_key "$file" "$key"; then
            _fail "missing top-level key '$key' in $name"
            log_diag "Expected key '$key' in $file"
            missing=1
        fi
    done
    if [ "$missing" -eq 0 ]; then
        _pass "all required top-level keys present"
    fi
}

_check_nested_keys() {
    local dir="$1" name="$2"
    local file="$dir/nesetup.json"
    local fail_count=0
    if ! json_has_key "$file" "ccow.tenant.failure_domain"; then
        _fail "missing ccow.tenant.failure_domain in $name"; fail_count=1
    fi
    if ! json_has_key "$file" "ccow.network.broker_interfaces"; then
        _fail "missing ccow.network.broker_interfaces in $name"; fail_count=1
    fi
    if ! json_has_key "$file" "ccowd.network.server_interfaces"; then
        _fail "missing ccowd.network.server_interfaces in $name"; fail_count=1
    fi
    if ! json_has_key "$file" "ccowd.transport"; then
        _fail "missing ccowd.transport in $name"; fail_count=1
    else
        local transport
        transport="$(json_query "$file" "d['ccowd']['transport']")"
        if [ "$transport" = "[]" ]; then
            _fail "ccowd.transport is empty array in $name"; fail_count=1
        fi
    fi
    if ! json_has_key "$file" "rtrd.devices"; then
        _fail "missing rtrd.devices in $name"; fail_count=1
    fi
    [ "$fail_count" -eq 0 ] && _pass "all required nested keys present"
}

_check_devices() {
    local dir="$1" name="$2"
    local file="$dir/nesetup.json"
    local nf; nf="$(_to_native_path "$file")"
    local dev_count
    dev_count="$(json_query "$file" "len(d['rtrd']['devices'])")"
    if [ "$dev_count" -eq 0 ]; then
        _fail "non-gateway profile $name has 0 devices"
        return
    fi
    local bad=0
    local dev_list
    dev_list="$($_PYTHON -c "
import json
with open(r'''$nf''') as f: d = json.load(f)
for dev in d['rtrd']['devices']:
    if not dev.get('device','').startswith('/dev/'):
        print('BAD:' + dev.get('device','<missing>'))
    if not dev.get('name',''):
        print('BAD_NAME:empty')
")"
    if printf '%s' "$dev_list" | grep -q "^BAD:"; then
        _fail "device paths not starting with /dev/ in $name"
        log_diag "$dev_list"
        bad=1
    fi
    if printf '%s' "$dev_list" | grep -q "^BAD_NAME:"; then
        _fail "empty device name in $name"
        bad=1
    fi
    local dup
    dup="$($_PYTHON -c "
import json
with open(r'''$nf''') as f: d = json.load(f)
paths = [dev['device'] for dev in d['rtrd']['devices']]
dups = [p for p in paths if paths.count(p) > 1]
if dups: print(','.join(set(dups)))
")"
    if [ -n "$dup" ]; then
        _fail "duplicate device paths in $name: $dup"
        bad=1
    fi
    [ "$bad" -eq 0 ] && _pass "$dev_count devices, all valid"
}

_check_gateway_empty_devices() {
    local file="$CONF_DIR/gateway/nesetup.json"
    local count
    count="$(json_query "$file" "len(d['rtrd']['devices'])")"
    assert_eq "0" "$count" "gateway devices list must be empty"
}

_check_single_node_fd() {
    local file="$CONF_DIR/single-node/nesetup.json"
    local fd
    fd="$(json_query "$file" "d['ccow']['tenant']['failure_domain']")"
    assert_eq "0" "$fd" "single-node failure_domain must be 0"
}

_check_single_node_agg() {
    local file="$CONF_DIR/single-node/nesetup.json"
    local agg
    agg="$(json_query "$file" "d['auditd']['is_aggregator']")"
    assert_eq "1" "$agg" "single-node is_aggregator must be 1"
}

_check_hp_journal() {
    local file="$CONF_DIR/high-performance/nesetup.json"
    local nf; nf="$(_to_native_path "$file")"
    local missing
    missing="$($_PYTHON -c "
import json
with open(r'''$nf''') as f: d = json.load(f)
count = sum(1 for dev in d['rtrd']['devices'] if 'journal' not in dev)
print(count)
")"
    assert_eq "0" "$missing" "all high-performance devices must have journal field"
}

_check_lot_wal() {
    local file="$CONF_DIR/large-object-throughput/nesetup.json"
    local nf; nf="$(_to_native_path "$file")"
    local missing
    missing="$($_PYTHON -c "
import json
with open(r'''$nf''') as f: d = json.load(f)
count = sum(1 for dev in d['rtrd']['devices'] if dev.get('wal_disabled') != 1)
print(count)
")"
    assert_eq "0" "$missing" "all large-object-throughput devices must have wal_disabled=1"
}

_check_cross_transport() {
    local bad=0
    for profile_dir in "${PROFILES[@]}"; do
        local name t
        name="$(basename "$profile_dir")"
        t="$(json_query "$profile_dir/nesetup.json" "d['ccowd']['transport']")"
        if ! printf '%s' "$t" | grep -q "rtrd"; then
            _fail "profile $name uses unexpected transport: $t"
            bad=1
        fi
    done
    [ "$bad" -eq 0 ] && _pass "all profiles use rtrd transport"
}

_check_cross_fd() {
    local bad=0
    for profile_dir in "${PROFILES[@]}"; do
        local name fd
        name="$(basename "$profile_dir")"
        fd="$(json_query "$profile_dir/nesetup.json" "d['ccow']['tenant']['failure_domain']")"
        case "$fd" in
            0|1) ;;
            *)
                _fail "profile $name has unexpected failure_domain: $fd"
                bad=1
                ;;
        esac
    done
    [ "$bad" -eq 0 ] && _pass "all profiles have failure_domain in {0, 1}"
}

_check_cross_agg() {
    local bad=0
    for profile_dir in "${PROFILES[@]}"; do
        local name agg
        name="$(basename "$profile_dir")"
        agg="$(json_query "$profile_dir/nesetup.json" "d['auditd']['is_aggregator']")"
        case "$agg" in
            0|1) ;;
            *)
                _fail "profile $name has unexpected is_aggregator: $agg"
                bad=1
                ;;
        esac
    done
    [ "$bad" -eq 0 ] && _pass "all profiles have is_aggregator in {0, 1}"
}

_check_missing_key_detection() {
    local tmpdir
    tmpdir="$(test_make_tmpdir)"
    local bad_json="$tmpdir/bad.json"
    printf '{"ccow":{},"ccowd":{},"rtrd":{"devices":[]}}' > "$bad_json"
    if json_has_key "$bad_json" "auditd"; then
        _fail "json_has_key did not detect missing 'auditd' key"
    else
        _pass "correctly detected missing 'auditd' key"
    fi
}

_check_invalid_json() {
    local tmpdir
    tmpdir="$(test_make_tmpdir)"
    local bad_json="$tmpdir/bad.json"
    printf '{invalid json' > "$bad_json"
    if $_PYTHON -m json.tool < "$bad_json" >/dev/null 2>&1; then
        _fail "invalid JSON was accepted"
    else
        _pass "correctly rejected invalid JSON"
    fi
}

_check_dup_device() {
    local tmpdir
    tmpdir="$(test_make_tmpdir)"
    local dup_json="$tmpdir/dup.json"
    cat > "$dup_json" <<'EOJSON'
{
    "rtrd": {
        "devices": [
            {"name": "disk1", "device": "/dev/sdb"},
            {"name": "disk2", "device": "/dev/sdb"}
        ]
    }
}
EOJSON
    local ndup; ndup="$(_to_native_path "$dup_json")"
    local dups
    dups="$($_PYTHON -c "
import json
with open(r'''$ndup''') as f: d = json.load(f)
paths = [dev['device'] for dev in d['rtrd']['devices']]
dups = [p for p in paths if paths.count(p) > 1]
if dups: print(','.join(set(dups)))
")"
    if [ -n "$dups" ]; then
        _pass "correctly detected duplicate device path: $dups"
    else
        _fail "duplicate device paths were not detected"
    fi
}

# ──────────────────────────────────────────────────────────────
# Test execution
# ──────────────────────────────────────────────────────────────
begin_suite "conf-validate"

for profile_dir in "${PROFILES[@]}"; do
    name="$(basename "$profile_dir")"
    run_test "profile:$name has README" _check_readme "$profile_dir" "$name"
done

for profile_dir in "${PROFILES[@]}"; do
    name="$(basename "$profile_dir")"
    run_test "json-valid:$name" _check_json_valid "$profile_dir" "$name"
done

for profile_dir in "${PROFILES[@]}"; do
    name="$(basename "$profile_dir")"
    run_test "required-keys:$name" _check_required_keys "$profile_dir" "$name"
done

for profile_dir in "${PROFILES[@]}"; do
    name="$(basename "$profile_dir")"
    run_test "nested-keys:$name" _check_nested_keys "$profile_dir" "$name"
done

for profile_dir in "${PROFILES[@]}"; do
    name="$(basename "$profile_dir")"
    [ "$name" = "gateway" ] && continue
    run_test "devices:$name" _check_devices "$profile_dir" "$name"
done

if [ -f "$CONF_DIR/gateway/nesetup.json" ]; then
    run_test "gateway:empty-devices" _check_gateway_empty_devices
fi

if [ -f "$CONF_DIR/single-node/nesetup.json" ]; then
    run_test "single-node:failure_domain=0" _check_single_node_fd
    run_test "single-node:is_aggregator=1" _check_single_node_agg
fi

if [ -f "$CONF_DIR/high-performance/nesetup.json" ]; then
    run_test "high-performance:has-journal" _check_hp_journal
fi

if [ -f "$CONF_DIR/large-object-throughput/nesetup.json" ]; then
    run_test "large-object-throughput:wal_disabled" _check_lot_wal
fi

run_test "cross-profile:transport-consistency" _check_cross_transport
run_test "cross-profile:failure_domain-values" _check_cross_fd
run_test "cross-profile:is_aggregator-values" _check_cross_agg
run_test "negative:missing-key-detection" _check_missing_key_detection
run_test "negative:invalid-json-detection" _check_invalid_json
run_test "negative:duplicate-device-detection" _check_dup_device

end_suite
