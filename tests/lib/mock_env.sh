#!/usr/bin/env bash
# tests/lib/mock_env.sh — Mock environment for simulating tool presence/absence
# Creates fake binaries in a tempdir, injects them into $PATH

_MOCK_ORIGINAL_PATH=""
_MOCK_DIR=""
MOCK_LOG_DIR=""

# List of tools to create mocks for
_MOCK_TOOLS=(docker curl iscsi-ls showmount rpcinfo openssl df mount which)

# ── setup_mock_env ────────────────────────────────────────
setup_mock_env() {
    _MOCK_ORIGINAL_PATH="$PATH"
    _MOCK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mock_env.XXXXXX")
    MOCK_LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mock_logs.XXXXXX")

    mkdir -p "$_MOCK_DIR/bin"

    for tool in "${_MOCK_TOOLS[@]}"; do
        _create_mock "$tool"
    done

    export PATH="$_MOCK_DIR/bin:$PATH"
}

# ── teardown_mock_env ─────────────────────────────────────
teardown_mock_env() {
    export PATH="$_MOCK_ORIGINAL_PATH"
    _MOCK_ORIGINAL_PATH=""
    [[ -n "$_MOCK_DIR" ]] && rm -rf "$_MOCK_DIR"
    [[ -n "$MOCK_LOG_DIR" ]] && rm -rf "$MOCK_LOG_DIR"
    _MOCK_DIR=""
    MOCK_LOG_DIR=""
}

# ── _create_mock <tool> ──────────────────────────────────
_create_mock() {
    local tool="$1"
    local safe_name
    safe_name=$(echo "$tool" | tr '-' '_')
    local mock_file="$_MOCK_DIR/bin/$tool"

    cat > "$mock_file" << 'MOCKEOF'
#!/usr/bin/env bash
# Auto-generated mock for: __TOOL__
_TOOL="__TOOL__"
_SAFE="__SAFE__"
_LOG_DIR="__LOG_DIR__"

# Log the call
echo "$_TOOL $*" >> "$_LOG_DIR/${_SAFE}.log"

# Check for custom behavior
_exit_var="MOCK_${_SAFE}_EXIT"
_out_var="MOCK_${_SAFE}_OUTPUT"

_exit_code="${!_exit_var:-0}"
_output="${!_out_var:-}"

if [[ -n "$_output" ]]; then
    echo "$_output"
fi

# Special cases: some tools need default output to be useful
case "$_TOOL" in
    which)
        # which checks if a tool exists in the mock bin directory
        _which_target="$1"
        _which_safe=$(echo "$_which_target" | tr '-' '_')
        _mock_bin="$(dirname "$0")"
        if [[ -x "$_mock_bin/$_which_target" ]]; then
            echo "$_mock_bin/$_which_target"
            exit 0
        else
            exit 1
        fi
        ;;
    mount)
        if [[ -z "${!_out_var+x}" ]]; then
            # Default: return a fake NFS mount entry
            echo "10.16.110.215:/export/nfssvc1 on /mnt/nfssvc1 type nfs (rw,addr=10.16.110.215)"
        fi
        ;;
    df)
        if [[ -z "${!_out_var+x}" ]]; then
            echo "Filesystem     1K-blocks    Used Available Use% Mounted on"
            echo "10.16.110.215:/export/nfssvc1  1048576  524288  524288  50% /mnt/nfssvc1"
        fi
        ;;
    showmount)
        if [[ -z "${!_out_var+x}" ]]; then
            echo "Export list for 10.16.110.215:"
            echo "/export/nfssvc1 *"
        fi
        ;;
    rpcinfo)
        if [[ -z "${!_out_var+x}" ]]; then
            echo "   program version netid     address          service    owner"
            echo "    100003    3    tcp      0.0.0.0.8.1      nfs        superuser"
            echo "    100003    3    udp      0.0.0.0.8.1      nfs        superuser  ready"
        fi
        ;;
    iscsi-ls)
        if [[ -z "${!_out_var+x}" ]]; then
            echo "Target: iqn.2018-01.com.nexenta:iscsi"
            echo "Lun:0    Type:0    Size:1073741824"
            echo "Lun:1    Type:0    Size:1073741824"
        fi
        ;;
    openssl)
        if [[ -z "${!_out_var+x}" ]]; then
            # Return a fake base64-encoded HMAC
            echo -n "dGVzdHNpZw=="
        fi
        ;;
    curl)
        if [[ -z "${!_out_var+x}" ]]; then
            echo "HTTP/1.1 200 OK"
            echo "Content-Type: application/xml"
        fi
        ;;
    docker)
        if [[ -z "${!_out_var+x}" ]]; then
            # Default: pretend success
            if [[ "$*" == *"inspect"* ]]; then
                echo "172.17.0.2"
            elif [[ "$*" == *"ps"* ]]; then
                echo "CONTAINER ID"
            fi
        fi
        ;;
esac

exit "$_exit_code"
MOCKEOF

    # Replace placeholders
    sed -i -e "s/__TOOL__/$tool/g" -e "s/__SAFE__/$safe_name/g" -e "s|__LOG_DIR__|$MOCK_LOG_DIR|g" "$mock_file"
    chmod +x "$mock_file"
}

# ── set_mock_behavior <tool> <exit_code> [output] ────────
set_mock_behavior() {
    local tool="$1"
    local exit_code="$2"
    local output="${3:-}"
    local safe_name
    safe_name=$(echo "$tool" | tr '-' '_')

    export "MOCK_${safe_name}_EXIT=$exit_code"
    export "MOCK_${safe_name}_OUTPUT=$output"
}

# ── remove_mock <tool> ───────────────────────────────────
# Removes a mock binary from the mock bin dir, simulating "tool not installed"
remove_mock() {
    local tool="$1"
    local mock_file="$_MOCK_DIR/bin/$tool"
    [[ -f "$mock_file" ]] && rm -f "$mock_file"
}

# ── restore_mock <tool> ──────────────────────────────────
restore_mock() {
    local tool="$1"
    _create_mock "$tool"
    local safe_name
    safe_name=$(echo "$tool" | tr '-' '_')
    export "MOCK_${safe_name}_EXIT=0"
    export "MOCK_${safe_name}_OUTPUT="
}

# ── reset_all_mocks ──────────────────────────────────────
reset_all_mocks() {
    for tool in "${_MOCK_TOOLS[@]}"; do
        local safe_name
        safe_name=$(echo "$tool" | tr '-' '_')
        export "MOCK_${safe_name}_EXIT=0"
        export "MOCK_${safe_name}_OUTPUT="
        # Recreate if removed
        if [[ ! -f "$_MOCK_DIR/bin/$tool" ]]; then
            _create_mock "$tool"
        fi
    done
}
