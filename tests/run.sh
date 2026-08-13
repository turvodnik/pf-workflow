#!/usr/bin/env bash
# tests/run.sh — one-command test suite for the pf-workflow distribution
# (T-016, F-14). Everything here runs against THIS repo's own files
# (skills/, agents/) — never the _tools canon.
#
# T-017 (2026-08-13) synced canon into this repo; tests/known-failures-T017.txt
# is empty as a result — all 28 cases it used to track (codex-review.sh
# predating T-008's safety fixes, pf-auto's SKILL.md still holding T-014/
# F-15's literal `<BASE>`, pf-retro/SKILL.md predating T-009's frontmatter
# quoting) are confirmed passing on their own, not just "accounted for"
# (see that file's header). The bookkeeping below stays wired in — it is
# unconditional and may be needed again after a future canon fix outpaces
# the next sync: list the resulting case, one line per case, in
# tests/known-failures-T017.txt. run.sh treats listed cases as accounted
# for (this section still passes) but turns RED on anything else: a NEW
# failing case not on the list, or a listed case that unexpectedly starts
# passing (a sign canon already synced and the list must be trimmed — see
# that file's header). `RESULT: GREEN` here means "nothing unexplained is
# red", not "nothing is red" — read known-failures-T017.txt for the
# difference.
#
# Bash 3.2 compatible (macOS system bash floor, same constraint as every
# other script in this family): no associative arrays, no ${var,,}, no
# mapfile, no $BASHPID.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
BASH_BIN="$(command -v bash)"
ALLOWLIST="$TESTS_DIR/known-failures-T017.txt"

PASS=0
FAIL=0
FAIL_LABELS=()
CURRENT_GROUP=""
GROUP_PASS=0
GROUP_FAIL=0
GROUP_SUMMARY=()

group() {
  if [ -n "$CURRENT_GROUP" ]; then
    GROUP_SUMMARY+=("$CURRENT_GROUP: $GROUP_PASS/$((GROUP_PASS + GROUP_FAIL))")
  fi
  CURRENT_GROUP="$1"; GROUP_PASS=0; GROUP_FAIL=0
  echo; echo "=== $1 ==="
}
pass() { PASS=$((PASS + 1)); GROUP_PASS=$((GROUP_PASS + 1)); echo "PASS  $1"; }
fail() {
  FAIL=$((FAIL + 1)); GROUP_FAIL=$((GROUP_FAIL + 1))
  echo "FAIL  $1"; [ -n "${2:-}" ] && echo "      $2"
  FAIL_LABELS+=("[$CURRENT_GROUP] $1")
}

echo "pf-workflow test suite"
echo "root: $ROOT"
echo "bash: $BASH_BIN ($("$BASH_BIN" --version | head -1))"

