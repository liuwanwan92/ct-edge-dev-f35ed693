# load.bash - sourced by every .bats file via `load load`. Pulls in the harness,
# the state drivers, and the scenario fixtures, and computes paths relative to
# the test/ tree so the suite runs from anywhere. Not executable on its own.

TEST_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
export TEST_ROOT

# REPO_ROOT lets instrument.bash find the production checks; default is the repo
# above test/. Allow override (e.g. when the checkout layout differs).
export REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"

# shellcheck source=/dev/null
source "$TEST_ROOT/lib/harness.bash"
# shellcheck source=/dev/null
source "$TEST_ROOT/fixtures/states.bash"
# shellcheck source=/dev/null
source "$TEST_ROOT/fixtures/scenarios/install.bash"
# shellcheck source=/dev/null
source "$TEST_ROOT/fixtures/scenarios/upgrade.bash"

# All tests in one `bats` invocation share a work root if HARNESS_WORK is already
# exported (run.sh does this so evidence lands in a single inspectable dir);
# otherwise each gets a throwaway mktemp dir.
harness_setup

# warm_then_read <svc> -> the value of a scrape taken AFTER one warming scrape.
# The first scrape on an empty cache returns MISSING, but its synchronous export
# refreshes the cache; the second scrape then returns the freshly computed value.
# This is the standard way the *_states tests read a single settled state.
warm_then_read() {
	run_scrape warm "$1" >/dev/null
	run_scrape read "$1"
}

# harness.bash/instrument.bash run `set -u`; sourcing them turns nounset ON in
# the test shell, which trips bats-core internals (and is stricter than the
# fixtures need). Turn it back off here - the harness functions are robust under
# either setting because they use ${x:?}/${x:-} guards, not bare expansions.
set +u
