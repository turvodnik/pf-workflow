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
CFG="$REPO_ROOT/.agents/codex-review.json"
MODEL=""; EFFORT=""
if [ -f "$CFG" ] && [ -r "$CFG" ]; then
  if command -v jq >/dev/null 2>&1; then
    ENABLED="$(jq -r '.enabled // false' "$CFG" 2>/dev/null)"
    MODEL="$(jq -r '.model // ""' "$CFG" 2>/dev/null)"
    EFFORT="$(jq -r '.effort // ""' "$CFG" 2>/dev/null)"
  elif command -v python3 >/dev/null 2>&1; then
    ENABLED="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1], encoding="utf-8-sig"));print(str(d.get("enabled",False)).lower())' "$CFG" 2>/dev/null)"
    MODEL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1], encoding="utf-8-sig")).get("model",""))' "$CFG" 2>/dev/null)"
    EFFORT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1], encoding="utf-8-sig")).get("effort",""))' "$CFG" 2>/dev/null)"
  elif [ "$FORCE" = 1 ]; then
    # --yes means the human just asked for this run: no reader needed.
    ENABLED="true"
  else
    # Neither reader available: say so instead of blaming the consent file.
    skip "consent file exists but neither jq nor python3 is available to read it"
  fi
  # "true"/"True"/"TRUE" must mean the same thing on every machine.
  ENABLED="$(printf '%s' "$ENABLED" | tr '[:upper:]' '[:lower:]')"
else
  ENABLED="false"
fi
if [ "$ENABLED" = "false" ] && [ -f "$CFG" ] && [ -r "$CFG" ]; then
  # An explicit "no" is a decision, not a missing answer: --yes must not step
  # over it. pf-spec writes {"enabled": false} exactly so nobody asks again.
  skip "the human declined Codex review for this project (.agents/codex-review.json) — ask them again before overriding"
fi
if [ "$FORCE" != 1 ] && [ "$ENABLED" != "true" ]; then
  skip "Codex review not enabled for this project (.agents/codex-review.json) — ask the human once, then continue"
fi

# --- Gate 4: does the diff contain anything executable? -----------------------
# Docs-only changes burn quota for "no executable code changed". Configs, CI
# workflows and data schemas are NOT docs — pf-auto counts them as executable
# risk, so they stay in scope; only prose, images and lockfiles are filtered out.
case "$SCOPE" in
  # -z + NUL: git quotes any path containing a space or non-ASCII, and a quoted
  # "моя дока.md" no longer matches the docs filter. Two clean path lists beat
  # parsing status prefixes.
  uncommitted) FILES="$( { git -c core.quotePath=false diff --name-only -z HEAD 2>/dev/null
                           # The index separately: a repo with no commits has no
                           # HEAD, and a staged file is neither in the diff nor
                           # in --others.
                           git -c core.quotePath=false diff --cached --name-only -z 2>/dev/null
                           git -c core.quotePath=false ls-files --others --exclude-standard -z 2>/dev/null
                         } | tr '\0' '\n' | sort -u )" ;;
  base)        [ -n "$BASE" ] || skip "--base requires a ref"
               # Ref goes into a prompt telling Codex to run the diff command,
               # so it must be a ref git itself recognises — never free text.
               git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1 || skip "unknown ref '$BASE' — nothing to review"
               FILES="$(git -c core.quotePath=false diff --name-only -z "$BASE...HEAD" 2>/dev/null | tr '\0' '\n')" ;;
  commit)      [ -n "$COMMIT" ] || skip "--commit requires a sha"
               git rev-parse --verify --quiet "${COMMIT}^{commit}" >/dev/null 2>&1 || skip "unknown commit '$COMMIT' — nothing to review"
               FILES="$(git -c core.quotePath=false show --name-only --format= -z "$COMMIT" 2>/dev/null | tr '\0' '\n')" ;;
  *)           skip "unknown scope '$SCOPE'" ;;
esac
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

# --- Output file -------------------------------------------------------------
STAMP="$(date +%Y-%m-%d-%H%M%S)"
if [ -z "$OUT" ]; then
  OUT="$REPO_ROOT/workspace/runs/codex-review/$STAMP-$SCOPE.md"
fi
[ -d "$OUT" ] && skip "--out points at a directory ($OUT) — give it a file path"
OUT_DIR="$(dirname "$OUT")"
mkdir -p "$OUT_DIR" 2>/dev/null || skip "cannot create output directory for $OUT"
# Reports are working material, not deliverables: keep them out of git so the
# tree stays clean (pf-auto step 8 requires exactly that). A local .gitignore
# inside our own directory touches nothing the project owns.
if [ ! -e "$OUT_DIR/.gitignore" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf '*\n' > "$OUT_DIR/.gitignore" 2>/dev/null || true
fi
: > "$OUT" 2>/dev/null || skip "cannot write the report to $OUT"

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

TMP="$(mktemp -t codex-review)" || skip "cannot create temp file"
ERR="$(mktemp -t codex-review-err)" || skip "cannot create temp file"
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
  # give it 15s to die politely, then make it non-negotiable.
  sleep 15
  kill -0 "$CODEX_PID" 2>/dev/null || exit 0
  kill -KILL "-$CODEX_PID" 2>/dev/null || kill -KILL "$CODEX_PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
disown "$WATCHDOG" 2>/dev/null || true
# The shell's own "Terminated: 15" note when the watchdog fires is noise in
# output the agent forwards to a human; silence it, the status comes from $?.
{ wait "$CODEX_PID"; RC=$?; } 2>/dev/null
# Kill the watchdog AND its sleeping child: killing only the subshell leaves the
# `sleep` alive for the rest of the timeout budget.
# Children first: killing the subshell reparents its `sleep` to init, and then
# `pkill -P` can no longer find it — it would idle out the whole budget.
pkill -P "$WATCHDOG" 2>/dev/null
kill "$WATCHDOG" 2>/dev/null
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
  echo "- scope: \`$SCOPE\`${BASE:+ (base $BASE)}${COMMIT:+ ($COMMIT)}"
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
