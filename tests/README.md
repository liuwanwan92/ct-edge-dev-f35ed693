# NexentaEdge Health Check Regression Test Framework

## Overview

This test framework reproduces and documents the flaky behavior in NexentaEdge's Prometheus health check scripts (`nedge-prom-nfs-check`, `nedge-prom-iscsi-check`, `nedge-prom-s3-check`).

**The problem**: After installation or upgrades, consecutive health checks return inconsistent results - the first reports errors, the second recovers. State from previous runs pollutes subsequent runs.

**Root cause**: All three scripts share an identical caching architecture that serves stale results while refreshing in the background:

```
Scrape 1: no cache → returns EMPTY, starts background write
Scrape 2: returns STALE data from scrape 1, starts new background write
Scrape 3: returns STALE data from scrape 2, ...
```

This framework does **not modify** the production scripts. Instead, it provides:
- Isolated sandbox execution (patched `/tmp/` paths)
- Mock system commands (mount, showmount, df, curl, etc.)
- Structured execution tracing
- Automated regression tests via bats-core

## Quick Start

```bash
cd tests/

# One-time setup
make install-bats

# Verify prerequisites
make check

# Run all tests
make all

# Run specific test categories
make unit            # Unit tests
make integration     # Integration tests
make scenarios       # Scenario test suites
```

## Directory Structure

```
tests/
├── lib/                    # Framework libraries
│   ├── test_helper.bash    # bats setup/teardown
│   ├── sandbox.bash        # /tmp state isolation
│   ├── mock.bash           # Command interception (PATH)
│   ├── trace.bash          # Execution tracing
│   ├── assert.bash         # Prometheus metric assertions
│   ├── http.bash           # HTTP request simulation
│   ├── services.bash       # SERVICE array override
│   └── multinode.bash      # Multi-node simulation
├── mocks/scenarios/        # Mock response profiles
│   ├── nfs/                # NFS scenarios (6)
│   ├── iscsi/              # iSCSI scenarios (4)
│   ├── s3/                 # S3 scenarios (4)
│   ├── docker/             # Docker scenarios (2)
│   └── transitions/        # Service transition scenarios (2)
├── fixtures/               # Cache file samples + utilities
│   └── sample-cache/       # Pre-built .prom files
├── unit/                   # Unit tests (6 files)
├── integration/            # Integration tests (5 files)
├── scenarios/              # Scenario test suites (13 files)
│   ├── post-install/       # Fresh install scenarios
│   ├── post-upgrade/       # Upgrade scenarios
│   ├── failover/           # VIP transition scenarios
│   ├── rapid-check/        # Consecutive check scenarios
│   └── multi-node/         # Multi-node isolation
├── diagnostics/            # Diagnostic tools
│   ├── state-trace.sh      # Full execution tracer
│   ├── timeline.sh         # Trace log visualizer
│   ├── race-detector.sh    # Race condition detector
│   └── report.sh           # Test report generator
└── Makefile                # Build entry point
```

## Test Categories

### Unit Tests
Individual function testing with controlled mocks.

| File | Tests |
|------|-------|
| `test-nfs-check.bats` | NFS check states (1/0/-1/-2/-3) |
| `test-iscsi-check.bats` | iSCSI check states (1/0/-1) |
| `test-s3-check.bats` | S3 check states (1/0/-1/-2) |
| `test-http-parsing.bats` | HTTP request handling |
| `test-cache-race-condition.bats` | **Bug reproduction** (key tests) |
| `test-cache-file-integrity.bats` | Cache edge cases |

### Bug Reproduction Tests (`test-cache-race-condition.bats`)

These tests **PASS when the bugs exist** (current state). They prove the flaky behavior is reproducible. When the production scripts are fixed, these tests will **FAIL** - alerting that expectations need updating.

### Integration Tests
End-to-end flows testing consecutive checks, install/upgrade sequences, and script idempotency.

### Scenario Tests
Named operational scenarios: post-install, post-upgrade, failover, rapid-check, multi-node.

## Diagnostics

```bash
# Full execution trace (5 consecutive checks with detailed logging)
make trace-nfs
make trace-all

# Race condition detector
make race-detect

# Generate test report
make report
```

### Trace Format

```
TIMESTAMP LEVEL COMPONENT #SEQNUM EVENT DETAILS
1618456789.123 INFO CHECK #00001 START service=nfs run=1
1618456789.124 DEBUG CACHE #00002 PRE_STATE service=nfs status=MISSING
1618456789.234 MOCK MOCK mount ARGS=[-l -t nfs,nfs4,nfs2,nfs3]
1618456789.345 INFO CHECK #00003 END service=nfs run=1 result=EMPTY
```

## How It Works

### Sandbox Isolation
Production scripts hardcode `/tmp/nedge-prom-*.last`. The sandbox copies scripts to a temp location and uses `sed` to replace the hardcoded path:

```bash
sed "s|/tmp/nedge-prom-|${SANDBOX_TMP}/nedge-prom-|g" script > patched
```

### Mock System
PATH-prepended shim scripts intercept external commands. Each shim:
1. Logs the call to the trace file
2. Returns mock response (if configured)
3. Falls through to the real command (if available)

### HTTP Simulation
Bypasses socat entirely. Pipes HTTP requests directly to the script's stdin:

```bash
printf 'GET /metrics HTTP/1.0\r\n\r\n' | sandbox_exec script
```

## Prerequisites

- **bash 4+** (for `declare -A` associative arrays)
- **bats-core** (run `make install-bats`)
- Linux (for full sandbox support)

## After Production Scripts Are Fixed

When the `*_last_result()` functions are fixed to use atomic writes, proper locking, and synchronous execution:

1. `test-cache-race-condition.bats` will **FAIL** - update these to expect correct behavior
2. All other tests continue to **PASS**
3. Add new regression tests to prevent re-introducing the bugs