CLEANUP_DIRS=()
cleanup() {
  local d
  for d in "${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}"; do [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"; done
}
trap cleanup EXIT

# Portable temp helpers: GNU mktemp (Linux, incl. ubuntu-latest — the CI
# runner this suite ships for) rejects `-t <prefix>` unless <prefix> itself
# contains literal X's ("too few X's in template"); BSD mktemp (macOS, this
# suite's other target) accepts a bare prefix and appends randomness itself.
# An explicit template with X's is accepted, identically, by both. Verified
# on macOS and in `ubuntu:24.04` (docker) before relying on it everywhere.
pf_mktemp_file() { mktemp "${TMPDIR:-/tmp}/$1.XXXXXXXX"; }
pf_mktemp_dir()  { mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXXXX"; }

mktempdir() { local d; d=$(pf_mktemp_dir pfwf-tests); CLEANUP_DIRS+=("$d"); printf '%s' "$d"; }

# ===========================================================================
# --- reusable sweeps (parameterized by root, so the negative control below
#     can point them at a mutated temp copy instead of the real repo) -------
# ===========================================================================

# find, not `git ls-files`: must also work against a temp copy with no .git.
list_sh_files() { find "$1" -name '*.sh' -not -path '*/.git/*' | sort; }

bash_n_sweep() {
  local root="$1" f bad=0 n=0 err
  err=$(pf_mktemp_file pfwf-bashn-err)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    n=$((n + 1))
    if ! "$BASH_BIN" -n "$f" 2>"$err"; then
      echo "      bash -n: ${f#"$root"/}: $(cat "$err")"
      bad=1
    fi
  done < <(list_sh_files "$root")
  rm -f "$err"
  echo "$n files checked"
  return "$bad"
}

# Runs ShellCheck across every .sh file under <root>: 0 = clean or
# unavailable, 1 = findings (also printed to stdout by the caller).
shellcheck_sweep() {
  local root="$1" files=()
  command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed"; return 2; }
  while IFS= read -r f; do files+=("$f"); done < <(list_sh_files "$root")
  [ "${#files[@]}" -eq 0 ] && return 0
  shellcheck -S warning "${files[@]}"
}

group "bash -n (syntax) on every .sh file"
bn_out=$(bash_n_sweep "$ROOT"); bn_rc=$?
echo "$bn_out" | tail -1
if [ "$bn_rc" = 0 ]; then
  pass "bash -n clean on all files ($(echo "$bn_out" | tail -1 | grep -oE '^[0-9]+'))"
else
  fail "bash -n found syntax error(s)" "$(echo "$bn_out" | grep '^      ')"
fi

group "shellcheck -S warning on every .sh file"
sc_out=$(shellcheck_sweep "$ROOT" 2>&1); sc_rc=$?
case "$sc_rc" in
  0) pass "shellcheck clean on all files" ;;
  2) echo "SKIP  shellcheck not installed on this machine — install: brew install shellcheck" ;;
  *) fail "shellcheck found issue(s)" "$sc_out" ;;
esac

group "GitHub Actions workflow YAML is valid"
WF="$ROOT/.github/workflows/tests.yml"
if [ ! -f "$WF" ]; then
  fail "tests.yml not found at $WF"
else
  # Two independent sub-checks (strict-parse, actionlint) with separate
  # tools: neither's absence may swallow the other (T-017 fix round, 🔴 B).
  if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP  python3 not available — cannot strict-parse the workflow YAML"
  elif ! python3 -c "import yaml" >/dev/null 2>&1; then
    # python3 present, PyYAML missing: the stock python3 on ubuntu-24.04 and
    # on macOS's Command Line Tools both lack it. Previously this fell
    # through to the strict-parse below, which raised ModuleNotFoundError
    # and reported "tests.yml is not valid YAML" — blaming a valid file for
    # a missing third-party module, contradicting this exact SKIP contract.
    echo "SKIP  PyYAML not installed (python3 -c 'import yaml' failed) — cannot strict-parse the workflow YAML"
  else
    if err=$(python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1], encoding='utf-8'))" "$WF" 2>&1); then
      pass "tests.yml parses as valid YAML"
    else
      fail "tests.yml is not valid YAML" "$err"
    fi
  fi
  if command -v actionlint >/dev/null 2>&1; then
    if out=$(actionlint "$WF" 2>&1); then pass "actionlint clean"; else fail "actionlint finding(s)" "$out"; fi
  else
    echo "SKIP  actionlint not installed on this machine (optional per acceptance criteria)"
  fi
fi

# ===========================================================================
# --- known-failures-T017.txt bookkeeping: per-case, not per-section --------
# ===========================================================================
# normalize_labels <file> -> sorted, with the two non-deterministic bits
# (a real PID, a real elapsed-seconds count from F-11/F-05's timeout races)
# collapsed so a rerun with a different PID/timing doesn't look "unexpected".
normalize_labels() {
  sed -E 's/pid=[0-9]+/pid=N/g; s/elapsed=[0-9]+s/elapsed=Ns/g' "$1" | sort
}

