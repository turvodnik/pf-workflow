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
# Sub-harnesses added by the 2026-09-20 fix pass (SPEC-agent-limits, final
# review 💭-9 / Consistency № 12): until then CI ran only the codex-review
# harness above — council.sh and pf-run.sh shipped with their own suites
# never executed here. Same contract as the block
# above: require_subharness_ran (rc 0/1 = a real run), then the per-case FAIL
# labels («  - label» lines of the "Failed:" summary, lib.sh format) against
# the allowlist. Each one's own summary is printed for the human reader.
run_lib_subharness() {
  # run_lib_subharness <label> <script>
  local label="$1" script="$2" out rc raw
  if [ ! -f "$script" ]; then
    fail "$label: $script missing — the script it covers would ship untested"
    return
  fi
  out=$("$BASH_BIN" "$script" 2>&1); rc=$?
  printf '%s\n' "$out" | grep -E '^(TOTAL|RESULT|PASS:|FAIL )' | tail -6
  if require_subharness_ran "$label" "$rc" "$out"; then
    raw=$(pf_mktemp_file pfwf-sub-raw)
    printf '%s\n' "$out" | grep '^  - ' | sed 's/^  - //' > "$raw"
    check_against_allowlist "$label" "$raw"
    rm -f "$raw"
  fi
}
# ===========================================================================
group "council.sh harness (skills/pf-do/scripts/tests/council.sh)"
# ===========================================================================
run_lib_subharness "council-harness" "$ROOT/skills/pf-do/scripts/tests/council.sh"

# ===========================================================================
group "pf-run.sh harness (skills/pf-do/scripts/tests/pf-run.sh, output diet)"
# ===========================================================================
run_lib_subharness "pf-run-harness" "$ROOT/skills/pf-do/scripts/tests/pf-run.sh"

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
group "agents/index.yaml validity (T-117, pf-agents scaffold)"
# ===========================================================================
# yaml-strict.sh above never touches this file (it walks *.md only) — that
# gap is exactly what a hostile review of T-117 found (a broken index.yaml
# would pass every other check in this suite). This is the real check:
# strict-parse index.yaml with an actual YAML loader and shape-check the
# result, the same way yaml-strict.sh does for frontmatter.
IY_FILE="$ROOT/agents/index.yaml"
if [ ! -f "$IY_FILE" ]; then
  echo "SKIP  agents/index.yaml not present in this checkout — nothing to validate (pre-sync, or a layout without it)"
