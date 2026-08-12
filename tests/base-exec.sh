#!/usr/bin/env bash
# base-exec.sh — executes the codex-review resolver command lines embedded in
# this repo's own skills/*/SKILL.md, verbatim, exactly as a human would paste
# them into a shell (T-016, F-14; regression guard for F-15's literal
# `<BASE>` bug: bash parses an unquoted `<BASE>` placeholder as `< BASE` —
# input redirection from a file literally named BASE — before the command
# even starts, independent of anything codex-review.sh itself does).
#
# Every run is fully sandboxed:
#  - HOME points at a scratch directory whose only
#    ~/.claude/skills/pf-do/scripts/codex-review.sh is a symlink to THIS
#    REPO's own copy — never the real installed surface, never _tools canon.
#  - PATH is a curated toolset that never includes the real `codex` CLI, so
#    even a resolver bug that reached a live call could not shell out for
#    real (belt-and-braces: codex-review.sh's own Gate 1 also checks
#    `command -v codex` and skips cleanly when absent — see run.sh's "no
#    real network calls, no real codex CLI reachable" group for the proof).
#  - cwd is a scratch git repo with no .agents/codex-review.json, so even a
#    line that reaches codex-review.sh hits a clean, honest SKIP.
# Bash 3.2 compatible (macOS system bash floor, same constraint as every
# other script in this family).
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
FULL_PATH="$PATH"
BASH_BIN="$(command -v bash)"

PASS=0
FAIL=0
FAIL_LABELS=()
pass() { PASS=$((PASS + 1)); echo "PASS  $1"; }
fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL  $1"
  [ -n "${2:-}" ] && echo "      $2"
  FAIL_LABELS+=("$1")
}

echo "base-exec.sh — <BASE>-placeholder / resolver-line executability"
echo "root: $ROOT"
echo "bash: $BASH_BIN ($("$BASH_BIN" --version | head -1))"

CLEANUP_DIRS=()
cleanup() {
  local d
  for d in "${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}"; do [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"; done
}
trap cleanup EXIT

# Portable temp dir: GNU mktemp (Linux, incl. ubuntu-latest — the CI runner
# this suite ships for) rejects `-t <prefix>` unless <prefix> itself
# contains literal X's ("too few X's in template"); BSD mktemp (macOS, this
# suite's other target) accepts a bare prefix and appends randomness itself.
# An explicit template with X's is accepted, identically, by both. Verified
# on macOS and in `ubuntu:24.04` (docker) before relying on it here — a
# silent empty $MP from a failed mktemp would make EVERY curated-PATH
# symlink below resolve to "/$t" instead of a real sandboxed tool.
mktempdir() { local d; d=$(mktemp -d "${TMPDIR:-/tmp}/pfwf-base-exec.XXXXXXXX"); CLEANUP_DIRS+=("$d"); printf '%s' "$d"; }

# --- curated PATH: fixed toolset, codex NEVER on it -------------------------
BASE_TOOLS="bash git printf tr grep date dirname mkdir sed cat rm mktemp sort wc head tail sleep basename ls"
MP="$(mktempdir)"
for t in $BASE_TOOLS; do
  src="$(PATH="$FULL_PATH" command -v "$t" 2>/dev/null)" || { echo "harness setup: required tool '$t' not found" >&2; exit 90; }
  ln -sf "$src" "$MP/$t"
done
if [ -e "$MP/codex" ]; then
  echo "harness bug: codex must never be on the curated PATH" >&2
  exit 90
fi

new_scratch_repo() {
  local d
  d="$(mktempdir)"
  ( cd "$d" && PATH="$FULL_PATH" git init -q \
      && PATH="$FULL_PATH" git config user.email test@example.com \
      && PATH="$FULL_PATH" git config user.name "base-exec tests" \
      && echo "seed=1" > seed.sh \
      && PATH="$FULL_PATH" git add seed.sh \
      && PATH="$FULL_PATH" git commit -qm seed >/dev/null )
  printf '%s' "$d"
}

# Sandbox HOME: the only codex-review.sh reachable via ~/.claude/... is a
# symlink to THIS repo's own copy.
SBHOME="$(mktempdir)"
mkdir -p "$SBHOME/.claude/skills/pf-do/scripts"
ln -sf "$ROOT/skills/pf-do/scripts/codex-review.sh" "$SBHOME/.claude/skills/pf-do/scripts/codex-review.sh"

# extract_resolver_line <file> — pulls the single-line, backtick-fenced
# inline code span CONTAINING `SC=$(ls` out of a markdown file (the
# resolver pattern used by pf-do/SKILL.md step 5a and pf-auto/SKILL.md's
# Codex pre-pass). Matches anywhere inside the span, not only at its start:
# pf-auto/SKILL.md's span opens with a `PF_AUTO_BASE="${PF_AUTO_BASE:-}"; if
# ...; else SC=$(ls ...` guard (T-014/F-15) — `SC=$(ls` is in the middle,
# not the first token. `[^`]*` on both sides never crosses into a
# neighbouring backtick span (it excludes the backtick character itself), so
# this still can't accidentally glue two separate inline spans together.
# Deliberately does NOT match the multi-line fenced ```bash ... ``` block in
# references/codex-review.md — that block documents the same idea for
# humans but is not "a command in SKILL.md", which is the literal scope of
# this ticket's acceptance criterion.
extract_resolver_line() {
  grep -oE '`[^`]*SC=\$\(ls[^`]*`' "$1" | head -1 | sed 's/^`//; s/`$//'
}

check_line() {
  local label="$1" cmd="$2"
  local repo out rc
  repo="$(new_scratch_repo)"
  out="$( cd "$repo" && PATH="$MP" HOME="$SBHOME" "$BASH_BIN" -c "$cmd" 2>&1 )"
  rc=$?
  # Three legitimate clean-exit shapes: the plain resolver's `SKIP:` (real
  # codex-review.sh gate) or `no script` (no installed surface), and
  # pf-auto's guarded form's `no BASE recorded` (PF_AUTO_BASE unset in this
  # sandbox — the correct, honest response, not a failure to detect).
  if [ "$rc" = 0 ] && { printf '%s' "$out" | grep -q '^SKIP:' || printf '%s' "$out" | grep -q 'no script' || printf '%s' "$out" | grep -q 'no BASE recorded'; }; then
    pass "$label -> clean skip, rc=0 ($out)"
  else
    fail "$label -> rc=$rc, not a clean skip" "$out"
  fi
}

FOUND_ANY=0
for f in "$ROOT/skills/pf-do/SKILL.md" "$ROOT/skills/pf-auto/SKILL.md"; do
  rel="${f#"$ROOT"/}"
  if [ ! -f "$f" ]; then
    fail "$rel -> file not found"
    continue
  fi
  line="$(extract_resolver_line "$f")"
  if [ -z "$line" ]; then
    fail "$rel -> no resolver line found (pattern \`SC=\$(ls ...\` missing)"
    continue
  fi
  FOUND_ANY=1
  check_line "$rel" "$line"
done
[ "$FOUND_ANY" = 1 ] || { echo "harness setup: found zero resolver lines to test — SKILL.md content moved?" >&2; exit 90; }

echo
echo "=== SUMMARY ==="
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
