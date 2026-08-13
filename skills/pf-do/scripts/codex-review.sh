#!/usr/bin/env bash
# codex-review.sh — optional second-opinion review of the current diff by Codex CLI.
#
# Contract: never blocks the workflow. If Codex is missing, not consented to, or
# the diff has no code, the script exits 0 with a one-line "skipped" note.
#
#   exit 0  — review ran, or was skipped for a legitimate reason (see SKIP line)
#   exit 1  — review was attempted and failed (empty/invalid output, crash)
#
# Usage:
#   codex-review.sh [--scope uncommitted|base|commit] [--base <ref>] [--commit <sha>]
#                   [--deep] [--out <file>] [--yes] [--why "<focus>"]
#
# The full report is written to a file; stdout carries only a short digest, so a
# calling agent spends ~15 lines of context instead of the whole review (§13).

set -uo pipefail

SCOPE="uncommitted"; BASE=""; COMMIT=""; DEEP=0; OUT=""; FORCE=0; FOCUS=""
MODEL_ARG=""; EFFORT_ARG=""
# Human-readable ref text for the report header (F-10 resolves BASE/COMMIT
# themselves to a bare hex SHA before they touch any command or prompt).
BASE_DISPLAY=""; COMMIT_DISPLAY=""
# A flag whose value is missing must fail loudly: with `shift 2` on a single
# remaining argument the loop would spin forever and hang the caller.
need_value() { [ "$2" -ge 2 ] || { echo "FAIL: $1 requires a value"; exit 1; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --scope) need_value "$1" $#; SCOPE="$2"; shift 2 ;;
    --base) need_value "$1" $#; BASE="$2"; SCOPE="base"; shift 2 ;;
    --commit) need_value "$1" $#; COMMIT="$2"; SCOPE="commit"; shift 2 ;;
    --deep) DEEP=1; shift ;;
    --model) need_value "$1" $#; MODEL_ARG="$2"; shift 2 ;;
    --effort) need_value "$1" $#; EFFORT_ARG="$2"; shift 2 ;;
    --out) need_value "$1" $#; OUT="$2"; shift 2 ;;
    --yes) FORCE=1; shift ;;
    --why) need_value "$1" $#; FOCUS="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "SKIP: unknown argument '$1' — nothing was reviewed"; exit 0 ;;
  esac
done

skip() { echo "SKIP: $1"; exit 0; }

# --- Gate 1: Codex CLI present? Absent is normal, not an error. ---------------
command -v codex >/dev/null 2>&1 || skip "codex CLI not installed — review step skipped, continue as usual"

# --- Gate 2: repository ------------------------------------------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "not a git repository — nothing to review"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# --- Gate 3: consent ---------------------------------------------------------
# .agents/codex-review.json = {"enabled": true, "model": "...", "effort": "..."}
# No file means the human was never asked → do not spend their quota.
#
# Contract (F-04): a recorded refusal is unbreakable in every environment,
# and so is "we could not verify what was recorded". --yes only ever means
# "the human just asked for this run, in this turn" — it can widen the *no
# file at all* case, nothing else. Concretely: the ONLY way to proceed is
# (a) no consent file exists and --yes was given, or (b) the file exists, is
# readable, parses as valid JSON, and `.enabled` is the JSON boolean `true`.
# Every other state of the file — false, missing/non-boolean `.enabled`,
# invalid JSON, or unreadable — skips unconditionally, --yes or not, because
# each of those states is indistinguishable from "someone recorded false and
# we can't prove otherwise". A quoted `"true"` string does not count either:
# only pf-spec writes this file, always with a real JSON boolean.
CFG="$REPO_ROOT/.agents/codex-review.json"
MODEL=""; EFFORT=""
if [ -f "$CFG" ]; then
  if [ ! -r "$CFG" ]; then
    skip "consent file exists but is not readable (check permissions) — .agents/codex-review.json"
  fi
  if command -v jq >/dev/null 2>&1; then
    ENABLED="$(jq -r 'if (type=="object") and (.enabled|type)=="boolean" then (.enabled|tostring) else "unknown" end' "$CFG" 2>/dev/null)" || ENABLED="unknown"
    MODEL="$(jq -r '.model // ""' "$CFG" 2>/dev/null)"
    EFFORT="$(jq -r '.effort // ""' "$CFG" 2>/dev/null)"
  elif command -v python3 >/dev/null 2>&1; then
    ENABLED="$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1], encoding="utf-8-sig"))