# check_against_allowlist <section> <file-of-this-run's-raw-FAIL-labels>
check_against_allowlist() {
  local section="$1" actual_raw="$2"
  local expected_raw norm_actual norm_expected unexpected stale
  expected_raw=$(pf_mktemp_file pfwf-allow-expected)
  if [ -f "$ALLOWLIST" ]; then
    grep -F "$section$(printf '\t')" "$ALLOWLIST" 2>/dev/null | sed "s/^$section$(printf '\t')//" > "$expected_raw"
  else
    : > "$expected_raw"
  fi
  norm_actual=$(pf_mktemp_file pfwf-allow-actual-n); normalize_labels "$actual_raw" > "$norm_actual"
  norm_expected=$(pf_mktemp_file pfwf-allow-expected-n); normalize_labels "$expected_raw" > "$norm_expected"

  unexpected=$(comm -23 "$norm_actual" "$norm_expected")
  stale=$(comm -13 "$norm_actual" "$norm_expected")

  if [ -z "$unexpected" ] && [ -z "$stale" ]; then
    local n; n=$(wc -l < "$norm_actual" | tr -d ' ')
    if [ "$n" -gt 0 ]; then
      pass "$section: $n known-fail(s), all accounted for in known-failures-T017.txt (canon sync pending T-017)"
    else
      pass "$section: fully green"
    fi
  else
    if [ -n "$unexpected" ]; then
      fail "$section: UNEXPECTED failing case(s), not in known-failures-T017.txt (real regression, or the allowlist text drifted)" "$unexpected"
    fi
    if [ -n "$stale" ]; then
      fail "$section: STALE known-failures-T017.txt entries — these now PASS; canon must have synced (T-017) — delete them from the allowlist" "$stale"
    fi
  fi
  rm -f "$expected_raw" "$norm_actual" "$norm_expected"
}

# require_subharness_ran <label> <rc> <output> -- a sub-harness that exits 0
# (clean) or 1 (some FAIL lines, which check_against_allowlist compares to
# the allowlist next) completed a real run. Anything else (e.g. 90 = setup
# aborted before any case ran — missing jq/python3 — or yaml-strict's 2 =
# "NOT VERIFIED, no YAML-capable interpreter") means it never finished: it
# has no per-case FAIL labels to check against the allowlist, so skipping
# straight to check_against_allowlist would compare two empty lists and
# print "fully green" for a sub-harness that verified nothing (T-017 fix
# round, 🟡 C — reproduced: renaming one resolver-line marker made
# base-exec.sh exit 90 with zero cases run, and the suite still read
# TOTAL 11/11 GREEN because nothing here ever looked at $?).
require_subharness_ran() {
  local label="$1" rc="$2" out="$3"
  if [ "$rc" != 0 ] && [ "$rc" != 1 ]; then
    fail "$label: sub-harness aborted before finishing (rc=$rc) — not run, not green" "$(printf '%s' "$out" | tail -3)"
    return 1
  fi
  return 0
}

# ===========================================================================
group "codex-review.sh safety harness (skills/pf-do/scripts/tests, T-008)"
# ===========================================================================
cr_out=$("$BASH_BIN" "$ROOT/skills/pf-do/scripts/tests/run.sh" 2>&1); cr_rc=$?
echo "$cr_out"
if require_subharness_ran "codex-review-harness" "$cr_rc" "$cr_out"; then
  cr_raw=$(pf_mktemp_file pfwf-cr-raw)
  printf '%s\n' "$cr_out" | grep '^  - ' | sed 's/^  - //' > "$cr_raw"
  check_against_allowlist "codex-review-harness" "$cr_raw"
  rm -f "$cr_raw"
fi

# ===========================================================================
group "yaml-strict.sh (skills/*/SKILL.md + agents/*.md frontmatter, T-009)"
# ===========================================================================
ys_out=$("$BASH_BIN" "$TESTS_DIR/yaml-strict.sh" 2>&1); ys_rc=$?
echo "$ys_out"
if require_subharness_ran "yaml-strict" "$ys_rc" "$ys_out"; then
  ys_raw=$(pf_mktemp_file pfwf-ys-raw)
  printf '%s\n' "$ys_out" | grep '^FAIL: ' | sed "s|^FAIL: $ROOT/||" > "$ys_raw"
  check_against_allowlist "yaml-strict" "$ys_raw"
  rm -f "$ys_raw"
fi

