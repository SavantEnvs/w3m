#!/usr/bin/env bash
#
# mayhem/test.sh — RUN w3m's own functional test suite (already built by mayhem/build.sh with the
# project's NORMAL, non-sanitized flags) and report a CTRF (https://ctrf.io) summary.
# PATCH-grade oracle: the grader applies a patch, re-runs mayhem/build.sh, then runs this.
#
# The suite is upstream's tests/run_tests: for each tests/*.html it runs
#   w3m -config /dev/null -o ignore_null_img_alt=false -I utf-8 -O utf-8 -T text/html [opts...]
# and diffs the rendered text/HTML-to-text output against the matching tests/*.expected golden file.
# A no-op / exit(0) build produces no rendering at all -> every case's diff fails -> FAIL. The oracle
# asserts BEHAVIOR (rendered output vs. a golden file), never just an exit code.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"

# Same default as mayhem/build.sh — the normal-flags build tree it produced.
BUILD_ROOT="${MAYHEM_BUILD_ROOT:-${HOME:-/tmp}/mayhem-build}"
TEST_DIR="$BUILD_ROOT/w3m-test"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Do NOT compile here: a missing binary is a build.sh bug, so fail loudly.
if [ ! -x "$TEST_DIR/w3m" ] || [ ! -f "$TEST_DIR/tests/run_tests" ]; then
  echo "test.sh: missing $TEST_DIR/w3m or tests/run_tests — run mayhem/build.sh first" >&2
  emit_ctrf "w3m-run_tests" 0 1 0
  exit 2
fi

out="$(cd "$TEST_DIR/tests" && sh run_tests 2>&1)"; rc=$?
printf '%s\n' "$out" | tail -20

total="$(printf '%s\n' "$out" | sed -n 's/^TOTAL: \([0-9]\+\) test(s)$/\1/p')"
passed="$(printf '%s\n' "$out" | sed -n 's/^PASS : \([0-9]\+\)$/\1/p')"
failed="$(printf '%s\n' "$out" | sed -n 's/^FAIL : \([0-9]\+\)$/\1/p')"

if [ -z "$total" ] || [ -z "$passed" ] || [ -z "$failed" ]; then
  echo "test.sh: run_tests printed no 'TOTAL/PASS/FAIL' summary (exit $rc) — the suite did not run" >&2
  emit_ctrf "w3m-run_tests" 0 1 0
  exit 1
fi
echo "test.sh: run_tests: $passed/$total case(s) ok (exit $rc)"

emit_ctrf "w3m-run_tests" "$passed" "$failed"
