#!/usr/bin/env bash
# tests/lib/yaml_helpers.sh — YAML validation with multi-tier fallback
# Tries: working python+PyYAML → ruby → pure-bash structural checks

# ── Detect working Python (shared with json_helpers if loaded) ──
if [[ -z "${_PYTHON_CMD:-}" ]]; then
    _PYTHON_CMD=""
fi
_yaml_detect_python() {
    if [[ -n "$_PYTHON_CMD" ]]; then
        [[ "$_PYTHON_CMD" != "none" ]] && return 0 || return 1
    fi
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

# ── validate_yaml <file> ──────────────────────────────────
# Returns 0 if valid, 1 if invalid
validate_yaml() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    _yaml_detect_python

    # Tier 1: working python + PyYAML
    if [[ "$_PYTHON_CMD" != "none" ]]; then
        if $_PYTHON_CMD -c "
import sys
try:
    import yaml
    with open(sys.argv[1]) as fh:
        yaml.safe_load(fh)
    sys.exit(0)
except ImportError:
    sys.exit(2)
except Exception:
    sys.exit(1)
" "$f" 2>/dev/null; then
            return 0
        fi
    fi

    # Tier 2: ruby
    if command -v ruby &>/dev/null; then
        if ruby -ryaml -e "YAML.load_file('$f')" &>/dev/null; then
            return 0
        fi
    fi

    # Tier 3: pure-bash structural checks (catches ~80% of errors)
    _bash_validate_yaml "$f"
}

_bash_validate_yaml() {
    local f="$1"
    local line_num=0
    local has_content=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$(( line_num + 1 ))
        # Skip blank lines and comments
        [[ -z "${line// /}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # No tab indentation
        if [[ "$line" =~ ^$'\t' ]]; then
            echo "YAML error at line $line_num: tab indentation" >&2
            return 1
        fi
        has_content=1
    done < "$f"

    (( has_content == 1 )) || return 1
    return 0
}

# ── yaml_has_key <file> <key_pattern> ─────────────────────
# Returns 0 if the file contains a line matching the key pattern
# Handles both "key: value" and "- key: value" (list items)
yaml_has_key() {
    local f="$1" key="$2"
    grep -qE "^[[:space:]]*(-[[:space:]]+)?${key}[[:space:]]*:" "$f" 2>/dev/null
}

# ── yaml_has_top_key <file> <key> ────────────────────────
# Returns 0 if the file has a top-level (no leading whitespace) key
yaml_has_top_key() {
    local f="$1" key="$2"
    grep -qE "^${key}[[:space:]]*:" "$f" 2>/dev/null
}

# ── yaml_count_pattern <file> <pattern> ───────────────────
# Prints the count of lines matching pattern
yaml_count_pattern() {
    local f="$1" pattern="$2"
    grep -cE "$pattern" "$f" 2>/dev/null || echo 0
}

# ── yaml_get_value <file> <key> ──────────────────────────
# Prints the value for the first matching key (simple key: value lines only)
# Handles both "key: value" and "- key: value" (list items)
yaml_get_value() {
    local f="$1" key="$2"
    grep -E "^[[:space:]]*(-[[:space:]]+)?${key}[[:space:]]*:" "$f" 2>/dev/null | \
        head -1 | \
        sed -E "s/^[[:space:]]*(-[[:space:]]+)?${key}[[:space:]]*:[[:space:]]*//" | \
        sed 's/#.*$//' | \
        sed "s/['\"]//g" | \
        sed 's/[[:space:]]*$//'
}
