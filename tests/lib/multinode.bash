#!/usr/bin/env bash
# multinode.bash - Multi-node simulation helpers
#
# Each simulated "node" gets:
#   - Its own sandbox subdirectory (isolated cache)
#   - A hostname override
#   - Independent mock state
#
# This allows testing that state from one node does not leak to another.

declare -A _MULTINODE_DIRS

# Create multiple simulated nodes
# Usage: multinode_create "node1" "node2" ...
multinode_create() {
    local node
    for node in "$@"; do
        local node_dir="${SANDBOX_BASE}/nodes/${node}"
        mkdir -p "${node_dir}/tmp" "${node_dir}/var" "${node_dir}/bin"
        _MULTINODE_DIRS["${node}"]="${node_dir}"
    done
}

# Execute a command in the context of a specific node
# The node's tmp/ dir is used as the cache location
# Usage: node_exec <node_name> <command> [args...]
node_exec() {
    local node="$1"; shift
    local node_dir="${_MULTINODE_DIRS[${node}]}"
    if [[ -z "${node_dir}" ]]; then
        echo "ERROR: node '${node}' not found" >&2
        return 1
    fi

    # Temporarily override sandbox paths
    local saved_tmp="${SANDBOX_TMP}"
    local saved_var="${SANDBOX_VAR}"
    local saved_bin="${SANDBOX_BIN}"
    local saved_hostname_resp

    SANDBOX_TMP="${node_dir}/tmp"
    SANDBOX_VAR="${node_dir}/var"
    SANDBOX_BIN="${node_dir}/bin"
    NEDGE_SANDBOX_TMP="${SANDBOX_TMP}"
    NEDGE_SANDBOX_VAR="${SANDBOX_VAR}"
    NEDGE_SANDBOX_BIN="${SANDBOX_BIN}"

    # Override hostname for this node
    saved_hostname_resp="${MOCK_RESPONSE_HOSTNAME:-}"
    MOCK_RESPONSE_HOSTNAME="${node}"

    # Execute the command
    "$@"
    local rc=$?

    # Restore
    SANDBOX_TMP="${saved_tmp}"
    SANDBOX_VAR="${saved_var}"
    SANDBOX_BIN="${saved_bin}"
    NEDGE_SANDBOX_TMP="${SANDBOX_TMP}"
    NEDGE_SANDBOX_VAR="${SANDBOX_VAR}"
    NEDGE_SANDBOX_BIN="${SANDBOX_BIN}"
    MOCK_RESPONSE_HOSTNAME="${saved_hostname_resp}"

    return ${rc}
}

# Inject cache for a specific node
# Usage: node_inject_cache <node_name> <service> <content>
node_inject_cache() {
    local node="$1" service="$2" content="$3"
    node_exec "${node}" sandbox_inject_cache "${service}" "${content}"
}

# Read cache for a specific node
# Usage: node_read_cache <node_name> <service>
node_read_cache() {
    local node="$1" service="$2"
    node_exec "${node}" sandbox_read_cache "${service}"
}

# Check if cache exists for a specific node
# Usage: node_cache_exists <node_name> <service>
node_cache_exists() {
    local node="$1" service="$2"
    node_exec "${node}" sandbox_cache_exists "${service}"
}

# List all nodes
# Usage: multinode_list
multinode_list() {
    echo "${!_MULTINODE_DIRS[@]}" | tr ' ' '\n' | sort
}

# Get the sandbox directory for a specific node
# Usage: multinode_get_dir <node_name>
multinode_get_dir() {
    local node="$1"
    echo "${_MULTINODE_DIRS[${node}]}"
}