# ===========================================================================
group "drift-check.sh level 1 (T-022, I-024): this repo vs a fresh sync-from-tools.sh"
# ===========================================================================
# Only meaningful in a dev clone under _tools/repos/pf-workflow, where the
# canon (skill-library/) sits two levels up — never true for an end-user
# clone of this public repo, which has no _tools at all. Absent canon is a
# SKIP, not a FAIL: this repo's own suite must stay green for people who
# never heard of _tools (same contract as the other SKIP branches above).
DC_CANON="$ROOT/../../skill-library/tests/drift-check.sh"
if [ -f "$DC_CANON" ]; then
  dc_out=$("$BASH_BIN" "$DC_CANON" --level 1 --repo pf-workflow 2>&1); dc_rc=$?
  echo "$dc_out"
  if [ "$dc_rc" = 0 ]; then
    pass "drift-check level 1: repo matches a fresh sync-from-tools.sh from canon"
  else
    fail "drift-check level 1 found drift between canon and this repo" "$dc_out"
  fi
else
  echo "SKIP  no _tools canon found at $DC_CANON — expected outside a _tools/repos dev clone"
fi

# ===========================================================================
group "base-exec.sh (<BASE>-executability of SKILL.md resolver commands, T-014/F-15)"
# ===========================================================================
be_out=$("$BASH_BIN" "$TESTS_DIR/base-exec.sh" 2>&1); be_rc=$?
echo "$be_out"
if require_subharness_ran "base-exec" "$be_rc" "$be_out"; then
  be_raw=$(pf_mktemp_file pfwf-be-raw)
  printf '%s\n' "$be_out" | grep '^  - ' | sed 's/^  - //' > "$be_raw"
  check_against_allowlist "base-exec" "$be_raw"
  rm -f "$be_raw"
fi

# ===========================================================================
group "No real network calls, no real codex CLI reachable in this suite"
# ===========================================================================
# curl/wget: zero tolerance anywhere under tests/ or the transplanted
# harness — nothing here should ever be ABLE to touch the network. Excludes
# THIS file only, by its exact absolute path: this very check's pattern
# text would otherwise self-match. A bare `.../run\.sh:` (any directory)
# used to exclude every basename run.sh, including the real, in-scope
# child at $CR_TESTS/run.sh — a curl/wget added there would have escaped
# this tripwire forever, even though README promises it "never touches the
# network" for the exact command that runs that child (T-017 fix round,
# 🟡 E).
CR_TESTS="$ROOT/skills/pf-do/scripts/tests"
net_hits=$(grep -rnE '\bcurl\b|\bwget\b' "$TESTS_DIR" "$CR_TESTS" --include='*.sh' --include='fake-codex' 2>/dev/null | grep -v "^$TESTS_DIR/run\.sh:" || true)
if [ -z "$net_hits" ]; then
  pass "grep -rnE 'curl|wget' tests/ + skills/pf-do/scripts/tests/ (excluding run.sh itself) -> no matches"
else
  fail "found a curl/wget reference under the test suite" "$net_hits"
fi

# codex: rather than trying to negatively enumerate every safe mention of the
# word (fragile — this whole suite is ABOUT codex-review.sh), assert the two
# POSITIVE structural facts that make the real CLI unreachable, quoting the
# exact lines as evidence:
#  1. lib.sh's make_minpath* always symlinks fixtures/fake-codex as "codex" —
#     every codex-review-harness scenario that puts ANY "codex" on PATH puts
#     the fixture there, never a real binary.
fake_codex_line=$(grep -n 'ln -sf "\$FAKE_CODEX" "\$dir/codex"' "$CR_TESTS/lib.sh" || true)
if [ -n "$fake_codex_line" ]; then
  pass "lib.sh: every curated PATH's 'codex' is fixtures/fake-codex, never real ($fake_codex_line)"
else
  fail "lib.sh no longer symlinks fake-codex as 'codex' on its curated PATHs — codex-review-harness safety assumption broken"
