# selfcheck harness — convenience targets.
# Runs from anywhere: paths are resolved relative to this Makefile's location.
.PHONY: check test lint
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

# Full CI gate: static/mock layer (--strict) + bats suite.
check:
	@bash $(ROOT)/selfcheck/run-ci.sh

# Just the bats unit suite.
test:
	@cd $(ROOT) && bats selfcheck/tests

# Syntax-check every shell script; run shellcheck if available.
lint:
	@cd $(ROOT) && for f in selfcheck/selfcheck.sh selfcheck/run-ci.sh selfcheck/lib/*.sh selfcheck/checks/* selfcheck/mocks/*; do \
		bash -n "$$f" && echo "ok: $$f" || exit 1; \
	done
	@cd $(ROOT) && { command -v shellcheck >/dev/null 2>&1 \
		&& shellcheck -e SC1090,SC1091 selfcheck/lib/*.sh selfcheck/checks/* selfcheck/selfcheck.sh selfcheck/run-ci.sh \
		|| echo "shellcheck not installed; skipped"; }