elif ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "SKIP  no python3 with the 'yaml' module (pyyaml) — agents/index.yaml NOT validated this run (this is NOT the same as 'valid')"
else
  iy_out=$(python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print("PARSE ERROR: %s" % e)
    sys.exit(1)
if not isinstance(d, dict) or not isinstance(d.get("roles"), list):
    print("SHAPE ERROR: expected a mapping with a list under \"roles\", got %r" % (d,))
    sys.exit(1)
print("roles is a list of %d entr%s" % (len(d["roles"]), "y" if len(d["roles"]) == 1 else "ies"))
' "$IY_FILE" 2>&1); iy_rc=$?
  if [ "$iy_rc" = 0 ]; then
    pass "agents/index.yaml: $iy_out"
  else
    fail "agents/index.yaml failed strict validation" "$iy_out"
  fi
fi

# ===========================================================================
group "wait-guard.sh Stop hook (T-110): tests/wait-guard.sh against hooks/wait-guard.sh"
# ===========================================================================
wg_out=$("$BASH_BIN" "$TESTS_DIR/wait-guard.sh" 2>&1); wg_rc=$?
wg_tail=$(printf '%s\n' "$wg_out" | tail -1)
if [ "$wg_rc" = 0 ]; then
  pass "wait-guard: $wg_tail"
else
  fail "wait-guard suite red (rc=$wg_rc): $wg_tail" "$wg_out"
fi

# ===========================================================================
group "install.sh keeps someone else's hook registration (T-187): KEPT, --force, --sync, missing file"
# ===========================================================================
# A registration of our hook that points at an EXISTING file outside this
# clone (a canon checkout, another copy) is someone else's wiring: install.sh
# (and --sync) must leave it and print KEPT; --force points it here; a
# registration whose file is gone is ours to repair. HOME and the settings
# file are temporary — never the real ~/.claude.
if command -v python3 >/dev/null 2>&1; then
  wk_root="$(mktempdir)"; wk_foreign="$wk_root/canon"; mkdir -p "$wk_foreign" "$wk_root/home"
  printf '#!/bin/bash\nexit 0\n' > "$wk_foreign/wait-guard.sh"; chmod +x "$wk_foreign/wait-guard.sh"
  wk_ours="$ROOT/hooks/wait-guard.sh"
  wk_kept_line="KEPT: Stop → $wk_foreign/wait-guard.sh (registered elsewhere; re-run with --force to point it at this clone)"
  wk_settings() { # wk_settings <file> <dir of the registered wait-guard.sh>
    printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash %s/wait-guard.sh","timeout":40}]}]}}\n' "$2" > "$1"
  }
  # stop_paths <settings> — the wait-guard.sh paths the Stop commands name.
  stop_paths() {
    python3 - "$1" <<'PYEOF'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for it in d.get("hooks", {}).get("Stop", []):
    for h in it.get("hooks", []):
        m = re.search(r"'([^']*/wait-guard\.sh)'|(/\S*/wait-guard\.sh)", h.get("command", ""))
        print(m.group(1) or m.group(2) if m else "?")
PYEOF
  }
  for mode in full sync; do
    args=(); [ "$mode" = sync ] && args=(--sync)
    s="$wk_root/kept-$mode.json"; wk_settings "$s" "$wk_foreign"
    o=$(HOME="$wk_root/home" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$ROOT/install.sh" "${args[@]+"${args[@]}"}" 2>&1); r=$?
    if [ "$r" = 0 ] && [ "$(stop_paths "$s")" = "$wk_foreign/wait-guard.sh" ] && printf '%s\n' "$o" | grep -qxF "$wk_kept_line"; then
      pass "[$mode] Stop registered at an existing file outside the clone -> KEPT line, entry untouched"
    else
      fail "[$mode] the foreign Stop registration was not kept (rc=$r)" "$o | $(stop_paths "$s")"
    fi
    s="$wk_root/force-$mode.json"; wk_settings "$s" "$wk_foreign"
    o=$(HOME="$wk_root/home" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$ROOT/install.sh" "${args[@]+"${args[@]}"}" --force 2>&1); r=$?
    if [ "$r" = 0 ] && [ "$(stop_paths "$s")" = "$wk_ours" ] && ! printf '%s' "$o" | grep -q '^KEPT' && grep -q '"timeout": 40' "$s"; then
      pass "[$mode] --force -> Stop points at this clone (manual timeout 40 kept), no KEPT line"
    else
      fail "[$mode] --force did not repoint Stop (rc=$r)" "$o | $(stop_paths "$s")"
    fi
    s="$wk_root/gone-$mode.json"; wk_settings "$s" "$wk_root/gone"
    o=$(HOME="$wk_root/home" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$ROOT/install.sh" "${args[@]+"${args[@]}"}" 2>&1); r=$?
    if [ "$r" = 0 ] && [ "$(stop_paths "$s")" = "$wk_ours" ] && ! printf '%s' "$o" | grep -q '^KEPT'; then
      pass "[$mode] Stop registered at a missing file -> upsert to this clone, no KEPT line"
    else
      fail "[$mode] a Stop registration pointing at a missing file was not repaired (rc=$r)" "$o | $(stop_paths "$s")"
    fi
  done
else
  echo "SKIP  python3 not available — install.sh needs it to register hooks"
fi

# ===========================================================================
group "pf-session-id.sh SessionStart hook (T-191, QA Ж-5; renamed T-193, Н-4): tests/pf-session-id.sh against hooks/pf-session-id.sh"
# ===========================================================================
si_out=$("$BASH_BIN" "$TESTS_DIR/pf-session-id.sh" 2>&1); si_rc=$?
si_tail=$(printf '%s\n' "$si_out" | tail -1)
if [ "$si_rc" = 0 ]; then
  pass "pf-session-id: $si_tail"
else
  fail "pf-session-id suite red (rc=$si_rc): $si_tail" "$si_out"
fi

# ===========================================================================
group "install.sh hook registration hardening (T-191, QA Ж-2 / Ж-3 / Ж-4)"
# ===========================================================================
# Ж-2: a clone path with an apostrophe gives a command that parses (rc 0
# under /bin/sh and dash, never the 2 that keeps a Stop hook blocking), and a
# second run reads it back as OURS (unchanged, no KEPT). Ж-3: our hook shares
# a group with a foreign one — only our object is replaced, the neighbour and
# the group's matcher stay. Ж-4: the backup copy gets the mode of a 0600
# settings file. Temporary HOME and settings file only.
if command -v python3 >/dev/null 2>&1; then
  ih_root="$(mktempdir)"; mkdir -p "$ih_root/home"
  ih_clone="$ih_root/Mike's tools/pf-workflow"; mkdir -p "$ih_clone"
  ( cd "$ROOT" && tar cf - --exclude ./.git --exclude ./.claude . ) | ( cd "$ih_clone" && tar xf - )
  s="$ih_root/apos.json"; printf '{}\n' > "$s"
  o1=$(HOME="$ih_root/home" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$ih_clone/install.sh" --sync 2>&1); r1=$?
  ih_cmd=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print([h["command"] for g in d["hooks"]["Stop"] for h in g["hooks"] if "wait-guard" in h["command"]][0])' "$s" 2>&1)
  sh_rc=$(printf '{}' | HOME="$ih_root/home" /bin/sh -c "$ih_cmd" >/dev/null 2>&1; echo $?)
  dash_rc=0; if [ -x /bin/dash ]; then dash_rc=$(printf '{}' | HOME="$ih_root/home" /bin/dash -c "$ih_cmd" >/dev/null 2>&1; echo $?); fi
  o2=$(HOME="$ih_root/home" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$ih_clone/install.sh" --sync 2>&1); r2=$?
  if [ "$r1" = 0 ] && [ "$sh_rc" = 0 ] && [ "$dash_rc" = 0 ] && [ "$r2" = 0 ] && printf '%s' "$o2" | grep -q 'unchanged' && ! printf '%s' "$o2" | grep -q '^KEPT'; then
    pass "Ж-2: clone path with an apostrophe -> Stop command parses (sh rc $sh_rc, dash rc $dash_rc); re-run reads it as ours (unchanged, no KEPT)"
  else
    fail "Ж-2: apostrophe in the clone path (install rc=$r1/$r2, sh rc=$sh_rc, dash rc=$dash_rc)" "$o1 | $o2 | $ih_cmd"
  fi
  # A foreign registration at an existing path WITH an apostrophe is still KEPT.
  ih_for="$ih_root/O'Brien canon"; mkdir -p "$ih_for"; printf '#!/bin/bash\nexit 0\n' > "$ih_for/wait-guard.sh"; chmod +x "$ih_for/wait-guard.sh"
  s="$ih_root/kept-apos.json"
  python3 -c '
import json, sys
q = sys.argv[2].replace("\x27", "\x27\\\x27\x27")
json.dump({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "bash \x27%s\x27" % q, "timeout": 15}]}]}}, open(sys.argv[1], "w"))' "$s" "$ih_for/wait-guard.sh"
  o=$(HOME="$ih_root/home" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$ROOT/install.sh" --sync 2>&1); r=$?
  if [ "$r" = 0 ] && printf '%s\n' "$o" | grep -qxF "KEPT: Stop → $ih_for/wait-guard.sh (registered elsewhere; re-run with --force to point it at this clone)"; then
    pass "Ж-2: a foreign Stop registration whose path has an apostrophe -> KEPT, not overwritten"
  else
    fail "Ж-2: foreign registration with an apostrophe was not kept (rc=$r)" "$o | $(cat "$s")"
  fi
  # Ж-3
  s="$ih_root/group.json"
  printf '%s\n' '{"hooks":{"Stop":[{"matcher":"m1","hooks":[{"type":"command","command":"/opt/my/notify-done.sh","timeout":30},{"type":"command","command":"bash '"'"'/old/place/pf-workflow/hooks/wait-guard.sh'"'"'","timeout":15}]}]}}' > "$s"
  o=$(HOME="$ih_root/home" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$ROOT/install.sh" --sync 2>&1); r=$?
  ih_g=$(python3 -c '
import json, sys
g = json.load(open(sys.argv[1]))["hooks"]["Stop"]
print(len(g), g[0].get("matcher"), [h["command"] for h in g[0]["hooks"]][0], sum(sys.argv[2] + "/hooks/wait-guard.sh" in h["command"] for h in g[0]["hooks"]))' "$s" "$ROOT" 2>&1)
  if [ "$r" = 0 ] && [ "$ih_g" = "1 m1 /opt/my/notify-done.sh 1" ]; then
    pass "Ж-3: our hook in a shared group -> only our object replaced; the neighbour, its order and the matcher stay (one group)"
  else
    fail "Ж-3: a shared Stop group was not preserved (rc=$r)" "$o | $ih_g | $(cat "$s")"
  fi
  o=$(HOME="$ih_root/home" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$ROOT/install.sh" --sync 2>&1)
  if printf '%s' "$o" | grep -q 'unchanged' && grep -q notify-done "$s"; then
    pass "Ж-3: a repeat --sync over the shared group -> unchanged, the neighbour still there"
  else
    fail "Ж-3: repeat --sync over a shared group changed it" "$o"
  fi
  # Ж-4
  s="$ih_root/mode.json"; printf '{"env":{"SOME_TOKEN":"x"}}\n' > "$s"; chmod 600 "$s"
  printf 'old\n' > "$s.bak-pf-workflow"; chmod 644 "$s.bak-pf-workflow"
  HOME="$ih_root/home" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$ROOT/install.sh" --sync >/dev/null 2>&1
  ih_m=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$s.bak-pf-workflow")
  s2="$ih_root/mode-new.json"; printf '{}\n' > "$s2"; chmod 600 "$s2"
  HOME="$ih_root/home" CLAUDE_SETTINGS_PATH="$s2" "$BASH_BIN" "$ROOT/install.sh" --sync >/dev/null 2>&1
  ih_m2=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$s2.bak-pf-workflow")
  if [ "$ih_m" = 0o600 ] && [ "$ih_m2" = 0o600 ] && grep -q SOME_TOKEN "$s.bak-pf-workflow"; then
    pass "Ж-4: backup of a 0600 settings.json is 0600 (an old 0644 copy is tightened, a new one is born 0600)"
  else
    fail "Ж-4: backup mode is not the original's" "existing copy: $ih_m, new copy: $ih_m2"
  fi
else
  echo "SKIP  python3 not available — install.sh needs it to register hooks"
fi

# ===========================================================================
group "install.sh fails when hook registration does not complete (R10, 2.1.1): default and --sync agree"
# ===========================================================================
# A broken settings.json: registration refuses and leaves it unchanged; the
# install must not report "Done" with rc 0 (it did: `register_hooks || true`).
# Temporary HOME and settings file only. Output is matched with here-strings,
# not `printf | grep -q` (that pipe races under pipefail — QA4 2.1.0).
if command -v python3 >/dev/null 2>&1; then
  r10_root="$(mktempdir)"; mkdir -p "$r10_root/home"
  r10_s="$r10_root/settings.json"; printf '{"hooks": {"Stop": [' > "$r10_s"
  r10_sum0=$(cksum < "$r10_s")
  r10_o1=$(HOME="$r10_root/home" CLAUDE_SETTINGS_PATH="$r10_s" "$BASH_BIN" "$ROOT/install.sh" 2>&1); r10_r1=$?
  r10_sum1=$(cksum < "$r10_s")
  if [ "$r10_r1" != 0 ] && [ "$r10_sum1" = "$r10_sum0" ] && ! grep -q '^Done' <<<"$r10_o1" \
     && grep -q 'INCOMPLETE' <<<"$r10_o1" && grep -q 'not valid JSON' <<<"$r10_o1"; then
    pass "default install over a broken settings.json -> rc $r10_r1, file unchanged, INCOMPLETE, no Done"
  else
    fail "default install over a broken settings.json (rc=$r10_r1, unchanged=$([ "$r10_sum1" = "$r10_sum0" ] && echo yes || echo no))" "$r10_o1"
  fi
  r10_o2=$(HOME="$r10_root/home" CLAUDE_SETTINGS_PATH="$r10_s" "$BASH_BIN" "$ROOT/install.sh" --sync 2>&1); r10_r2=$?
  if [ "$r10_r2" != 0 ] && [ "$r10_r2" = "$r10_r1" ] && [ "$(cksum < "$r10_s")" = "$r10_sum0" ] && grep -q 'not valid JSON' <<<"$r10_o2"; then
    pass "--sync over the same file -> the same rc $r10_r2, file unchanged"
  else
    fail "--sync over a broken settings.json disagrees with the default mode (sync rc=$r10_r2, default rc=$r10_r1)" "$r10_o2"
  fi
  # control: the same install over a valid file succeeds
  printf '{}\n' > "$r10_s"
  r10_o3=$(HOME="$r10_root/home" CLAUDE_SETTINGS_PATH="$r10_s" "$BASH_BIN" "$ROOT/install.sh" --update 2>&1); r10_r3=$?
  if [ "$r10_r3" = 0 ] && grep -q '^Done' <<<"$r10_o3" && grep -q 'wait-guard' "$r10_s"; then
    pass "control: a valid settings.json -> rc 0, Done, hooks registered"
  else
    fail "control: install over a valid settings.json (rc=$r10_r3)" "$r10_o3"
  fi
  # QA 27.10 (2.1.1, yellow-2): a hook skipped because it is not executable is
  # a hook that is NOT registered — the install fails like a broken file does.
  r10_c="$r10_root/clone"; mkdir -p "$r10_c"; cp -R "$ROOT/." "$r10_c/"; rm -rf "$r10_c/.git"
  chmod -x "$r10_c/hooks/wait-guard.sh"
  printf '{}\n' > "$r10_s"
  r10_o4=$(HOME="$r10_root/home" CLAUDE_SETTINGS_PATH="$r10_s" "$BASH_BIN" "$r10_c/install.sh" 2>&1); r10_r4=$?
  if [ "$r10_r4" != 0 ] && ! grep -q '^Done' <<<"$r10_o4" && grep -q 'INCOMPLETE' <<<"$r10_o4" && grep -q 'not executable' <<<"$r10_o4"; then
    pass "default install with a non-executable wait-guard.sh -> rc $r10_r4, INCOMPLETE, no Done"
  else
    fail "non-executable hook: default install (rc=$r10_r4)" "$r10_o4"
  fi
  printf '{}\n' > "$r10_s"
  r10_o5=$(HOME="$r10_root/home" CLAUDE_SETTINGS_PATH="$r10_s" "$BASH_BIN" "$r10_c/install.sh" --sync 2>&1); r10_r5=$?
  if [ "$r10_r5" != 0 ] && grep -q 'not executable' <<<"$r10_o5"; then
    pass "--sync with a non-executable wait-guard.sh -> rc $r10_r5"
  else
    fail "non-executable hook: --sync (rc=$r10_r5)" "$r10_o5"
  fi
  chmod -x "$r10_c/hooks/pf-session-id.sh"; printf '{}\n' > "$r10_s"
  r10_o6=$(HOME="$r10_root/home" CLAUDE_SETTINGS_PATH="$r10_s" "$BASH_BIN" "$r10_c/install.sh" --sync 2>&1); r10_r6=$?
  if [ "$r10_r6" != 0 ] && grep -q 'no hook could be registered' <<<"$r10_o6" && ! grep -q 'missing or empty' <<<"$r10_o6"; then
    pass "--sync with every hook non-executable -> rc $r10_r6, the true reason (not 'missing or empty')"
  else
    fail "all hooks non-executable (rc=$r10_r6)" "$r10_o6"
  fi
else
  echo "SKIP  python3 not available — install.sh needs it to register hooks"
fi

# ===========================================================================
group "criteria-check.sh broken probe vs legitimate red (R09, 2.1.1): skills/pf-tickets/scripts/tests/criteria-check.sh"
# ===========================================================================
cc_out=$("$BASH_BIN" "$ROOT/skills/pf-tickets/scripts/tests/criteria-check.sh" 2>&1); cc_rc=$?
cc_tail=$(tail -1 <<<"$cc_out")
if [ "$cc_rc" = 0 ] && grep -q 'passed, 0 failed' <<<"$cc_tail"; then
  pass "criteria-check: $cc_tail"
else
  fail "criteria-check suite red (rc=$cc_rc): $cc_tail" "$cc_out"
fi

# ===========================================================================
group "private-words stop-list (T-191, QA К-1): no author's project names in this tree"
# ===========================================================================
# The list lives OUTSIDE the distribution (${PF_PRIVATE_WORDS:-<canon>/
# security/private-words.txt}; one word or grep -E pattern per line,
# case-insensitive). No list (a friend's clone) — only the negative control
# below runs. pw_scan prints file:line, never the word itself.
pw_scan() {  # pw_scan <root> <list> -> file:line hits on stdout; rc 2 when grep failed
  local root="$1" list="$2" pat err out=""
  pat=$(pf_mktemp_file pfwf-pwpat); err=$(pf_mktemp_file pfwf-pwerr)
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$list" > "$pat" || true
  if [ -s "$pat" ]; then
    out="$(cd "$root" && find . -type f -not -path './.git/*' -not -path './.git' -not -path './.claude/*' -print0 \
      | xargs -0 grep -I -i -n -E -f "$pat" -- /dev/null 2>"$err" | cut -d: -f1,2 | sed 's|^\./||')" || true
  fi
  if [ -s "$err" ]; then rm -f "$pat" "$err"; return 2; fi
  rm -f "$pat" "$err"; printf '%s' "$out"
}
pw_list="${PF_PRIVATE_WORDS:-}"
if [ -z "$pw_list" ]; then
  pw_common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  for c in "${PF_TOOLS:-}" "$ROOT/../.." "${pw_common:+$pw_common/../../..}"; do
    if [ -n "$c" ] && [ -f "$c/security/private-words.txt" ]; then pw_list="$c/security/private-words.txt"; break; fi
  done
fi
if [ -n "$pw_list" ] && [ -f "$pw_list" ]; then
  pw_hits="$(pw_scan "$ROOT" "$pw_list")"; pw_rc=$?
  if [ "$pw_rc" = 0 ] && [ -z "$pw_hits" ]; then
    pass "no word of the stop-list ($pw_list) in this tree"
  else
    fail "stop-list words found in this tree (rc=$pw_rc) — de-personalise them in the canon, re-sync" "$pw_hits"
  fi
else
  echo "SKIP  no private-words list (PF_PRIVATE_WORDS / <canon>/security/private-words.txt) — expected outside the author's machine"
fi
pw_neg="$(mktempdir)"; pw_neg_list="$pw_neg/list.txt"
printf '# test list\n\nzz-private-canary\n' > "$pw_neg_list"
mkdir -p "$pw_neg/tree/docs"; cp "$ROOT/docs/rules-sections.en.md" "$pw_neg/tree/docs/"
before_hits="$(pw_scan "$pw_neg/tree" "$pw_neg_list")"
printf 'mention of ZZ-Private-Canary here\n' >> "$pw_neg/tree/docs/rules-sections.en.md"
after_hits="$(pw_scan "$pw_neg/tree" "$pw_neg_list")"
if [ -z "$before_hits" ] && printf '%s\n' "$after_hits" | grep -q '^docs/rules-sections.en.md:[0-9]*$'; then
  pass "negative control: a list word appended to a copy of a shipped file (other case) -> named as file:line"
else
  fail "negative control: the stop-list scan did not catch a planted word" "before=$before_hits after=$after_hits"
fi

# ===========================================================================
group "secret scanner copy next to council.sh (T-187): present, executable, equal to the canon"
# ===========================================================================
# council.sh finds skills/pf-do/scripts/secret-scan/repo-hooks/pre-commit when
# there is no _tools canon (friends' machines). sync-from-tools.sh puts the
# three files there; here: they exist, the hook is executable, and — where a
# canon is reachable (a dev clone or its worktree, or PF_TOOLS) — they are
# byte-equal to it. No canon: the equality check is a SKIP, not a FAIL.
SS_DIR="$ROOT/skills/pf-do/scripts/secret-scan"
ss_missing=""
for f in repo-hooks/pre-commit repo-hooks/pf-secret-rules.toml gitleaks-fp-ledger.py; do
  [ -f "$SS_DIR/$f" ] || ss_missing="$ss_missing $f"
done
if [ -z "$ss_missing" ] && [ -x "$SS_DIR/repo-hooks/pre-commit" ]; then
  pass "secret-scan/: pre-commit (executable), pf-secret-rules.toml, gitleaks-fp-ledger.py are in place"
else
  fail "secret-scan/ copy incomplete or pre-commit not executable" "missing:$ss_missing"
fi
ss_canon=""
ss_common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
for c in "${PF_TOOLS:-}" "$ROOT/../.." "${ss_common:+$ss_common/../../..}"; do
  if [ -n "$c" ] && [ -f "$c/security/repo-hooks/pre-commit" ]; then ss_canon="$c"; break; fi
done
if [ -n "$ss_canon" ]; then
  ss_diff=""
  for f in repo-hooks/pre-commit repo-hooks/pf-secret-rules.toml gitleaks-fp-ledger.py; do
    cmp -s "$SS_DIR/$f" "$ss_canon/security/$f" || ss_diff="$ss_diff $f"
  done
  if [ -z "$ss_diff" ]; then
    pass "secret-scan/ copy is byte-equal to the canon ($ss_canon/security)"
  else
    fail "secret-scan/ copy differs from the canon — re-run sync-from-tools.sh" "differs:$ss_diff"
  fi
else
  echo "SKIP  no _tools canon reachable — copy-equals-canon not checked (expected outside a dev clone)"
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
  # --repo-dir, not --repo: the checker must inspect THIS checkout ($ROOT),
# not guess $TOOLS/repos/<name> — in a worktree or symlinked layout those
# are different directories, and the suite would silently report on the
# wrong one (and stay green forever if the directory were renamed).
dc_out=$("$BASH_BIN" "$DC_CANON" --level 1 --repo-dir "$ROOT" 2>&1); dc_rc=$?
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
