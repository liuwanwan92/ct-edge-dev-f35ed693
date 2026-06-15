#!/usr/bin/env bash
# tests/lib/json_helpers.sh — JSON validation with multi-tier fallback
# Tries: working python3 → python → jq → pure-bash bracket matching

# ── Detect working Python ────────────────────────────────
_PYTHON_CMD=""
_detect_python() {
    if [[ -n "$_PYTHON_CMD" ]]; then return 0; fi
    local candidate
    for candidate in python3 python python3.12 python3.11 python3.10; do
        if command -v "$candidate" &>/dev/null && "$candidate" -c "import sys; sys.exit(0)" 2>/dev/null; then
            _PYTHON_CMD="$candidate"
            return 0
        fi
    done
    _PYTHON_CMD="none"
    return 1
}

# ── validate_json <file> ──────────────────────────────────
validate_json() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    _detect_python

    if [[ "$_PYTHON_CMD" != "none" ]]; then
        $_PYTHON_CMD -c "import json,sys; json.load(open(sys.argv[1])); sys.exit(0)" "$f" 2>/dev/null && return 0
    fi

    # Tier 2: jq
    if command -v jq &>/dev/null; then
        jq empty "$f" 2>/dev/null && return 0
    fi

    # Tier 3: pure-bash bracket matching
    _bash_validate_json "$f"
}

_bash_validate_json() {
    local f="$1"
    local content
    content=$(< "$f")
    # Trim leading/trailing whitespace
    content="${content#"${content%%[![:space:]]*}"}"
    content="${content%"${content##*[![:space:]]}"}"
    # Must start with { or [
    if [[ "$content" != "{"* ]] && [[ "$content" != "["* ]]; then
        echo "JSON error: does not start with { or [" >&2
        return 1
    fi
    # Basic bracket balance
    local opens closes
    opens=$(echo "$content" | tr -cd '{[' | wc -c)
    closes=$(echo "$content" | tr -cd '}]' | wc -c)
    if (( opens != closes )); then
        echo "JSON error: unbalanced brackets (open=$opens close=$closes)" >&2
        return 1
    fi
    return 0
}

# ── json_has_key <file> <key> ─────────────────────────────
json_has_key() {
    local f="$1" key="$2"
    _detect_python
    if [[ "$_PYTHON_CMD" != "none" ]]; then
        $_PYTHON_CMD -c "
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
def find_key(obj, key):
    if isinstance(obj, dict):
        if key in obj: return True
        return any(find_key(v, key) for v in obj.values())
    if isinstance(obj, list):
        return any(find_key(v, key) for v in obj)
    return False
sys.exit(0 if find_key(data, sys.argv[2]) else 1)
" "$f" "$key" 2>/dev/null && return 0
    fi
    # Fallback: grep for quoted key
    grep -q "\"${key}\"" "$f" 2>/dev/null
}

# ── json_get_value <file> <key> ───────────────────────────
# Prints the value for the first matching top-level key
json_get_value() {
    local f="$1" key="$2"
    _detect_python
    if [[ "$_PYTHON_CMD" != "none" ]]; then
        $_PYTHON_CMD -c "
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
def find_val(obj, key):
    if isinstance(obj, dict):
        if key in obj: return obj[key]
        for v in obj.values():
            r = find_val(v, key)
            if r is not None: return r
    if isinstance(obj, list):
        for v in obj:
            r = find_val(v, key)
            if r is not None: return r
    return None
v = find_val(data, sys.argv[2])
if v is not None:
    print(v if not isinstance(v, (dict,list)) else json.dumps(v))
    sys.exit(0)
sys.exit(1)
" "$f" "$key" 2>/dev/null && return 0
    fi
    # Fallback: grep-based (fragile)
    grep -oP "\"${key}\"\s*:\s*\"[^\"]*\"" "$f" 2>/dev/null | head -1 | sed -E "s/\"${key}\"\s*:\s*\"(.*)\"/\1/"
}

# ── json_count_pattern <file> <pattern> ───────────────────
json_count_pattern() {
    local f="$1" pattern="$2"
    grep -cE "$pattern" "$f" 2>/dev/null || echo 0
}

# ── json_array_length <file> <key> ────────────────────────
json_array_length() {
    local f="$1" key="$2"
    _detect_python
    if [[ "$_PYTHON_CMD" != "none" ]]; then
        $_PYTHON_CMD -c "
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
def find_val(obj, key):
    if isinstance(obj, dict):
        if key in obj and isinstance(obj[key], list): return len(obj[key])
        for v in obj.values():
            r = find_val(v, key)
            if r is not None: return r
    if isinstance(obj, list):
        for v in obj:
            r = find_val(v, key)
            if r is not None: return r
    return None
v = find_val(data, sys.argv[2])
if v is not None:
    print(v); sys.exit(0)
sys.exit(1)
" "$f" "$key" 2>/dev/null && return 0
    fi
    echo 0; return 1
}
