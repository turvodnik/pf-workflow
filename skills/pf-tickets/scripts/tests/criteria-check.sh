#!/bin/bash
# tests/criteria-check.sh — criteria-check.sh tells a broken probe from a
# legitimate red on HEAD (R09, 2.1.1). Each case writes a one-criterion ticket
# and asserts the exit code AND the verdict line. bash 3.2, python3 only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SUT="$HERE/../criteria-check.sh"
[ -f "$SUT" ] || { echo "FAIL: criteria-check.sh not found at $SUT" >&2; exit 2; }

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/criteria-check-tests.XXXXXX")"
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
printf 'alpha\nbeta\n' > "$ROOT/present.txt"

# check <label> <want rc> <want substring in output> <must NOT appear> <criterion field lines...>
check() {
  local label="$1" want_rc="$2" want="$3" never="$4" t="$ROOT/T-001.md" out rc; shift 4
  { printf -- '---\nid: T-001\n---\n\n## Критерии приёмки\n- [ ] probe — change\n'
    for l in "$@"; do printf '  %s\n' "$l"; done
    printf '\n## Ограничения\n'; } > "$t"
  out="$(bash "$SUT" "$t" --cwd "$ROOT" 2>&1)"; rc=$?
  case "$out" in *"$want"*) ;; *) fail "$label → no «${want}» in: $out"; return ;; esac
  if [ -n "$never" ]; then case "$out" in *"$never"*) fail "$label → «${never}» must not appear: $out"; return ;; esac; fi
  if [ "$rc" = "$want_rc" ]; then pass "$label (rc $rc)"; else fail "$label → rc $rc, wanted $want_rc: $out"; fi
}

# Broken probes: never «OK (red on HEAD)», exit 2.
check "1 syntax error in the cmd (printf ( ) -> PROBE-ERROR" 2 "PROBE-ERROR" "OK (red on HEAD)" 'cmd: printf (' 'expect: ready'
check "2 nested shell syntax error (sh -c, rc 2) -> PROBE-ERROR" 2 "PROBE-ERROR" "OK (red on HEAD)" "cmd: sh -c 'if then'" 'expect: ready'
check "2a Python syntax error in the probe (SyntaxError, rc 1) -> PROBE-ERROR" 2 "PROBE-ERROR" "OK (red on HEAD)" "cmd: python3 -c 'print('" 'expect: ready'
check "2b broken grep regex in the probe (unbalanced parenthesis, rc 2) -> PROBE-ERROR" 2 "PROBE-ERROR" "OK (red on HEAD)" "cmd: grep -cE '(' present.txt" 'expect: 1'
# A leading '*' is an error only for BSD grep (macOS); GNU grep takes it as a literal.
# shellcheck disable=SC2063 # the glob-looking pattern is the point of the probe
if grep -E '*' </dev/null >/dev/null 2>&1; [ $? -eq 2 ]; then
check "2d BSD grep: '*' (repetition-operator operand invalid) -> PROBE-ERROR" 2 "PROBE-ERROR" "OK (red on HEAD)" "cmd: grep -cE '*' present.txt" 'expect: 1'
fi
check "2e grep: '[b-a]' (invalid range) -> PROBE-ERROR" 2 "PROBE-ERROR" "OK (red on HEAD)" "cmd: grep -cE '[b-a]' present.txt" 'expect: 1'
check "2f grep: 'a{2,1}' (invalid repetition count) -> PROBE-ERROR" 2 "PROBE-ERROR" "OK (red on HEAD)" "cmd: grep -cE 'a{2,1}' present.txt" 'expect: 1'
check "2c control: a missing Python module is a legitimate red (Traceback) -> OK" 0 "OK (red on HEAD)" "PROBE-ERROR" "cmd: python3 -c 'import nosuchmod_t201'" 'expect: ready'
check "3 missing file (grep on a path that is not there) -> PROBE-ERROR" 2 "PROBE-ERROR" "OK (red on HEAD)" 'cmd: grep -c alpha nosuch/file.txt' 'expect: 1'
check "4 missing program (rc 127) -> RUN-ERROR" 2 "RUN-ERROR" "OK (red on HEAD)" 'cmd: /nonexistent/probe-tool --check' 'expect: 1'
printf 'echo hi\n' > "$ROOT/noexec.sh"; chmod 644 "$ROOT/noexec.sh"
check "5 probe program not executable (rc 126) -> RUN-ERROR" 2 "RUN-ERROR" "OK (red on HEAD)" 'cmd: ./noexec.sh' 'expect: hi'
if [ "$(id -u)" != 0 ]; then
  printf 'alpha\n' > "$ROOT/locked.txt"; chmod 000 "$ROOT/locked.txt"
  check "6 unreadable file (Permission denied) -> PROBE-ERROR" 2 "PROBE-ERROR" "OK (red on HEAD)" 'cmd: grep -c alpha locked.txt' 'expect: 1'
else
  echo "SKIP: 6 unreadable file — running as root, chmod 000 does not bite"
fi
# Legitimate reds: accepted.
check "7 legitimate negative (grep -c finds 0, rc 1, no stderr) -> OK" 0 "OK (red on HEAD)" "PROBE-ERROR" 'cmd: grep -c gamma present.txt' 'expect: 1'
check "8 legitimate negative (test -f; rc 1, silent) -> OK" 0 "OK (red on HEAD)" "PROBE-ERROR" 'cmd: test -f created-later.txt && echo yes' 'expect: yes'
check "9 missing file declared as the red state (expect_head_rc: 2) -> OK" 0 "OK (red on HEAD)" "PROBE-ERROR" 'cmd: grep -c alpha created-later.txt' 'expect: 1' 'expect_head_rc: 2'
check "9a a syntax error the program under test reports ON PURPOSE (expect_head_rc: 2) -> OK" 0 "OK (red on HEAD)" "PROBE-ERROR" "cmd: sh -c 'if then'" 'expect: ready' 'expect_head_rc: 2'
check "10 expect_head_rc does not match the HEAD rc -> HEAD-MISMATCH FAIL" 1 "HEAD-MISMATCH FAIL" "OK (red on HEAD)" 'cmd: grep -c gamma present.txt' 'expect: 1' 'expect_head_rc: 0'
check "11 expect_head_rc not a number -> PROBE-ERROR" 2 "PROBE-ERROR" "OK (red on HEAD)" 'cmd: grep -c gamma present.txt' 'expect: 1' 'expect_head_rc: two'
# Unchanged verdicts.
check "12 green before work -> RED-BEFORE-WORK FAIL" 1 "RED-BEFORE-WORK FAIL" "PROBE-ERROR" 'cmd: grep -c alpha present.txt' 'expect: 1'
check "13 stderr without a failure (rc 0) -> STDERR WARN + OK" 0 "STDERR WARN" "PROBE-ERROR" 'cmd: echo note >&2; echo 0' 'expect: 1'

echo
echo "criteria-check tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
