#!/usr/bin/env bash
set -euo pipefail

log_file="$(mktemp "${TMPDIR:-/tmp}/localvoxtral-swift-test.XXXXXX")"
chmod 600 "$log_file"

echo "Running swift test; full output: $log_file"
set +e
swift test "$@" >"$log_file" 2>&1
test_status=$?
set -e

if (( test_status == 0 )); then
  echo "PASS: swift test"
  grep -E "Test Suite 'All tests' passed|Executed [0-9]+ tests|Test run with [0-9]+ tests" \
    "$log_file" | tail -n 3 || true
  rm -f "$log_file"
  exit 0
fi

echo "FAIL: swift test exited with status $test_status" >&2
echo "Actionable failures:" >&2
if ! grep -n -C 2 -E \
  "(^|[[:space:]])error:|Test (Case|Suite) .+ failed|unexpected signal|fatalError|\[test\].*ERROR|task failed" \
  "$log_file" >&2; then
  echo "No standard failure markers found; last 80 lines:" >&2
  tail -n 80 "$log_file" >&2
fi
echo "Full output retained at: $log_file" >&2
exit "$test_status"
