#!/usr/bin/env bash
#
# run-tests.sh - run every test_*.sh in this directory, each in its own bash
# process for isolation, and aggregate the results.
#
#   bash prometheus/selfcheck/tests/run-tests.sh
#
# Exit code: 0 only if every test file passes.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

total=0
failed=0
for t in "$SCRIPT_DIR"/test_*.sh; do
  [ -f "$t" ] || continue
  total=$((total + 1))
  printf '\n########## %s ##########\n' "$(basename "$t")"
  bash "$t"
  if [ $? -ne 0 ]; then
    failed=$((failed + 1))
  fi
done

printf '\n===================================================\n'
if [ "$failed" -eq 0 ]; then
  printf 'ALL TEST FILES PASSED (%d/%d)\n' "$total" "$total"
  exit 0
fi
printf '%d of %d TEST FILES FAILED\n' "$failed" "$total"
exit 1