except Exception:
    print("unknown"); sys.exit()
v=d.get("enabled") if isinstance(d,dict) else None
print("true" if v is True else "false" if v is False else "unknown")' "$CFG" 2>/dev/null)" || ENABLED="unknown"
    MODEL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1], encoding="utf-8-sig")).get("model",""))' "$CFG" 2>/dev/null)"
    EFFORT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1], encoding="utf-8-sig")).get("effort",""))' "$CFG" 2>/dev/null)"
  else
    # Neither reader available: cannot verify the recorded value, so this is
    # NOT a case --yes can widen (unlike "no file") — say so and stop.
    skip "consent file exists but neither jq nor python3 is available to read it"
  fi
  [ -n "$ENABLED" ] || ENABLED="unknown"
  # "true"/"True"/"TRUE" must mean the same thing on every machine.
  ENABLED="$(printf '%s' "$ENABLED" | tr '[:upper:]' '[:lower:]')"
  case "$ENABLED" in
    true) : ;; # verified consent — fall through to Gate 4
    false) skip "the human declined Codex review for this project (.agents/codex-review.json) — ask them again before overriding" ;;
    *) skip "consent file exists but could not be parsed as JSON with a boolean 'enabled' — .agents/codex-review.json" ;;
  esac
else
  # No file at all: never asked. --yes means "asked and answered yes, right
  # now" — the one case this flag is allowed to widen.
  if [ "$FORCE" != 1 ]; then
    skip "Codex review not enabled for this project (.agents/codex-review.json) — ask the human once, then continue"
  fi
fi

# --- Gate 4: does the diff contain anything executable? -----------------------
# Docs-only changes burn quota for "no executable code changed". Configs, CI
# workflows and data schemas are NOT docs — pf-auto counts them as executable
# risk, so they stay in scope; only prose, images and lockfiles are filtered out.
# F-19: -z gives NUL-separated paths; converting to one-per-line is needed
# because grep/sort below are line-oriented (and NUL cannot live in a bash
# variable at all — that conversion cannot be skipped). It is unsafe if a
# path itself contains a literal newline: such a path would silently split
# into two fake entries downstream. Detect that in the RAW NUL stream first —
# a byte-for-byte newline count, no encoding assumptions — and refuse rather
# than guess. wc -l counts '\n' bytes regardless of whether the file ends
# with one, so this works identically on GNU and BSD wc.
nul_to_lines() {
  [ "$(wc -l < "$1")" -eq 0 ] || return 1
  tr '\0' '\n' < "$1"
}
# Portable form: GNU mktemp (Linux, incl. ubuntu-latest and Linux/WSL users
# of this skill) rejects a bare `-t <prefix>` ("too few X's in template");
# BSD mktemp (macOS) accepts it. An explicit template with X's works
# identically on both (verified T-016).
RAW="$(mktemp "${TMPDIR:-/tmp}/codex-review-files.XXXXXXXX")" || skip "cannot create temp file"
# Every skip() from here until RAW is consumed must clear it first, or an
# empty temp file leaks on each early exit (--base/--commit with no value,
# an unresolvable ref, a newline in a path).
skip_rm() { rm -f "$RAW"; skip "$1"; }
case "$SCOPE" in
  # -z + NUL: git quotes any path containing a space or non-ASCII, and a quoted
  # "моя дока.md" no longer matches the docs filter. Two clean path lists beat
  # parsing status prefixes.
  uncommitted) { git -c core.quotePath=false diff --name-only -z HEAD 2>/dev/null
                 # The index separately: a repo with no commits has no
                 # HEAD, and a staged file is neither in the diff nor
                 # in --others.
                 git -c core.quotePath=false diff --cached --name-only -z 2>/dev/null
                 git -c core.quotePath=false ls-files --others --exclude-standard -z 2>/dev/null
               } > "$RAW"
               FILES="$(nul_to_lines "$RAW")" || skip_rm "a changed path contains a newline character — refusing to guess file boundaries (F-19); review it manually"
               FILES="$(printf '%s\n' "$FILES" | sort -u)" ;;
  base)        [ -n "$BASE" ] || skip_rm "--base requires a ref"
               # Ref goes into a prompt telling Codex to run the diff command,
               # so it must be a ref git itself recognises — never free text.
               git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1 || skip_rm "unknown ref '$BASE' — nothing to review"
               # F-10: a *validated* ref can still carry shell metacharacters
               # (';', '$()', backticks are legal bytes in a Git ref name) —
               # resolve to the full hex commit SHA now, once, and use only
               # that downstream (diff command, prompt text, codex argv).
               BASE_DISPLAY="$BASE"
               BASE="$(git rev-parse --verify --quiet "${BASE}^{commit}")" || skip_rm "cannot resolve '$BASE_DISPLAY' to a commit"
               git -c core.quotePath=false diff --name-only -z "$BASE...HEAD" > "$RAW" 2>/dev/null
               FILES="$(nul_to_lines "$RAW")" || skip_rm "a changed path contains a newline character — refusing to guess file boundaries (F-19); review it manually" ;;
  commit)      [ -n "$COMMIT" ] || skip_rm "--commit requires a sha"
               git rev-parse --verify --quiet "${COMMIT}^{commit}" >/dev/null 2>&1 || skip_rm "unknown commit '$COMMIT' — nothing to review"
               COMMIT_DISPLAY="$COMMIT"
               COMMIT="$(git rev-parse --verify --quiet "${COMMIT}^{commit}")" || skip_rm "cannot resolve '$COMMIT_DISPLAY' to a commit"
               git -c core.quotePath=false show --name-only --format= -z "$COMMIT" > "$RAW" 2>/dev/null
               FILES="$(nul_to_lines "$RAW")" || skip_rm "a changed path contains a newline character — refusing to guess file boundaries (F-19); review it manually" ;;
  *)           skip_rm "unknown scope '$SCOPE'" ;;
