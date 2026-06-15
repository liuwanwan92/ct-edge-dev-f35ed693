#!/usr/bin/env bash
# test_helper.bash - Unified bats test setup/teardown
#
# Loaded by every .bats test file via: load '../lib/test_helper'
# (or appropriate relative path)

# Resolve paths
TESTS_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
REPO_ROOT="$(cd "${TESTS_ROOT}/.." && pwd)"
LIB_ROOT="${TESTS_ROOT}/lib"
MOCK_ROOT="${TESTS_ROOT}/mocks"
FIXTURE_ROOT="${TESTS_ROOT}/fixtures"
SVC_CHECK_DIR="${REPO_ROOT}/prometheus/svc-checks"
SCRIPTS_DIR="${REPO_ROOT}/scripts"

# Export paths needed by child processes (mock shims, scenario handlers)
export TESTS_ROOT REPO_ROOT LIB_ROOT MOCK_ROOT FIXTURE_ROOT SVC_CHECK_DIR SCRIPTS_DIR

# Load all framework libraries
load "${LIB_ROOT}/sandbox"
load "${LIB_ROOT}/trace"
load "${LIB_ROOT}/mock"
load "${LIB_ROOT}/assert"
load "${LIB_ROOT}/http"
load "${LIB_ROOT}/services"

# Standard bats setup: runs before every @test
setup() {
    sandbox_create
    mock_reset_all
    trace_init

    # Make ps always return "not found" to avoid 20-second timeout loops
    # in the production NFS check script (showmount/df timeout detection)
    mock_ps_fast_fail

    # Speed up the scripts: mock sleep to be instant
    mock_set_response sleep "" 0

    # Default hostname for consistent metric labels
    mock_set_response hostname "testhost"

    # Provide default egrep/grep mocks (passthrough to real commands)
    # These are already handled by fallthrough in the shim
}

# Standard bats teardown: runs after every @test
teardown() {
    # Dump trace on test failure for debugging
    if [[ "${BATS_TEST_COMPLETED:-}" != "1" ]]; then
        echo "--- TRACE LOG (test failed) ---" >&3
        trace_dump 3
        echo "--- END TRACE ---" >&3
    fi
    sandbox_destroy
}
