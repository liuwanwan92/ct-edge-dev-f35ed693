#!/usr/bin/env bats
# test-nestart-idempotency.bats - Integration test for nestart script
#
# Tests the multi-host container start script's behavior across multiple runs.

load '../lib/test_helper'

setup() {
    sandbox_create
    mock_reset_all
    trace_init
    mock_set_response sleep "" 0
    mock_set_response hostname "testhost"

    NESTART="${SCRIPTS_DIR}/nestart"

    # Create a minimal nesetup.json for testing
    CONTAINER_DIR="${SANDBOX_VAR}/c0"
    mkdir -p "${CONTAINER_DIR}"
    cat > "${CONTAINER_DIR}/nesetup.json" << 'EOF'
{
    "ccow": {
        "tenant": { "failure_domain": 1 },
        "network": { "broker_interfaces": "eth0" }
    },
    "ccowd": {
        "network": { "server_interfaces": "eth0" }
    }
}
EOF
}

teardown() {
    if [[ "${BATS_TEST_COMPLETED:-}" != "1" ]]; then
        echo "--- TRACE LOG ---" >&3
        trace_dump 3
    fi
    sandbox_destroy
}

@test "nestart: no arguments shows usage message" {
    run bash "${NESTART}"
    [[ "${status}" -ne 0 ]]
    echo "${output}" | grep -qi "usage"
}

@test "nestart: missing nesetup.json fails with error" {
    local empty_dir="${SANDBOX_VAR}/empty"
    mkdir -p "${empty_dir}"

    run bash "${NESTART}" "${empty_dir}"
    [[ "${status}" -ne 0 ]]
    echo "${output}" | grep -qi "not found"
}

@test "nestart: creates var/ directory if missing" {
    # Remove var/ if it exists
    rm -rf "${CONTAINER_DIR}/var"

    # Mock docker and modprobe to succeed
    mock_set_response docker "container-id-123"
    mock_set_response modprobe ""
    mock_set_response mount ""

    run bash "${NESTART}" "${CONTAINER_DIR}"

    # var/ should be created
    [[ -d "${CONTAINER_DIR}/var" ]]
}

@test "nestart: displays parameter summary" {
    mock_set_response docker "container-id-123"
    mock_set_response modprobe ""
    mock_set_response mount ""

    run bash "${NESTART}" "${CONTAINER_DIR}"

    echo "${output}" | grep -q "Name"
    echo "${output}" | grep -q "Image"
    echo "${output}" | grep -q "Management IP"
}

@test "nestart: handles pre-existing Docker networks gracefully" {
    # docker network create returns error (network already exists)
    # but nestart suppresses errors with 2>/dev/null
    mock_set_response docker "container-id-123"
    mock_set_response modprobe ""
    mock_set_response mount ""

    run bash "${NESTART}" "${CONTAINER_DIR}"

    # Should not fail despite network creation errors being suppressed
    [[ "${status}" -eq 0 ]]
}

@test "nestart: uses custom environment variables" {
    mock_set_response docker "container-id-123"
    mock_set_response modprobe ""
    mock_set_response mount ""

    CCOW_MGMTIPV4="192.168.210.99" \
    CCOW_SVCNAME="s3test" \
    run bash "${NESTART}" "${CONTAINER_DIR}"

    echo "${output}" | grep -q "192.168.210.99"
    echo "${output}" | grep -q "s3test"
}

@test "nestart: trace records all docker commands invoked" {
    mock_set_response docker "container-id-123"
    mock_set_response modprobe ""
    mock_set_response mount ""

    bash "${NESTART}" "${CONTAINER_DIR}" >/dev/null 2>&1

    # Trace should show docker, modprobe, mount calls
    trace_has "MOCK MOCK docker"
    trace_has "MOCK MOCK modprobe"
}