esac
rm -f "$RAW"
[ -n "${FILES//[[:space:]]/}" ] || skip "empty diff — nothing to review"

CODE_FILES="$(printf '%s\n' "$FILES" \
  | grep -vE '\.(md|markdown|txt|rst|adoc|csv|svg|png|jpe?g|gif|webp|pdf|lock)$' \
  | grep -vE '(^|/)(CHANGELOG|README|LICENSE|NOTICE)(\.[A-Za-z]+)?$' \
  | grep -vE '(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Cargo\.lock|poetry\.lock|composer\.lock)$' \
  | grep -vE '(^|/)\.agents/(codex-review|context-budget)\.json$' || true)"
if [ -z "${CODE_FILES//[[:space:]]/}" ]; then
  skip "diff has no code files (docs/config only) — review adds nothing here"
fi
CODE_COUNT="$(printf '%s\n' "$CODE_FILES" | grep -c . || true)"

# --- Model and effort --------------------------------------------------------
# Fast lane: luna at max — a full-strength reviewer that still answers in minutes.
# Deep lane (--deep, e.g. an autopilot milestone): a frontier model at xhigh.
if [ "$DEEP" = 1 ]; then
  # --deep must actually be deep: a project config pinning the fast lane would
  # otherwise silently downgrade an autopilot milestone pass.
  MODEL="gpt-5.6-sol"; EFFORT="xhigh"
else
  MODEL="${MODEL:-gpt-5.6-luna}"; EFFORT="${EFFORT:-max}"
fi
# Explicit flags win over both the config and --deep (debugging, cheap re-runs).
[ -n "$MODEL_ARG" ] && MODEL="$MODEL_ARG"
[ -n "$EFFORT_ARG" ] && EFFORT="$EFFORT_ARG"
# `ultra` is banned by house rule (max reasoning + automatic delegation to
# sub-agents: slowest, most expensive, unpredictable spend). Downgrade loudly
# instead of silently obeying, whatever the source of the value.
if [ "$EFFORT" = "ultra" ]; then
  echo "NOTE: effort 'ultra' is not used here — falling back to 'max'." >&2
  EFFORT="max"
fi
# luna tops out at max; ultra exists only on sol/terra. Nothing to clamp now that
# ultra is banned, but the ceiling is worth stating where the value is chosen.
TIMEOUT=1800
case "$EFFORT" in
  low) TIMEOUT=150 ;; medium) TIMEOUT=300 ;; high) TIMEOUT=600 ;;
  xhigh) TIMEOUT=1200 ;; max|ultra) TIMEOUT=1800 ;;
