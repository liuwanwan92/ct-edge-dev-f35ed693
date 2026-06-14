#!/usr/bin/env bash
# selfcheck/tests/helpers.bash -- shared bats setup. `load helpers` in each file.
SC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
REPO="$(cd "$SC/.." && pwd)"
FIX="$SC/fixtures"
ISCSI="$REPO/prometheus/svc-checks/nedge-prom-iscsi-check"
NFSC="$REPO/prometheus/svc-checks/nedge-prom-nfs-check"
S3C="$REPO/prometheus/svc-checks/nedge-prom-s3-check"

# Drive the exporters/oracles deterministically through the mocks.
export SELFCHECK_MOCKS="$SC/mocks"
export PATH="$SC/mocks:$PATH"
chmod +x "$SC"/mocks/* 2>/dev/null || true   # exec bit may be lost on a Windows commit
export SELFCHECK_SETTLE_SLEEP="${SELFCHECK_SETTLE_SLEEP:-0.1}"
export SELFCHECK_SETTLE_TRIES="${SELFCHECK_SETTLE_TRIES:-40}"

# shellcheck source=/dev/null
. "$SC/lib/common.sh"
# shellcheck source=/dev/null
. "$SC/lib/svccheck.sh"

teardown() { svc_cache_clean 2>/dev/null || true; }

# Copy a negative config fixture into a correctly-named profile dir, then run
# check-config against it (check-config keys its ruleset off the dir basename).
run_config_fixture() {  # <fixture-file> <profile-dirname>
	local d="$BATS_TEST_TMPDIR/$2"
	mkdir -p "$d"
	cp "$FIX/configs/missing-items/$1" "$d/nesetup.json"
	run bash "$SC/checks/check-config" --target "$d"
}
