#!/usr/bin/env bash
# Runs the Ashframe anticheat regression suite and writes a report of every
# case: what was "sent", the result, and whether it was BLOCKED or ALLOWED.
#
# Usage: tools/run_anticheat_tests.sh
#
# The cases live in src/server/anticheat_test.zig. This only exercises the
# validation/deserialization layer; the network wire is not simulated.

set -uo pipefail
cd "$(dirname "$0")/.."

OUT="tools/anticheat-test-report.txt"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

echo "Running: zig build test -Doptimize=ReleaseSafe"
./compiler/zig/zig build test -Doptimize=ReleaseSafe >"$LOG" 2>&1
STATUS=$?

{
	echo "Ashframe anticheat test report"
	echo "generated: $(date -Is)"
	echo
	echo "cases: $(grep -ac '\[cheat-test\]' "$LOG")   result: $([ $STATUS -eq 0 ] && echo PASS || echo "FAIL (exit $STATUS)")"
	echo
	echo "--- cases (name / sent / result / verdict) ---"
	grep -a '\[cheat-test\]' "$LOG" || true
	echo
	echo "--- failures / errors ---"
	grep -aE 'FAIL|error:|panic|ABRT|reached unreachable' "$LOG" | grep -av '\[cheat-test\].*PASS' || echo "(none)"
	echo
	grep -aE 'All [0-9]+ tests passed|tests failed|tests passed' "$LOG" | tail -1 || true
} >"$OUT"

cat "$OUT"
echo
echo "wrote $OUT"
exit $STATUS