esac
# PF_CODEX_TIMEOUT — manual watchdog override (tests, debugging).
case "${PF_CODEX_TIMEOUT:-}" in ''|*[!0-9]*) : ;; *) TIMEOUT="$PF_CODEX_TIMEOUT" ;; esac
# Grace period between SIGTERM and the final group-wide SIGKILL (F-11).
# PF_CODEX_GRACE mirrors PF_CODEX_TIMEOUT — manual override for tests/debugging.
GRACE=15
case "${PF_CODEX_GRACE:-}" in ''|*[!0-9]*) : ;; *) GRACE="$PF_CODEX_GRACE" ;; esac

# --- Output file -------------------------------------------------------------
# F-05: a user-supplied --out must never touch a byte that was already there.
# Only OUR OWN default path gets the "-N" collision dance (it only ever
# steps sideways to a fresh name, never into something that exists); a path
# the human gave us is either free to use, or the run stops without writing
# anything — file, directory, FIFO, device, or symlink (even a dangling
# one, so we never write through it to wherever it points).
STAMP="$(date +%Y-%m-%d-%H%M%S)"
OWN_DIR=0
if [ -z "$OUT" ]; then
  OUT="$REPO_ROOT/workspace/runs/codex-review/$STAMP-$SCOPE.md"
  OWN_DIR=1   # only our own default directory may get a .gitignore
