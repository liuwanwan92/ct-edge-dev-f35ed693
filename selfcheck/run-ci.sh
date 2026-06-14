#!/usr/bin/env bash
#
# selfcheck/run-ci.sh -- CI entry point. Runs the static/mock layer with
# --strict, then the bats suite. Needs no docker/root; intended for a Linux CI
# runner (jq makes the JSON checks fast). The live layer (--live) is a separate,
# host-only, manually-triggered job and is never run here.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # repo root (win32-safe via BASH_SOURCE)
chmod +x selfcheck/mocks/* 2>/dev/null || true   # ensure mock probes are executable on the runner

echo "== selfcheck: static/mock layer (--strict --target all) =="
bash selfcheck/selfcheck.sh --strict --target all
rc=$?

echo
echo "== selfcheck: bats unit suite =="
if command -v bats >/dev/null 2>&1; then
	bats selfcheck/tests
	brc=$?
else
	echo "run-ci: bats not found; skipping unit suite (install bats-core)" >&2
	brc=0
fi

# Exit with the worse of the two results.
[ "$rc" -gt "$brc" ] && exit "$rc" || exit "$brc"
