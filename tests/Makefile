# NexentaEdge DevOps Test Framework
#
# Run health check regression tests and diagnostics.
# Requires: bash 4+, bats-core (run 'make install-bats' first)

BATS := vendor/bats-core/bin/bats
TESTS_ROOT := $(shell pwd)
REPO_ROOT := $(shell dirname $(TESTS_ROOT))

.PHONY: all unit integration scenarios diagnostics clean help install-bats check \
        trace-nfs trace-iscsi trace-s3 trace-all race-detect verbose report \
        post-install post-upgrade failover rapid-check multi-node

# ============================================================
# Test targets
# ============================================================

all: unit integration scenarios
	@echo ""
	@echo "All tests completed."

unit: check
	@echo "=== Unit Tests ==="
	@$(BATS) --tap unit/

integration: check
	@echo "=== Integration Tests ==="
	@$(BATS) --tap integration/

scenarios: post-install post-upgrade failover rapid-check multi-node
	@echo ""
	@echo "All scenario suites completed."

post-install: check
	@echo "  --- Scenario: post-install ---"
	@$(BATS) --tap scenarios/post-install/

post-upgrade: check
	@echo "  --- Scenario: post-upgrade ---"
	@$(BATS) --tap scenarios/post-upgrade/

failover: check
	@echo "  --- Scenario: failover ---"
	@$(BATS) --tap scenarios/failover/

rapid-check: check
	@echo "  --- Scenario: rapid-check ---"
	@$(BATS) --tap scenarios/rapid-check/

multi-node: check
	@echo "  --- Scenario: multi-node ---"
	@$(BATS) --tap scenarios/multi-node/

# ============================================================
# Single test / pattern matching
# ============================================================

# Run a specific test file: make test FILE=unit/test-nfs-check.bats
test: check
	@$(BATS) --tap $(FILE)

# Run tests matching a pattern: make grep PATTERN="first invocation"
grep: check
	@$(BATS) --tap --filter "$(PATTERN)" unit/ integration/ scenarios/

# Verbose output for all tests
verbose: check
	@$(BATS) --tap --verbose unit/ integration/ scenarios/

# ============================================================
# Diagnostic tools
# ============================================================

trace-nfs:
	@bash diagnostics/state-trace.sh nfs all-healthy

trace-iscsi:
	@bash diagnostics/state-trace.sh iscsi all-healthy

trace-s3:
	@bash diagnostics/state-trace.sh s3 all-healthy

trace-all: trace-nfs trace-iscsi trace-s3

race-detect:
	@bash diagnostics/race-detector.sh nfs 50

report: check
	@bash diagnostics/report.sh text

report-tap: check
	@bash diagnostics/report.sh tap

# ============================================================
# Setup and maintenance
# ============================================================

install-bats:
	@if [ ! -d "vendor/bats-core" ]; then \
		echo "Cloning bats-core..."; \
		git clone --depth 1 https://github.com/bats-core/bats-core.git vendor/bats-core; \
		echo "bats-core installed."; \
	else \
		echo "bats-core already installed."; \
	fi

check:
	@command -v bash >/dev/null 2>&1 || { echo "ERROR: bash not found"; exit 1; }
	@if [ ! -x "$(BATS)" ]; then \
		echo "ERROR: bats not found. Run: make install-bats"; exit 1; \
	fi
	@bash -c '[[ $${BASH_VERSINFO[0]} -ge 4 ]]' || \
		{ echo "ERROR: bash 4+ required (have $$(bash --version | head -1))"; exit 1; }

clean:
	@rm -rf /tmp/nedge-test-sandbox.*
	@rm -rf reports/
	@rm -f trace-*.log
	@echo "Cleaned test artifacts."

help:
	@echo "NexentaEdge DevOps Test Framework"
	@echo "================================="
	@echo ""
	@echo "Setup:"
	@echo "  install-bats    Install bats-core (one-time)"
	@echo "  check           Verify prerequisites"
	@echo ""
	@echo "Test targets:"
	@echo "  all             Run all tests (unit + integration + scenarios)"
	@echo "  unit            Unit tests only"
	@echo "  integration     Integration tests only"
	@echo "  scenarios       All scenario suites"
	@echo "  post-install    Post-installation scenarios"
	@echo "  post-upgrade    Post-upgrade scenarios"
	@echo "  failover        Failover transition scenarios"
	@echo "  rapid-check     Rapid consecutive check scenarios"
	@echo "  multi-node      Multi-node isolation scenarios"
	@echo ""
	@echo "Specific tests:"
	@echo "  test FILE=x     Run a specific .bats file"
	@echo "  grep PATTERN=x  Run tests matching pattern"
	@echo "  verbose         All tests with verbose output"
	@echo ""
	@echo "Diagnostics:"
	@echo "  trace-nfs       Run NFS health check with full tracing"
	@echo "  trace-iscsi     Run iSCSI health check with full tracing"
	@echo "  trace-s3        Run S3 health check with full tracing"
	@echo "  trace-all       Trace all three health checks"
	@echo "  race-detect     Run race condition detector (50 iterations)"
	@echo "  report          Generate text test report"
	@echo "  report-tap      Generate TAP format report"
	@echo ""
	@echo "Maintenance:"
	@echo "  clean           Remove test artifacts and sandbox residuals"
	@echo ""
	@echo "Examples:"
	@echo "  make install-bats && make all"
	@echo "  make test FILE=unit/test-cache-race-condition.bats"
	@echo "  make grep PATTERN='BUG-REPRO'"
	@echo "  make trace-all"