fi
#  2. base-exec.sh refuses to run at all if "codex" ever ends up on its
#     curated PATH (belt-and-braces beyond simply never adding it).
guard_line=$(grep -n 'codex must never be on the curated PATH' "$TESTS_DIR/base-exec.sh" || true)
if [ -n "$guard_line" ]; then
  pass "base-exec.sh: hard-fails its own setup if codex ever appears on its curated PATH ($guard_line)"
else
  fail "base-exec.sh lost its 'codex must never be on the curated PATH' guard"
fi
# Evidence dump for the human reader (informational — not pass/fail gated,
# since almost every line here legitimately mentions codex by name; this is
# a codex-review test suite):
echo "      (informational) codex mentions in the suite: $(grep -rc 'codex' "$TESTS_DIR" "$CR_TESTS" --include='*.sh' --include='fake-codex' 2>/dev/null | awk -F: '{s+=$2} END{print s+0}') lines across $(grep -rl 'codex' "$TESTS_DIR" "$CR_TESTS" --include='*.sh' --include='fake-codex' 2>/dev/null | wc -l | tr -d ' ') files — see fixtures/fake-codex and lib.sh for the fixture that stands in for it"

# ===========================================================================
group "Negative control 1/2: a syntax error MUST turn the bash -n section red"
# ===========================================================================
mut1="$(mktempdir)"
cp -R "$ROOT/skills" "$ROOT/agents" "$ROOT/tests" "$mut1/"
printf 'if [ 1 = 1 ' >> "$mut1/skills/pf-do/scripts/codex-review.sh"   # unterminated [ ] / if -> guaranteed syntax error
mut_out=$(bash_n_sweep "$mut1" 2>&1); mut_rc=$?
if [ "$mut_rc" != 0 ] && printf '%s' "$mut_out" | grep -q 'codex-review.sh'; then
  pass "mutated copy (broken skills/pf-do/scripts/codex-review.sh) -> bash -n correctly reports it broken"
else
  fail "mutated copy did NOT turn bash -n red — negative control is not sensitive" "$mut_out"
fi

# ===========================================================================
group "Negative control 2/2: a broken frontmatter file MUST turn yaml-strict.sh red"
# ===========================================================================
mut2="$(mktempdir)"
cp -R "$ROOT/skills" "$ROOT/agents" "$ROOT/tests" "$mut2/"
# Break a file that is currently CLEAN (not the pre-existing pf-retro/SKILL.md
# known-failure) — proves this reacts to a fresh defect, not just to the one
# already on the allowlist. Same shape of breakage as the real pf-retro bug:
# an unquoted value containing ": " (colon-space), which YAML reads as a
# nested mapping key.
python3 - "$mut2/agents/pf-executor.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("description: ", "description: broken: value, ", 1)
open(p, "w", encoding="utf-8").write(s)
PY
mut_ys_out=$("$BASH_BIN" "$mut2/tests/yaml-strict.sh" 2>&1); mut_ys_rc=$?
if [ "$mut_ys_rc" != 0 ] && printf '%s' "$mut_ys_out" | grep -q 'pf-executor.md'; then
  pass "mutated copy (broken agents/pf-executor.md) -> yaml-strict.sh correctly reports it broken"
else
  fail "mutated copy did NOT turn yaml-strict.sh red — negative control is not sensitive" "$mut_ys_out"
fi

echo
echo "=== SUMMARY ==="
if [ -n "$CURRENT_GROUP" ]; then
  GROUP_SUMMARY+=("$CURRENT_GROUP: $GROUP_PASS/$((GROUP_PASS + GROUP_FAIL))")
fi
for line in "${GROUP_SUMMARY[@]+"${GROUP_SUMMARY[@]}"}"; do echo "$line"; done
echo "TOTAL: $PASS/$((PASS + FAIL))"
if [ "$FAIL" -gt 0 ]; then
  echo
  echo "Failed:"
  for l in "${FAIL_LABELS[@]+"${FAIL_LABELS[@]}"}"; do echo "  - $l"; done
fi
if [ "$FAIL" -eq 0 ]; then
  echo "RESULT: GREEN"
  exit 0
else
  echo "RESULT: RED"
  exit 1
fi