fi
# A relative --out must be absolutized HERE, before the guard below and
# before `cd "$REPO_ROOT"` further down (F-05 fix-round, T-017 workflow
# pilot): the guard's existence check and the noclobber test-write both run
# in the invocation cwd, but the real write at the bottom of this script
# happens after the cd. Left relative, those two resolve against different
# directories — the guard protects one file while a plain truncating `>`
# silently clobbers a different one, behind a reported "OK". Absolutizing
# once, right after OUT is decided, makes every later use of $OUT — guard,
# mkdir, the final write — agree on the same path regardless of the cd.
case "$OUT" in
  /*) : ;;                 # already absolute (also true for the default above)
  *)  OUT="$PWD/$OUT" ;;   # relative to the cwd the script was invoked from
esac
if [ "$OWN_DIR" = 1 ]; then
  if [ -e "$OUT" ] || [ -L "$OUT" ]; then
    n=2
    while [ -e "${OUT%.md}-$n.md" ] || [ -L "${OUT%.md}-$n.md" ]; do n=$(( n + 1 )); done
    OUT="${OUT%.md}-$n.md"
  fi
else
  [ -d "$OUT" ] && skip "--out points at a directory ($OUT) — give it a file path"
  if [ -e "$OUT" ] || [ -L "$OUT" ]; then
    skip "--out $OUT already exists — refusing to overwrite it (F-05), pick a new path"
  fi
fi
OUT_DIR="$(dirname "$OUT")"
mkdir -p "$OUT_DIR" 2>/dev/null || skip "cannot create output directory for $OUT"
# Reports are working material, not deliverables: keep them out of git so the
# tree stays clean (pf-auto step 8 requires exactly that). A local .gitignore
# inside our own directory touches nothing the project owns.
if [ "$OWN_DIR" = 1 ] && [ ! -e "$OUT_DIR/.gitignore" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf '*\n' > "$OUT_DIR/.gitignore" 2>/dev/null || true
fi
# noclobber (set -C): the shell itself refuses to open an existing path for
# truncation, closing the gap between the check above and this write (TOCTOU).
( set -C; : > "$OUT" ) 2>/dev/null || skip "cannot write the report to $OUT (already exists, or not writable)"

# --- Run ---------------------------------------------------------------------
# </dev/null is mandatory: `codex exec` always reads stdin and hangs forever
# when stdin is neither a TTY nor closed (hooks, background tasks, scripts).
# 2>/dev/null drops the reasoning stream so the file holds the result only.
if [ -z "$FOCUS" ]; then
  # Native reviewer: Codex frames the review itself, so our blind spot does not
  # leak into the prompt.
  set -- exec --skip-git-repo-check review
  case "$SCOPE" in
    uncommitted) set -- "$@" --uncommitted ;;
    base)        set -- "$@" --base "$BASE" ;;
    commit)      set -- "$@" --commit "$COMMIT" ;;
  esac
  set -- "$@" -m "$MODEL" --config "model_reasoning_effort=\"$EFFORT\"" \
    --config "sandbox_mode=\"read-only\""
else
  # `codex exec review` refuses a positional prompt together with any scope flag
  # (--uncommitted / --base / --commit), so a focused pass goes through plain
  # `codex exec` with the diff command spelled out. Same read-only sandbox.
  case "$SCOPE" in
    uncommitted) DIFF_CMD="git status --short --untracked-files=all && git diff HEAD (untracked files are NOT in that diff — read each '??' path from the status output before judging)" ;;
    base)        DIFF_CMD="git diff $BASE...HEAD" ;;
    commit)      DIFF_CMD="git show $COMMIT" ;;
  esac
  set -- exec --skip-git-repo-check --sandbox read-only \
    -m "$MODEL" --config "model_reasoning_effort=\"$EFFORT\"" \
    "Review the changes in this repository. Get them with: $DIFF_CMD
Focus of this review: $FOCUS
Report every problem on its own line as: - [P1|P2|P3] short title — file:lines
followed by an indented explanation. P1 = breaks or endangers something, P2 =
real defect, P3 = worth fixing. Report nothing you cannot point to in the diff."
fi

TMP="$(mktemp "${TMPDIR:-/tmp}/codex-review.XXXXXXXX")" || skip "cannot create temp file"
ERR="$(mktemp "${TMPDIR:-/tmp}/codex-review-err.XXXXXXXX")" || skip "cannot create temp file"
START="$(date +%s)"
# stderr goes to a file rather than /dev/null: it holds the reasoning stream we
# do not want in the report, but also the only explanation when a run dies.
# No subshell wrapper: $! must be Codex itself, otherwise the watchdog kills the
# wrapper and leaves the real process running (orphaned, still burning quota).
cd "$REPO_ROOT" || skip "cannot enter $REPO_ROOT"
set -m 2>/dev/null || true   # own process group for Codex → we can signal its whole tree
codex "$@" </dev/null 2>"$ERR" >"$TMP" &
CODEX_PID=$!
set +m 2>/dev/null || true
# Watchdog: Codex emits nothing until it finishes, so a hung run would block the
# whole session. Kill it at the effort's budget and report a failure, never a
# silent "clean".
# The watchdog MUST NOT hold this script's stdout: a caller doing RESULT=$(...)
# reads until every writer closes the pipe, so a lingering `sleep` would hang it
# long after the review succeeded. Hence >/dev/null on the whole subshell.
( waited=0
  while [ "$waited" -lt "$TIMEOUT" ]; do
    kill -0 "$CODEX_PID" 2>/dev/null || exit 0   # Codex done — watchdog not needed
    sleep 1
    waited=$(( waited + 1 ))
  done
  kill -0 "$CODEX_PID" 2>/dev/null || exit 0
  kill -TERM "-$CODEX_PID" 2>/dev/null || kill -TERM "$CODEX_PID" 2>/dev/null
  # A process that ignores or delays SIGTERM would make the timeout advisory —
  # give it $GRACE seconds to die politely, then make it non-negotiable.
  sleep "$GRACE"
  # No "is the leader still alive" check here: the leader may be gone while a
  # child that ignored SIGTERM lives on. The group gets SIGKILL either way.
  kill -KILL "-$CODEX_PID" 2>/dev/null || kill -KILL "$CODEX_PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
# The shell's own "Terminated" note when a signaled background job is waited
# on is noise in output an agent forwards to a human; silence it via
# 2>/dev/null on the `wait`, the status comes from $?.
{ wait "$CODEX_PID"; RC=$?; } 2>/dev/null
# F-11: no `disown`, and no race to `pkill`/`kill` the watchdog to cut its
# sleep short. Confirmed empirically: on bash 3.2 (macOS system /bin/bash,
# what `env bash` resolves to here) `wait` on a disowned PID returns
# immediately WITHOUT actually waiting — so the old disown+pkill+kill combo
# let this script return before the watchdog's pending group-wide SIGKILL
# ever ran, leaving a SIGTERM-resistant descendant alive forever, and it
# depended on `pkill` besides (undeclared, and not always installed). A
# plain, non-disowned `wait` blocks until the watchdog is genuinely done —
# either a fast self-exit (leader already gone, noticed on its next <=1s
# poll) or the full TERM -> grace -> KILL escalation completing its cleanup.
{ wait "$WATCHDOG"; } 2>/dev/null
ELAPSED=$(( $(date +%s) - START ))

# --- Result ------------------------------------------------------------------
# `codex exec review` exits 0 even when it finds problems, so the verdict comes
# from the text. An empty file means the run died — that is a failure, not "clean".
if [ "$RC" != 0 ] || [ ! -s "$TMP" ]; then
  echo "FAIL: Codex review did not produce output (exit=$RC, ${ELAPSED}s, limit ${TIMEOUT}s). Treat as 'not reviewed', never as 'clean'."
  if [ -s "$ERR" ]; then
    echo "STDERR (last lines):"
    grep -vE '^\s*$' "$ERR" | tail -5
  fi
  rm -f "$TMP" "$ERR"
  exit 1
fi

{
  echo "# Codex review — $STAMP"
  echo
  echo "- scope: \`$SCOPE\`${BASE_DISPLAY:+ (base $BASE_DISPLAY -> $BASE)}${COMMIT_DISPLAY:+ ($COMMIT_DISPLAY -> $COMMIT)}"
  echo "- model: \`$MODEL\`, effort: \`$EFFORT\`, elapsed: ${ELAPSED}s"
  echo "- code files in diff: $CODE_COUNT"
  echo "- sandbox: read-only (Codex could not modify anything)"
  echo
  echo "---"
  echo
  cat "$TMP"
} > "$OUT" 2>/dev/null
# An unwritable --out path would otherwise end in "OK, 0 findings" — a review
# that never reached the caller reported as a clean one.
if [ ! -f "$OUT" ] || [ ! -s "$OUT" ]; then
  echo "FAIL: review ran (${ELAPSED}s) but the report could not be written to $OUT. Treat as 'not reviewed'."
  rm -f "$TMP" "$ERR"
  exit 1
fi
rm -f "$TMP" "$ERR"

# Only list lines count: Codex repeats markers in its intro paragraph, and the
# header above is ours — counting those would inflate the tally.
P1=$(grep -cE '^[-*] +\[P1\]' "$OUT" || true)
P2=$(grep -cE '^[-*] +\[P2\]' "$OUT" || true)
P3=$(grep -cE '^[-*] +\[P3\]' "$OUT" || true)
TOTAL=$(( P1 + P2 + P3 ))

# F-09: `codex exec review` exits 0 whether it reviewed anything or not, so a
# provider/CLI failure that lands on stdout (auth errors, rate limits, a
# crashed sub-process) previously read as "0 findings" — indistinguishable
# from a genuinely clean review. Zero findings AND text that matches a known
# failure signature is reclassified as "not reviewed", never "clean". This
# is a disclosed heuristic, not a formal contract with the provider: it
# catches the concrete failure shapes seen in practice, not everything that
# could ever go wrong — read the report when a result looks surprising.
FAILURE_SIGNATURE='(^|[^A-Za-z])(auth(entication)?[ _-]?fail(ed|ure)?|unauthori[sz]ed|forbidden|rate[ -]?limit(ed)?|quota[ -]?exceeded|invalid[ _-]?api[ _-]?key|no such (model|provider)|(connection|network) (refused|reset|error)|internal server error|bad gateway|service unavailable|gateway timeout|request timed out|traceback \(most recent call last\)|unhandled exception|panic:|fatal error)([^A-Za-z]|$)'
if [ "$TOTAL" = 0 ] && grep -qiE "$FAILURE_SIGNATURE" "$OUT"; then
  echo "FAIL: not reviewed — Codex exited 0 with no findings, but the output matches a known error/failure pattern, not a completed review."
  echo "REPORT: $OUT (raw output kept for inspection)"
  grep -iE "$FAILURE_SIGNATURE" "$OUT" | head -3
  exit 1
fi

echo "OK: Codex review finished in ${ELAPSED}s ($MODEL/$EFFORT, $CODE_COUNT code files)"
echo "REPORT: $OUT"
echo "FINDINGS: P1=$P1 P2=$P2 P3=$P3 (total $TOTAL)"
if [ "$TOTAL" = 0 ]; then
  echo "VERDICT: no prioritized findings — read the report before trusting this"
  sed -n '9,14p' "$OUT"
else
  echo "VERDICT: findings present — read $OUT in full"
  grep -nE '^[-*] +\[P[123]\]' "$OUT" | head -10
fi
exit 0
