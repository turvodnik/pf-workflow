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
#   codex-review.sh --async [same flags]     detach, print "PENDING: <marker>", exit 0
#   codex-review.sh --wait <marker> [--timeout <seconds>]   block until the verdict
#
# --async runs the very same review in a DETACHED background process and returns
# immediately with the path of a marker file. Two things follow from "detached":
# there is no agent Bash-tool ceiling over that process, so the effort's full
# watchdog budget applies again; and a diff larger than ASYNC_CHUNK_MAX_FILES
# code files is split into groups reviewed one after another, folded into that
# one marker. The background run appends its ordinary verdict line
# (OK:/SKIP:/FAIL:), then "ASYNC-DONE: <exit code>", and last of all writes the
# authoritative sign-off to the sibling file "<marker>.done".
#
# --wait polls for that .done file — never for a line inside the marker, which
# also carries the tail of codex's stderr and therefore fragments of the diff
# under review. It prints the verdict block and exits with the same code a
# synchronous run would have. A timeout (default 900s) prints
# "FAIL: wait timeout" and exits 1: "not finished yet" is never reported as
# success, and it is not the same thing as "not reviewed" — re-run --wait.
#
# The full report is written to a file; stdout carries only a short digest, so a
# calling agent spends ~15 lines of context instead of the whole review (§13).

set -uo pipefail

# --- Internal seams: read once, then removed from the environment ------------
# PF_CODEX_ASYNC / PF_CODEX_CHUNK_FILE / PF_CODEX_ASYNC_DONE_FILE are set by
# this script when it re-invokes itself, never by a caller (like the older
# PF_CODEX_TIMEOUT / PF_CODEX_GRACE / PF_CODEX_PRINT_BUDGET seams). They are
# unset immediately so nothing this process spawns — codex included — inherits
# a flag that lifts a safety budget.
IS_ASYNC=0
[ "${PF_CODEX_ASYNC:-0}" = 1 ] && IS_ASYNC=1
CHUNK_FILE="${PF_CODEX_CHUNK_FILE:-}"
DONE_FILE="${PF_CODEX_ASYNC_DONE_FILE:-}"
# HEAD, pinned to a sha by the async launcher. `--base <ref>` was advertised as
# an immutable scope and was not one: the diff command handed to codex said
# `git diff <sha>...HEAD`, and codex resolves HEAD itself, minutes later, in a
# repository that may have moved (gate 2026-09-04). Empty on the synchronous
# path, where the window is seconds and the literal HEAD is what has always
# been sent — which is why that path stays byte-identical.
HEAD_PIN="${PF_CODEX_HEAD_PIN:-}"
# The private copy of this script a detached run executes; the run deletes it on
# the way out. See the launcher for why it exists.
SELF_COPY="${PF_CODEX_SELF_COPY:-}"
unset PF_CODEX_ASYNC PF_CODEX_CHUNK_FILE PF_CODEX_ASYNC_DONE_FILE PF_CODEX_HEAD_PIN PF_CODEX_SELF_COPY
# A chunk list means something only inside a detached run. On its own it would
# silently narrow an ordinary review to somebody else's file list and report
# the result as a full one.
[ "$IS_ASYNC" = 1 ] || CHUNK_FILE=""
[ "$IS_ASYNC" = 1 ] || HEAD_PIN=""

# The detached child of an --async run signs off twice: a human-readable line
# at the end of the marker, and then the authoritative sign-off in a sibling
# `<marker>.done` file. In that order, so the existence of `.done` proves the
# marker is complete.
#
# Why two files and not one line (P1, gate 2026-09-04): on a failed run this
# script copies the tail of codex's stderr into its output, and that stream
# carries fragments of the diff under review. A diff that adds a line reading
# `ASYNC-DONE: 0` at column 0 — this very ticket's diff does — would land in
# the marker and could satisfy a waiter that trusted the marker alone. The
# `.done` file is written by nothing but this trap, so it cannot be forged by
# reviewed content.
#
# Both are appended by an EXIT trap rather than at each of this script's ~30
# exits, so no future exit path can forget them — and neither survives a
# SIGKILL, which is exactly what makes "killed" distinguishable from
# "finished". Chunk children are excluded: their output is captured and folded
# by the coordinator, which owns the one sign-off for the whole marker.
if [ "$IS_ASYNC" = 1 ] && [ -z "$CHUNK_FILE" ]; then
  _async_signoff() {
    local rc=$?
    echo "ASYNC-DONE: $rc"
    [ -n "$DONE_FILE" ] && printf "ASYNC-DONE: %s\n" "$rc" > "$DONE_FILE"
    [ -n "$SELF_COPY" ] && rm -f "$SELF_COPY"
    :
  }
  trap _async_signoff EXIT
fi

SCOPE="uncommitted"; BASE=""; COMMIT=""; DEEP=0; OUT=""; FORCE=0; FOCUS=""
MODEL_ARG=""; EFFORT_ARG=""
# Async mode. WAIT_TIMEOUT_SET exists so "--timeout without --wait" can be
# refused instead of silently ignored: an undefined flag combination that
# quietly does nothing is how a caller ends up believing it waited.
ASYNC=0; WAIT_FILE=""; WAIT_TIMEOUT=900; WAIT_TIMEOUT_SET=0
# FWD — the argv to hand to the detached child and to each chunk child, i.e.
# everything EXCEPT the mode flags themselves. Rebuilt token by token inside
# the parse loop rather than filtered afterwards: filtering "$@" for the
# string --async would also delete it when it is somebody's --why value.
FWD=()
fwd1() { FWD[${#FWD[@]}]="$1"; }
fwd2() { FWD[${#FWD[@]}]="$1"; FWD[${#FWD[@]}]="$2"; }
# Human-readable ref text for the report header (F-10 resolves BASE/COMMIT
# themselves to a bare hex SHA before they touch any command or prompt).
BASE_DISPLAY=""; COMMIT_DISPLAY=""
# A flag whose value is missing must fail loudly: with `shift 2` on a single
# remaining argument the loop would spin forever and hang the caller.
need_value() { [ "$2" -ge 2 ] || { echo "FAIL: $1 requires a value"; exit 1; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --scope) need_value "$1" $#; SCOPE="$2"; fwd2 "$1" "$2"; shift 2 ;;
    --base) need_value "$1" $#; BASE="$2"; SCOPE="base"; fwd2 "$1" "$2"; shift 2 ;;
    --commit) need_value "$1" $#; COMMIT="$2"; SCOPE="commit"; fwd2 "$1" "$2"; shift 2 ;;
    --deep) DEEP=1; fwd1 "$1"; shift ;;
    --model) need_value "$1" $#; MODEL_ARG="$2"; fwd2 "$1" "$2"; shift 2 ;;
    --effort) need_value "$1" $#; EFFORT_ARG="$2"; fwd2 "$1" "$2"; shift 2 ;;
    --out) need_value "$1" $#; OUT="$2"; fwd2 "$1" "$2"; shift 2 ;;
    --yes) FORCE=1; fwd1 "$1"; shift ;;
    --why) need_value "$1" $#; FOCUS="$2"; fwd2 "$1" "$2"; shift 2 ;;
    --async) ASYNC=1; shift ;;
    --wait) need_value "$1" $#; WAIT_FILE="$2"; shift 2 ;;
    --timeout) need_value "$1" $#; WAIT_TIMEOUT="$2"; WAIT_TIMEOUT_SET=1; shift 2 ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "SKIP: unknown argument '$1' — nothing was reviewed"; exit 0 ;;
  esac
done

skip() { echo "SKIP: $1"; exit 0; }

# --- helper state: why Codex gave nothing (T-127) ----------------------------
# A refusal is named, not buried in a stderr tail: the verdict line becomes
# `FAIL: QUOTA (until <date>) — ...`, `FAIL: LOGIN — ...` or `FAIL: TIMEOUT
# — ...` (our own watchdog), still a FAIL: (never a verdict), so every
# reader of the prefix keeps working and council.sh / --stats can count the
# reason. The two patterns are TWINS of council.sh's: tests/council.sh and
# drift-check level 3 (twin-pairs.txt) fail when the QUOTA_RE= / LOGIN_RE=
# lines differ between the two files — edit both or neither.
QUOTA_RE='usage limit|rate limit|quota|resource_exhausted|too many requests|(^|[^0-9])429([^0-9]|$)|limit reached|exceeded your|out of credits|insufficient (credits|balance|funds)'
LOGIN_RE='not logged in|not authenticated|unauthenticated|unauthorized|(^|[^0-9])401([^0-9]|$)|login required|please (log ?in|sign in|authenticate)|run [^ ]*login|invalid (api key|token)|no credentials|credentials? (missing|expired)|token expired'
# helper_state — reads the CLI's stderr/stdout on stdin: QUOTA | LOGIN | "".
helper_state() {
  local t; t="$(cat)"
  if printf '%s\n' "$t" | grep -qiE "$QUOTA_RE"; then echo QUOTA
  elif printf '%s\n' "$t" | grep -qiE "$LOGIN_RE"; then echo LOGIN; fi
}
# quota_until — a date quoted next to the refusal, on stdin: an ISO
# YYYY-MM-DD first, else the phrase after "try again at" / "resets" /
# "until" (letters, digits, ':' and ',' only — it lands inside our own
# verdict line, so nothing else from the stream is copied), else "".
quota_until() {
  local t d; t="$(cat | grep -iE "$QUOTA_RE")"
  d="$(printf '%s\n' "$t" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
  [ -n "$d" ] || d="$(printf '%s\n' "$t" | grep -oiE '(try again at|resets?( at| on)?|until) [A-Za-z0-9:, ]+' | head -1 | sed -E 's/^[A-Za-z]+( again at| at| on)? //; s/[ ,]+$//' | cut -c1-40)"
  printf '%s' "$d"
}

# --- untrusted passthrough ---------------------------------------------------
# Several places quote raw material back to the caller: the tail of codex's
# stderr, excerpts of its stdout, the head of the report. All of it is content
# this script did not write, and on a review of THIS repository it contains
# lines that look exactly like our own verdicts — the stderr stream echoes the
# diff under review, which is how the T-070 P1 was found in the first place.
#
# Synchronously that is only cosmetic: the caller reads one command's output
# and the real verdict is unmissable. In a marker it is not, because a marker
# is parsed later, by a machine, looking for a line at column 0 (pf-auto step 4
# does exactly that). So in the async-marker case every quoted line is indented
# with "| ", leaving exactly one column-0 verdict in the file. Outside that
# case this is `cat` — which is why the synchronous path stays byte-identical.
untrusted() {
  if [ "${IS_ASYNC:-0}" = 1 ] && [ -z "${CHUNK_FILE:-}" ]; then
    sed 's/^/| /'
  else
    cat
  fi
}

# --- Mode conflicts: named, never guessed ------------------------------------
# --async and --wait are two halves of one workflow, not one command: doing
# both in a single call would mean "detach, then block", which is just the
# synchronous run with extra steps and no way to report which half failed.
if [ "$ASYNC" = 1 ] && [ -n "$WAIT_FILE" ]; then
  echo "FAIL: --async and --wait are separate calls — start the run with --async, read it with --wait <marker>"
  exit 1
fi
if [ "$WAIT_TIMEOUT_SET" = 1 ] && [ -z "$WAIT_FILE" ]; then
  echo "FAIL: --timeout only applies to --wait (the background run keeps the effort's own watchdog budget)"
  exit 1
fi

# --- --wait: poll a marker for the verdict of a detached run -----------------
# A pure reader: it starts no review, spends no quota, and touches none of the
# gates below. What it waits for is the sibling `<marker>.done` file, never a
# line inside the marker: the marker also carries the tail of codex's stderr on
# a failed run, and that stream echoes the diff under review — content that can
# therefore contain a convincing `ASYNC-DONE: 0` of its own. Only the EXIT trap
# writes `.done`, and it writes it after the marker line, so `.done` existing
# proves both that the run finished and that the marker is whole.
if [ -n "$WAIT_FILE" ]; then
  case "$WAIT_TIMEOUT" in
    ''|*[!0-9]*) echo "FAIL: --timeout takes a whole number of seconds, got '$WAIT_TIMEOUT'"; exit 1 ;;
  esac
  DONE_MARK="$WAIT_FILE.done"
  WAITED=0
  while : ; do
    if [ -f "$DONE_MARK" ] && grep -qE '^ASYNC-DONE: [0-9]+$' "$DONE_MARK" 2>/dev/null; then
      # A sign-off with no readable marker beside it is not a result. Without
      # this the waiter printed zero bytes and returned the recorded code —
      # usually 0 — which a caller parsing text cannot tell from a clean
      # review (gate 2026-09-04). It is reachable by housekeeping, not
      # sabotage: `.done` has no .md extension, so it outlives a
      # `rm .../codex-review/*.md`, a removed worktree or a `git clean -xdf`.
      if [ ! -f "$WAIT_FILE" ]; then
        echo "FAIL: sign-off $DONE_MARK exists but its marker $WAIT_FILE is gone — the verdict text cannot be recovered, so this is 'not reviewed', never 'clean'. Re-run the review."
        exit 1
      fi
      if ! grep -q '^ASYNC-BEGIN$' "$WAIT_FILE"; then
        echo "FAIL: $WAIT_FILE is not an async marker (no ASYNC-BEGIN line) — nothing to report. Re-run the review."
        exit 1
      fi
      # A whole, signed-off marker with no verdict line in it is the same
      # silent success in a third shape (gate 2026-09-11): the waiter printed
      # whatever prose it found and returned the recorded code — usually 0 —
      # and a reader grepping ^OK:/^SKIP:/^FAIL: took the silence for "clean".
      # One verdict at column 0 is what "finished" means here; a quoted line
      # ("| " fence from untrusted()) is not ours and does not count. The
      # extraction is deliberately the same pipeline as the print below, so the
      # check and the output can never disagree. Counted, not -q: with pipefail
      # an early grep exit could SIGPIPE the sed upstream and turn a marker
      # WITH a verdict into "no verdict".
      VERDICT_LINES="$( sed -n '/^ASYNC-BEGIN$/,$p' "$WAIT_FILE" | sed '1d' | grep -vE '^ASYNC-DONE: [0-9]+$' | grep -cE '^(OK|SKIP|FAIL): ' )"
      if [ "${VERDICT_LINES:-0}" -lt 1 ]; then
        echo "FAIL: $WAIT_FILE is signed off but carries no verdict line (no ^OK:/^SKIP:/^FAIL: in it) — 'not reviewed', never 'clean'. Re-run the review."
        exit 1
      fi
      # Print to the END of the marker, not to the first ASYNC-DONE line: a
      # forged one in the middle would otherwise truncate the real verdict.
      # Our own protocol lines are dropped wherever they occur.
      sed -n '/^ASYNC-BEGIN$/,$p' "$WAIT_FILE" | sed '1d' | grep -vE '^ASYNC-DONE: [0-9]+$'
      WAIT_RC="$(grep -E '^ASYNC-DONE: [0-9]+$' "$DONE_MARK" | tail -1 | sed -E 's/^ASYNC-DONE: //')"
      case "$WAIT_RC" in ''|*[!0-9]*) WAIT_RC=1 ;; esac
      exit "$WAIT_RC"
    fi
    [ "$WAITED" -ge "$WAIT_TIMEOUT" ] && break
    sleep 1
    WAITED=$(( WAITED + 1 ))
  done
  echo "FAIL: wait timeout — no sign-off file $DONE_MARK after ${WAIT_TIMEOUT}s."
  echo "HINT: this is 'not finished yet', which is NOT the same as 'not reviewed' — the"
  echo "HINT: background run may still be working (a full-budget pass on a large diff can"
  echo "HINT: outlast the default 900s). Re-run: codex-review.sh --wait $WAIT_FILE"
  echo "HINT: If that file never appears, the run was killed — then it IS 'not reviewed',"
  echo "HINT: never 'clean'. Read $WAIT_FILE itself to see how far it got."
  exit 1
fi

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

# --- Async chunking: one number, one place -----------------------------------
# An async run whose diff carries more code files than this is reviewed in
# groups of at most this many, one child per group. Sized against the measured
# pain point, not a guess about the model: luna/max on a 73-file diff was still
# mid-review at 560s (I-035). The price is stated where it is paid — a defect
# whose cause is in one group and whose symptom is in another is invisible to
# every single pass, so the aggregate verdict says so out loud.
ASYNC_CHUNK_MAX_FILES=25
# The second half of the same decision: a chunked run costs N x the per-call
# watchdog, and nothing else was bounding it — 500 files is 20 groups, which is
# ten hours of somebody's quota spent in the background where no one is looking.
# This is the ceiling for the WHOLE run. Groups that have not started when it is
# gone do not start, and the run says so out loud instead of reporting the
# groups that did fit as if they were the diff.
ASYNC_CHUNK_TOTAL_BUDGET=3600
# Manual override, mirroring PF_CODEX_TIMEOUT — tests and debugging. Inert
# outside a chunked async run, so the synchronous path cannot see it.
case "${PF_CODEX_TOTAL_BUDGET:-}" in ''|*[!0-9]*) : ;; *) ASYNC_CHUNK_TOTAL_BUDGET="$PF_CODEX_TOTAL_BUDGET" ;; esac

# --- --async: detach and hand back a marker ----------------------------------
# Placed AFTER the four gates on purpose: every legitimate skip (no codex, not
# a repo, no consent, docs-only, empty diff) stays synchronous and instant, so
# "PENDING:" always means "codex is really going to run" and no caller ever
# waits on a marker that was only ever going to say SKIP.
#
# The child is a plain re-invocation of this same file with the same argv minus
# the mode flag — not a copy of the review logic. One code path, so the
# synchronous behaviour cannot drift from the asynchronous one.
if [ "$ASYNC" = 1 ] && [ "$IS_ASYNC" != 1 ]; then
  # "PENDING means codex will really run" has to hold for the caller-supplied
  # --out too. Without this the child would reach the F-05 guard minutes later
  # and the caller would have waited on a marker for a refusal knowable now.
  # Deliberately the SAME conditions and wording as that guard; the child still
  # enforces it, this only moves the answer forward in time.
  if [ -n "$OUT" ]; then
    [ -d "$OUT" ] && skip "--out points at a directory ($OUT) — give it a file path"
    if [ -e "$OUT" ] || [ -L "$OUT" ]; then
      skip "--out $OUT already exists — refusing to overwrite it (F-05), pick a new path"
    fi
  fi
  SELF="$0"
  case "$SELF" in /*) : ;; *) SELF="$PWD/$SELF" ;; esac
  # Both ends of a --base range are frozen HERE, at launch, and the child is
  # handed shas rather than names: BASE was already resolved by Gate 4 (F-10),
  # so only its spelling in the forwarded argv still has to be replaced, and
  # HEAD is pinned through PF_CODEX_HEAD_PIN. pf-auto step 4 (T-075) will call
  # `--async --base <wave sha>` and must get the range it asked for, not the
  # one that exists when codex gets round to running the command.
  HEAD_PINNED=""
  if [ "$SCOPE" = "base" ]; then
    HEAD_PINNED="$(git rev-parse --verify --quiet 'HEAD^{commit}')" \
      || skip "cannot resolve HEAD to a commit — nothing to review"
    _k=0; _n=${#FWD[@]}
    while [ "$_k" -lt "$_n" ]; do
      if [ "${FWD[$_k]}" = "--base" ] && [ "$(( _k + 1 ))" -lt "$_n" ]; then
        FWD[$(( _k + 1 ))]="$BASE"
      fi
      _k=$(( _k + 1 ))
    done
  fi
  ASTAMP="$(date +%Y-%m-%d-%H%M%S)"
  MARKER_DIR="$REPO_ROOT/workspace/runs/codex-review"
  mkdir -p "$MARKER_DIR" 2>/dev/null || skip "cannot create $MARKER_DIR for the async marker"
  if [ ! -e "$MARKER_DIR/.gitignore" ]; then
    printf '*\n' > "$MARKER_DIR/.gitignore" 2>/dev/null || true
  fi
  # $$ rather than the "-N" sideways dance used for reports: two async runs can
  # legitimately start inside the same second, and a PID cannot collide with a
  # live sibling.
  # Run a private SNAPSHOT of this script, not the file in the skill directory.
  # bash reads a script incrementally, by byte offset, for as long as it runs —
  # and a detached review runs for up to half an hour. Edit the canon during
  # that window and the child resumes at the same offset in different bytes,
  # executing a fragment of whatever now sits there: observed 2026-09-04 as
  # `codex-review.sh: line 725: already: command not found` (the word from
  # `--out $OUT already exists`), with the run dying before any sign-off.
  # This is not a hypothetical: the reviews most likely to be long are reviews
  # OF this skill, run while somebody is editing this skill. The copy makes a
  # run immune to later edits, and gives every chunk group the same edition.
  SELF_SNAP="$(mktemp "${TMPDIR:-/tmp}/codex-review-self.XXXXXXXX")" \
    || skip "cannot create the private script copy for the async run"
  cat "$SELF" > "$SELF_SNAP" 2>/dev/null \
    || { rm -f "$SELF_SNAP"; skip "cannot copy this script for the async run"; }
  MARKER="$MARKER_DIR/$ASTAMP-$SCOPE-async-$$.md"
  rm -f "$MARKER.done" 2>/dev/null || true
  { echo "# Codex review ASYNC — started $ASTAMP (launcher pid $$)"
    echo "#"
    echo "# Written by a DETACHED background run. It has NOT finished until the"
    echo "# sibling file '${MARKER##*/}.done' exists. Do not judge by the"
    echo "# text below: this file also carries the tail of codex's own stderr,"
    echo "# which echoes the diff under review, so a line that looks like a"
    echo "# sign-off can simply be reviewed content. Only the EXIT trap writes"
    echo "# the .done file. No .done means the run was killed from the outside —"
    echo "# that is 'not reviewed', never 'clean'."
    echo "#"
    echo "# Read it with:  codex-review.sh --wait $MARKER"
    echo "ASYNC-BEGIN"
  } > "$MARKER" 2>/dev/null || skip "cannot write the async marker $MARKER"
  # Detachment, without setsid (absent on macOS) and without nohup (an extra
  # external dependency this script does not otherwise need): `set -m` gives
  # the child its own process group, so a group-wide kill of the caller does
  # not reach it — the same mechanism this script already uses for codex —
  # `trap '' HUP` in the child does nohup's actual job, and stdin/stdout/stderr
  # are fully redirected so nothing keeps the caller's pipe open.
  set -m 2>/dev/null || true
  PF_CODEX_ASYNC=1 PF_CODEX_ASYNC_DONE_FILE="$MARKER.done" PF_CODEX_HEAD_PIN="$HEAD_PINNED" \
  PF_CODEX_SELF_COPY="$SELF_SNAP" "${BASH:-bash}" -c '
    trap "" HUP
    exec "$@"' _ "${BASH:-bash}" "$SELF_SNAP" ${FWD[@]+"${FWD[@]}"} \
    </dev/null >>"$MARKER" 2>&1 &
  ASYNC_PID=$!
  set +m 2>/dev/null || true
  disown "$ASYNC_PID" 2>/dev/null || true
  echo "PENDING: $MARKER"
  echo "HINT: read the verdict with: codex-review.sh --wait $MARKER"
  exit 0
fi

# --- Chunk child: review only the files it was handed ------------------------
# CHUNK_FILE is internal (set by the coordinator below, never by a human) and
# is already forced empty outside a detached run. The prompt tells Codex to run
# the diff itself, so restricting the scope means restricting THAT command with
# a pathspec — the file list is not merely advisory.
DIFF_PATHSPEC=""
if [ -n "$CHUNK_FILE" ]; then
  [ -r "$CHUNK_FILE" ] || skip "chunk list $CHUNK_FILE is unreadable — nothing was reviewed"
  CODE_FILES="$(cat "$CHUNK_FILE")"
  [ -n "${CODE_FILES//[[:space:]]/}" ] || skip "chunk list is empty — nothing to review"
  CODE_COUNT="$(printf '%s\n' "$CODE_FILES" | grep -c . || true)"
  # Single-quote every path and escape any quote inside it. Paths containing a
  # newline were already refused upstream (F-19), so line-at-a-time is safe;
  # the here-doc (not a pipe) keeps the accumulator in THIS shell.
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    _q="$(printf '%s' "$_p" | sed "s/'/'\\\\''/g")"
    DIFF_PATHSPEC="$DIFF_PATHSPEC '$_q'"
  done <<CHUNK_EOF
$CODE_FILES
CHUNK_EOF
fi

# --- Coordinator: split a large async diff, fold the verdicts into one marker -
if [ "$IS_ASYNC" = 1 ] && [ -z "$CHUNK_FILE" ] \
   && [ "$CODE_COUNT" -gt "$ASYNC_CHUNK_MAX_FILES" ]; then
  NCHUNKS=$(( (CODE_COUNT + ASYNC_CHUNK_MAX_FILES - 1) / ASYNC_CHUNK_MAX_FILES ))
  # Test seam, mirroring PF_CODEX_PRINT_BUDGET: report the plan and stop before
  # spending anything, so the split itself is testable without a provider.
  if [ "${PF_CODEX_PRINT_CHUNKS:-}" = 1 ]; then
    echo "CHUNKS: $NCHUNKS group(s) of at most $ASYNC_CHUNK_MAX_FILES file(s) for $CODE_COUNT code file(s)"
    _i=1
    while [ "$_i" -le "$NCHUNKS" ]; do
      _from=$(( (_i - 1) * ASYNC_CHUNK_MAX_FILES + 1 ))
      _to=$(( _i * ASYNC_CHUNK_MAX_FILES ))
      echo "CHUNK $_i/$NCHUNKS: $(printf '%s\n' "$CODE_FILES" | sed -n "${_from},${_to}p" | grep -c . || true) file(s)"
      _i=$(( _i + 1 ))
    done
    exit 0
  fi
  echo "NOTE: this run is split into $NCHUNKS group(s), reviewed one after another. Worst case it occupies a background process for ${NCHUNKS} x the per-call watchdog budget, capped at ${ASYNC_CHUNK_TOTAL_BUDGET}s for the whole run; groups still unstarted when that cap is reached will not run."
  CHUNK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-review-chunks.XXXXXXXX")" || skip "cannot create the chunk directory"
  CSELF="$0"; case "$CSELF" in /*) : ;; *) CSELF="$PWD/$CSELF" ;; esac
  AGG_RC=0; AGG_P1=0; AGG_P2=0; AGG_P3=0; AGG_OK=0; AGG_SKIP=0; AGG_FAIL=0
  CH_START="$(date +%s)"
  _i=1
  AGG_UNSTARTED=0
  while [ "$_i" -le "$NCHUNKS" ]; do
    # Whole-run budget. Checked before starting a group, never mid-flight: a
    # half-killed codex is the artefact this script exists to avoid.
    if [ "$(( $(date +%s) - CH_START ))" -ge "$ASYNC_CHUNK_TOTAL_BUDGET" ]; then
      AGG_UNSTARTED=$(( NCHUNKS - _i + 1 ))
      AGG_RC=1
      break
    fi
    _from=$(( (_i - 1) * ASYNC_CHUNK_MAX_FILES + 1 ))
    _to=$(( _i * ASYNC_CHUNK_MAX_FILES ))
    printf '%s\n' "$CODE_FILES" | sed -n "${_from},${_to}p" | grep . > "$CHUNK_DIR/chunk-$_i.txt"
    # A caller's --out must never be handed to more than one child: the second
    # would hit F-05 ("already exists — refusing to overwrite") and skip. Each
    # chunk gets its own derived path instead.
    CH_ARGS=(); _j=0; _n=${#FWD[@]}
    while [ "$_j" -lt "$_n" ]; do
      _a="${FWD[$_j]}"
      if [ "$_a" = "--out" ]; then
        CH_ARGS[${#CH_ARGS[@]}]="--out"
        CH_ARGS[${#CH_ARGS[@]}]="${OUT%.md}-chunk-$_i.md"
        _j=$(( _j + 2 )); continue
      fi
      CH_ARGS[${#CH_ARGS[@]}]="$_a"
      _j=$(( _j + 1 ))
    done
    CH_OUTPUT="$(PF_CODEX_ASYNC=1 PF_CODEX_CHUNK_FILE="$CHUNK_DIR/chunk-$_i.txt" \
      PF_CODEX_HEAD_PIN="$HEAD_PIN" \
      "${BASH:-bash}" "$CSELF" ${CH_ARGS[@]+"${CH_ARGS[@]}"} 2>&1)"; CH_RC=$?
    # Prefixed, so the aggregate below is the ONLY line in this marker that
    # starts with OK:/SKIP:/FAIL: — a reader grepping '^FAIL:' must not get an
    # ambiguous answer from a marker whose overall verdict is OK.
    printf '%s\n' "$CH_OUTPUT" | sed "s#^#chunk $_i/$NCHUNKS | #"
    # Only OK: is a reviewed group. SKIP: means "no review happened here" —
    # in this script's own vocabulary — so a skipped group is a hole in the
    # coverage, not a neutral outcome, and it poisons the run exactly like a
    # failure does. Found by the gate 2026-09-04 (RED-1): with SKIP counted as
    # harmless, 20 files out of 60 reviewed reported OK: and exit 0, which is
    # the "sum of greens" this whole script exists to refuse. Reachable without
    # any sabotage: a re-run onto the same --out, a vanished codex, a consent
    # file changed mid-run, or a group whose diff emptied under it.
    if [ "$CH_RC" != 0 ]; then
      AGG_FAIL=$(( AGG_FAIL + 1 )); AGG_RC=1
    elif printf '%s\n' "$CH_OUTPUT" | grep -q '^OK:'; then
      AGG_OK=$(( AGG_OK + 1 ))
    elif printf '%s\n' "$CH_OUTPUT" | grep -q '^SKIP:'; then
      AGG_SKIP=$(( AGG_SKIP + 1 )); AGG_RC=1
    else
      # Exit 0 with no verdict line at all: this script cannot produce that, so
      # something outside it did — treat as not reviewed, never as clean.
      AGG_FAIL=$(( AGG_FAIL + 1 )); AGG_RC=1
    fi
    _F="$(printf '%s\n' "$CH_OUTPUT" | grep -m1 '^FINDINGS: ' || true)"
    if [ -n "$_F" ]; then
      _p1="$(printf '%s' "$_F" | sed -E 's/.*P1=([0-9]+).*/\1/')"
      _p2="$(printf '%s' "$_F" | sed -E 's/.*P2=([0-9]+).*/\1/')"
      _p3="$(printf '%s' "$_F" | sed -E 's/.*P3=([0-9]+).*/\1/')"
      case "$_p1" in ''|*[!0-9]*) _p1=0 ;; esac
      case "$_p2" in ''|*[!0-9]*) _p2=0 ;; esac
      case "$_p3" in ''|*[!0-9]*) _p3=0 ;; esac
      AGG_P1=$(( AGG_P1 + _p1 )); AGG_P2=$(( AGG_P2 + _p2 )); AGG_P3=$(( AGG_P3 + _p3 ))
    fi
    _i=$(( _i + 1 ))
  done
  rm -rf "$CHUNK_DIR"
  CH_ELAPSED=$(( $(date +%s) - CH_START ))
  echo "CHUNKS: $NCHUNKS group(s) of at most $ASYNC_CHUNK_MAX_FILES file(s) — ok=$AGG_OK skipped=$AGG_SKIP failed=$AGG_FAIL unstarted=$AGG_UNSTARTED"
  echo "NOTE: this diff was reviewed in $NCHUNKS separate passes. A defect whose cause is in one group and whose symptom is in another was seen by no pass — the split is what made the review possible at all, and this is its price."
  if [ "$AGG_UNSTARTED" -gt 0 ]; then
    echo "FAIL: budget exhausted, $AGG_OK of $NCHUNKS groups reviewed — the ${ASYNC_CHUNK_TOTAL_BUDGET}s whole-run cap ran out with $AGG_UNSTARTED group(s) never started. Not reviewed, never clean."
    exit 1
  fi
  if [ "$AGG_RC" != 0 ]; then
    echo "FAIL: not reviewed — $(( AGG_FAIL + AGG_SKIP )) of $NCHUNKS group(s) produced no verdict ($AGG_FAIL failed, $AGG_SKIP skipped). A skip is 'no review happened here', not a neutral outcome; the per-group lines above are prefixed 'chunk N/M |'."
    exit 1
  fi
  echo "OK: Codex review finished in ${CH_ELAPSED}s ($NCHUNKS groups, $CODE_COUNT code files, every group reviewed)"
  echo "REPORT: one per group — see the 'chunk N/M | REPORT:' lines above"
  echo "FINDINGS: P1=$AGG_P1 P2=$AGG_P2 P3=$AGG_P3 (total $(( AGG_P1 + AGG_P2 + AGG_P3 )))"
  if [ "$(( AGG_P1 + AGG_P2 + AGG_P3 ))" = 0 ]; then
    echo "VERDICT: no prioritized findings — read the group reports before trusting this"
  else
    echo "VERDICT: findings present — read the group reports in full"
  fi
  exit 0
fi

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
# Agent-caller ceiling (2026-08-28, a week of 0-byte reports in
# one of the author's projects): every agent runs this script through a Bash tool whose
# hard ceiling is 600s. A watchdog budget above that ceiling is advisory —
# the harness kills the script first, so the FAIL line is never printed, the
# reserved report stays empty, and codex itself survives in its own process
# group (set -m below) burning quota for up to the full budget. The default
# must therefore beat the harness: 540s + 15s grace + report write < 600s.
# Measured live: luna/max on a 73-file diff was still mid-review at 560s —
# such a run now ends in an honest FAIL from our own watchdog instead of
# vanishing. A human in a real terminal (no ceiling) restores the effort's
# full budget with PF_CODEX_TIMEOUT, which stays absolute and unclamped.
# The ceiling belongs to the CALLER, not to this script: it is the agent's Bash
# tool that dies at 600s. A detached --async run has no such caller — the tool
# call that launched it returned seconds ago — so clamping there would keep
# paying for a ceiling that is not present, which is the whole reason the
# pre-pass went quiet on large diffs (retro 2026-09-03). The constant itself is
# unchanged; it is simply not applied where its stated precondition is false.
AGENT_CEILING_BUDGET=540
if [ "$IS_ASYNC" != 1 ]; then
  [ "$TIMEOUT" -gt "$AGENT_CEILING_BUDGET" ] && TIMEOUT="$AGENT_CEILING_BUDGET"
fi
# PF_CODEX_TIMEOUT — manual watchdog override (tests, debugging).
case "${PF_CODEX_TIMEOUT:-}" in ''|*[!0-9]*) : ;; *) TIMEOUT="$PF_CODEX_TIMEOUT" ;; esac
# Grace period between SIGTERM and the final group-wide SIGKILL (F-11).
# PF_CODEX_GRACE mirrors PF_CODEX_TIMEOUT — manual override for tests/debugging.
GRACE=15
case "${PF_CODEX_GRACE:-}" in ''|*[!0-9]*) : ;; *) GRACE="$PF_CODEX_GRACE" ;; esac
# Test seam: report the decided budget and stop before spending anything.
# Exists so the ceiling clamp above is testable without a 540-second wait.
if [ "${PF_CODEX_PRINT_BUDGET:-}" = 1 ]; then
  echo "BUDGET: model=$MODEL effort=$EFFORT timeout=${TIMEOUT}s grace=${GRACE}s"
  exit 0
fi

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
# The reservation is a self-explaining placeholder, not zero bytes: when an
# OUTER layer kills this script (agent Bash-tool ceiling, closed session), no
# FAIL line reaches anyone and the reserved file is all the evidence left. A
# 0-byte file reads as "mysteriously empty report"; this text names what
# happened. The real report (or an internal-timeout FAIL summary) overwrites it.
( set -C; printf '%s\n' \
  "# Codex review PENDING — run started $STAMP" \
  "" \
  "If this text is still here, the run was killed from the OUTSIDE (caller" \
  "timeout — e.g. an agent Bash-tool ceiling — or a closed session) before" \
  "this script could write any verdict. Treat as 'not reviewed', never as" \
  "'clean'. Check for a stray 'codex' process still running. Re-run with a" \
  "lighter --effort, or from a real terminal with PF_CODEX_TIMEOUT for the" \
  "full budget." > "$OUT" ) 2>/dev/null || skip "cannot write the report to $OUT (already exists, or not writable)"

# --- Run ---------------------------------------------------------------------
# </dev/null is mandatory: `codex exec` always reads stdin and hangs forever
# when stdin is neither a TTY nor closed (hooks, background tasks, scripts).
# 2>/dev/null drops the reasoning stream so the file holds the result only.
# I-033 (T-024): every run now goes through plain `codex exec` with the prompt
# spelled out — including the default, unfocused pass that used to use the
# native reviewer (`codex exec review --uncommitted|--base|--commit`).
#
# Why the native reviewer had to go: the verdict is no longer "does this look
# like an error" (a denylist that three tickets in a row failed to close) but
# "is there proof a review happened" (SENTINEL below). That proof can only be
# REQUESTED, and `codex exec review` has no prompt slot at all — the CLI
# refuses a positional prompt together with any scope flag ("the argument
# '--uncommitted' cannot be used with '[PROMPT]'"). Keeping it would leave the
# default path — the one everybody uses — without any proof of review.
#
# The cost, stated plainly: Codex no longer frames the review itself, so our
# framing (below) is what it sees. It is deliberately neutral — no focus, no
# hypothesis — unless the caller passed --why. In exchange the output format
# is contractual on every path, which it never was for the native reviewer
# whose [P1]/[P2]/[P3] lines this script was already counting on faith.
SENTINEL='CODEX-REVIEW-COMPLETE'
# PS is empty on every path except a chunk child, where it restricts the very
# command Codex is told to run. Empty, these three lines are byte-for-byte the
# ones that were here before chunking existed.
PS=""
[ -n "$DIFF_PATHSPEC" ] && PS=" --$DIFF_PATHSPEC"
case "$SCOPE" in
  uncommitted) DIFF_CMD="git status --short --untracked-files=all$PS && git diff HEAD$PS (untracked files are NOT in that diff — read each '??' path from the status output before judging)" ;;
  base)        DIFF_CMD="git diff $BASE...${HEAD_PIN:-HEAD}$PS" ;;
  commit)      DIFF_CMD="git show $COMMIT$PS" ;;
esac
PROMPT="Review the changes in this repository. Get them with: $DIFF_CMD
"
[ -n "$FOCUS" ] && PROMPT="${PROMPT}Focus of this review: $FOCUS
"
# Honesty about a partial view: without this the model reports a "missing
# caller" that is simply in another group, and the aggregate fills with
# findings that are artefacts of the split.
[ -n "$DIFF_PATHSPEC" ] && PROMPT="${PROMPT}This is one PART of a larger change: only the files named in that command are
in scope. Do not report a problem whose cause or fix lies in a file outside them.
"
# The marker requirement is the LAST line of the instruction on purpose: it is
# the one part the model must not lose track of, and the wording pins exactly
# what the number means, so an honest review cannot fail on an ambiguous count.
PROMPT="${PROMPT}Report every problem on its own line as: - [P1|P2|P3] short title — file:lines
followed by an indented explanation. P1 = breaks or endangers something, P2 =
real defect, P3 = worth fixing. Every finding must name the place in the diff it
concerns; when the problem is what the diff does NOT contain (a missing test,
check, guard or rollback), name the file:lines where it should have been. Do not
report anything you cannot anchor that way.
MANDATORY, no exceptions: the very last line of your output must be exactly
$SENTINEL: <N>
where <N> is the number of [P1]/[P2]/[P3] finding lines you wrote above. Write
$SENTINEL: 0 when you found nothing. Output that lacks that final line is
discarded as 'not reviewed', however good the review itself was."
set -- exec --skip-git-repo-check --sandbox read-only \
  -m "$MODEL" --config "model_reasoning_effort=\"$EFFORT\"" "$PROMPT"

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
  # The reason, when the stream names it: quota and login are read from the
  # text (stderr first — that is where the CLI puts refusals — then stdout);
  # a run our watchdog cut is TIMEOUT; anything else keeps the plain text.
  STATE="$(cat "$ERR" "$TMP" 2>/dev/null | helper_state)"
  case "$STATE" in
    QUOTA) UNTIL="$(cat "$ERR" "$TMP" 2>/dev/null | quota_until)"; STATE="QUOTA${UNTIL:+ (until $UNTIL)}" ;;
    LOGIN) : ;;
    *) if [ "$ELAPSED" -ge "$TIMEOUT" ] 2>/dev/null; then STATE="TIMEOUT"; else STATE=""; fi ;;
  esac
  echo "FAIL: ${STATE:+$STATE — }Codex review did not produce output (exit=$RC, ${ELAPSED}s, limit ${TIMEOUT}s). Treat as 'not reviewed', never as 'clean'."
  if [ -s "$ERR" ]; then
    echo "STDERR (last lines):"
    grep -vE '^\s*$' "$ERR" | tail -5 | untrusted
  fi
  if [ "$ELAPSED" -ge "$TIMEOUT" ] 2>/dev/null; then
    echo "HINT: killed by this script's own watchdog — $MODEL/$EFFORT simply needs more than ${TIMEOUT}s on this diff, codex itself is fine. Re-run with a lighter effort (--effort high|medium), or from a real terminal (no caller ceiling) with PF_CODEX_TIMEOUT=1800 for the full budget."
  fi
  # The reserved report must not stay a PENDING placeholder after an internal
  # verdict: overwrite it with the same FAIL so the file self-explains.
  { echo "# Codex review FAILED — $STAMP"
    echo
    echo "- scope: \`$SCOPE\`${BASE_DISPLAY:+ (base $BASE_DISPLAY -> $BASE)}${COMMIT_DISPLAY:+ ($COMMIT_DISPLAY -> $COMMIT)}"
    echo "- model: \`$MODEL\`, effort: \`$EFFORT\`, elapsed: ${ELAPSED}s, limit: ${TIMEOUT}s, exit: $RC"
    echo "- state: ${STATE:-unclassified (see the STDERR tail above)}"
    echo
    echo "No output was produced — 'not reviewed', never 'clean'."
  } > "$OUT" 2>/dev/null || true
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
# that never reached the caller reported as a clean one. `-s` alone is no
# longer enough: the reservation above pre-fills $OUT with a PENDING
# placeholder, so a failed overwrite leaves a non-empty file that is still
# not the report. The proof of the write is the header line only this block
# above produces.
if [ "$(head -1 "$OUT" 2>/dev/null)" != "# Codex review — $STAMP" ]; then
  echo "FAIL: review ran (${ELAPSED}s) but the report could not be written to $OUT. Treat as 'not reviewed'."
  rm -f "$TMP" "$ERR"
  exit 1
fi
# Shape of the raw stdout, captured before it's deleted below — the F-09
# heuristic further down needs to tell a terse provider error from genuine
# review prose, and both live only in $TMP (the header wrapped into $OUT is
# ours, not Codex's).
RAW_LINES=$(grep -c . "$TMP" 2>/dev/null || true)
RAW_CHARS=$(wc -c < "$TMP" 2>/dev/null | tr -d ' ')
RAW_BODY="$(cat "$TMP")"
rm -f "$TMP" "$ERR"

# Only list lines count: Codex repeats markers in its intro paragraph, and the
# header above is ours — counting those would inflate the tally.
#
# The tolerance here must match the tolerance granted to the marker below, and
# for the same reason: markdown dressing is the likeliest thing a real model
# does to an obedient line. The T-024 gate found the asymmetry — `- **[P1]**
# missing rollback — example.sh:3` with a CORRECT marker `: 1` was read as a
# count desync ("typically a truncated report"), i.e. an obedient review was
# refused for its formatting. So: leading indentation, any of the three list
# bullets, and emphasis around the severity token all count as the same line.
# What is still required is the positive part — a bullet and a bracketed
# severity — because that is what makes the line a finding rather than prose.
P1=$(grep -cE '^[[:space:]]*[-*+] +[*_`]*\[P1\]' "$OUT" || true)
P2=$(grep -cE '^[[:space:]]*[-*+] +[*_`]*\[P2\]' "$OUT" || true)
P3=$(grep -cE '^[[:space:]]*[-*+] +[*_`]*\[P3\]' "$OUT" || true)
TOTAL=$(( P1 + P2 + P3 ))

# --- The verdict: proof of review, not absence of error signs (I-033) --------
# Three tickets (F-09 -> T-020 -> T-023) tried to enumerate what a provider
# failure LOOKS like. Each time the next gate found a shape that walked past
# the list: a traceback starting on line 2, a CLI banner before the HTML, ANSI
# colouring, a line of spaces. The conclusion we paid for three times: a list
# of failure signs cannot be closed, because there are unlimited ways to begin
# a dump of text. So the question is inverted — not "does this look broken"
# but "is there proof this is a review". The proof is the marker the prompt
# above demands. Everything else, at any length and in any shape, is
# 'not reviewed'.
#
# The old detectors are kept, but demoted: they no longer decide anything,
# they only explain a failure to the human ("this looks like a provider
# error"), which "no marker" alone would not. Their history, kept because it
# explains their shape:
#   * F-09 — the original word list: a provider failure on stdout with exit 0
#     read as "0 findings", indistinguishable from a clean review.
#   * I-022 (T-020) — the word list alone over-fired on a genuine review of
#     auth/rate-limit code, which uses those very words. Hence the length gate:
#     the words only count in output that is also terse and unstructured.
#   * I-031 (T-023) — the length gate let long dumps (tracebacks, HTML error
#     pages) through, so a second, length-independent check anchored to the
#     FIRST non-empty line was added: quoted examples inside review prose never
#     land there, raw envelopes always do.
# As hints, both are free to be imperfect — an imperfect explanation costs
# nothing now that it no longer decides the verdict.
FAILURE_SIGNATURE='(^|[^A-Za-z])(auth(entication)?[ _-]?fail(ed|ure)?|unauthori[sz]ed|forbidden|rate[ -]?limit(ed)?|quota[ -]?exceeded|invalid[ _-]?api[ _-]?key|no such (model|provider)|(connection|network) (refused|reset|error)|internal server error|bad gateway|service unavailable|gateway timeout|request timed out|traceback \(most recent call last\)|unhandled exception|panic:|fatal error)([^A-Za-z]|$)'
STRUCT_SIGNATURE='^[[:space:]]*(Traceback \(most recent call last\):|<!DOCTYPE[[:space:]]+html|<html[ >]|\{"error"[[:space:]]*:|HTTP/1\.[01][[:space:]]+[45][0-9][0-9])'
ERR_SHAPE_LINES=3
ERR_SHAPE_CHARS=300
RAW_LINES="${RAW_LINES:-0}"; RAW_CHARS="${RAW_CHARS:-0}"
case "$RAW_LINES" in ''|*[!0-9]*) RAW_LINES=0 ;; esac
case "$RAW_CHARS" in ''|*[!0-9]*) RAW_CHARS=0 ;; esac
RAW_FIRST_LINE="$(printf '%s\n' "$RAW_BODY" | grep -m1 '.' || true)"

# Second echelon: prints a human-readable hint when the raw output also
# matches one of the old error shapes, and says nothing otherwise. Its return
# code is meaningful (0 = matched) so the relaxed mode below can reuse it.
second_echelon_hint() {
  if [ "$RAW_LINES" -le "$ERR_SHAPE_LINES" ] && [ "$RAW_CHARS" -le "$ERR_SHAPE_CHARS" ] \
     && printf '%s\n' "$RAW_BODY" | grep -qiE "$FAILURE_SIGNATURE"; then
    echo "HINT: this also looks like a provider/CLI failure — short, unstructured output matching a known error pattern:"
    printf '%s\n' "$RAW_BODY" | grep -iE "$FAILURE_SIGNATURE" | head -3 | untrusted
    return 0
  fi
  if printf '%s' "$RAW_FIRST_LINE" | grep -qiE "$STRUCT_SIGNATURE"; then
    echo "HINT: this also looks like a provider/CLI failure — the raw output opens with a traceback/HTML/JSON error envelope, not review prose:"
    printf '%s\n' "$RAW_BODY" | head -3 | untrusted
    return 0
  fi
  return 1
}

not_reviewed() {
  # A terse stdout naming a quota / login refusal (rc 0, F-09 shape) gets
  # the same class prefix; long prose never does (I-022: a genuine review of
  # rate-limit code uses those very words) — the length gate is the second
  # echelon's, reused as is.
  local st=""
  if [ "$RAW_LINES" -le "$ERR_SHAPE_LINES" ] && [ "$RAW_CHARS" -le "$ERR_SHAPE_CHARS" ]; then
    st="$(printf '%s\n' "$RAW_BODY" | helper_state)"
    [ "$st" != QUOTA ] || { u="$(printf '%s\n' "$RAW_BODY" | quota_until)"; st="QUOTA${u:+ (until $u)}"; }
  fi
  echo "FAIL: ${st:+$st — }not reviewed — $1"
  echo "REPORT: $OUT (raw output kept for inspection)"
  second_echelon_hint || true
  exit 1
}

# Markdown dressing around the sign-off is the most likely thing a real model
# does to it (`**CODEX-REVIEW-COMPLETE: 1**`, the line in backticks, as a list
# item, quoted, or as a heading). That is an obedient marker in a wrapper, not a
# missing one. Two passes, in this order:
#   1. every emphasis character is deleted anywhere on the line — edge-stripping
#      alone missed `**CODEX-REVIEW-COMPLETE:** 1`, where the pair sits in the
#      MIDDLE, and that shape was refused with a message blaming truncation;
#   2. a leading run of block markers (`>` quote, `#` heading, `-`/`+`/`*` list
#      bullet) is dropped — the T-024 gate found the accidental asymmetry that
#      `* MARKER` passed while `- MARKER` failed, purely because the old edge
#      strip happened to include `*` and not `-`.
# This view is used ONLY for marker detection — never for counting findings,
# whose lines legitimately begin with a bullet and carry `[P1]` in emphasis.
# Cost, stated: a line that becomes the marker only after this stripping now
# counts as a sign-off, and a review whose last line is literally `- C` would be
# read as a cut marker. Both are loud, both need the count to agree, and the
# direction of the second one is FAIL — the safe one.
NORM_BODY="$(printf '%s\n' "$RAW_BODY" | sed -E 's/[*_`]//g; s/^[[:space:]]*[>#+-]+[[:space:]]*//; s/[[:space:]]+$//')"
# A complete marker line: the token, a colon, a number, nothing else. `tail -1`
# because a review may legitimately quote the format earlier in its prose (this
# very script's diff, for instance) — the last one is the one it signed off with.
SENTINEL_LINE="$(printf '%s\n' "$NORM_BODY" | grep -E "^[[:space:]]*$SENTINEL:[[:space:]]*[0-9]+[[:space:]]*$" | tail -1)"
SENTINEL_N=""
# Leading zeros are the model's formatting, not a different number: `: 01` with
# one finding is a match. Stripped textually rather than through $((10#…)),
# which overflows on an absurdly long digit string instead of just disagreeing.
[ -n "$SENTINEL_LINE" ] && SENTINEL_N="$(printf '%s' "$SENTINEL_LINE" | sed -E 's/[^0-9]//g; s/^0+([0-9])/\1/')"
SENTINEL_SEEN=0
printf '%s\n' "$NORM_BODY" | grep -qF "$SENTINEL" && SENTINEL_SEEN=1
# The token is case-sensitive on purpose (a lowercase one is not the contract),
# but the failure message should say WHY rather than claim there is no marker.
SENTINEL_CASE=0
[ "$SENTINEL_SEEN" = 0 ] && printf '%s\n' "$NORM_BODY" | grep -qiF "$SENTINEL" && SENTINEL_CASE=1
# Truncation that lands INSIDE the token leaves no whole token to find — the
# tail then reads as a fragment like "CODEX-REVIEW-COMPL". So the last
# non-empty line is also checked against the token's prefixes. ANY non-empty
# prefix counts: an earlier 8-character floor left a window where a cut after
# 1..7 characters was invisible. Matching is exact, case-sensitive and against
# the WHOLE trimmed line, so a real review would have to end with a line that is
# literally `C` or `CODEX-R` to trip it — and the cost of that is a loud FAIL,
# the safe direction. What no check can see is a cut that ate the marker line
# whole: zero characters of it are left, which is indistinguishable from a model
# that never wrote one (documented in references/codex-review.md).
SENTINEL_CUT=0
LAST_LINE="$(printf '%s\n' "$NORM_BODY" | grep '.' | tail -1)"
LAST_TRIM="$(printf '%s' "$LAST_LINE" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
if [ -n "$LAST_TRIM" ]; then
  case "$SENTINEL" in "$LAST_TRIM"*) SENTINEL_CUT=1 ;; esac
fi
# Emergency relief valve (documented in references/codex-review.md together
# with its price): if the provider ever starts truncating tails, this stops the
# MARKER from being required. It does not, and must not, disarm the second
# echelon's veto — see the branch below. Value matched case-insensitively, like
# the consent branch above: `TRUE` and `Yes` mean what they say.
RELAX=0
case "$(printf '%s' "${PF_CODEX_SENTINEL_OPTIONAL:-}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on) RELAX=1 ;;
esac

if [ -n "$SENTINEL_LINE" ] && [ "$SENTINEL_N" = "$TOTAL" ]; then
  : # Proven: the review ran and signed off with a count that matches the report.
elif [ "$RELAX" = 1 ]; then
  RELAX_NOTE="NOTE: PF_CODEX_SENTINEL_OPTIONAL is set — the completion marker is not required for this run. Price: without it a silent provider failure can again read as a clean review; only the old shape heuristics are left."
  echo "$RELAX_NOTE"
  printf '\n%s\n' "$RELAX_NOTE" >> "$OUT" 2>/dev/null || true
  # The veto runs whatever the finding count is. The T-024 gate found this
  # guarded by `[ "$TOTAL" = 0 ]`, which meant the valve silently bought more
  # than it advertised: a known 502 shape with a finding line inside was
  # refused without the valve and accepted with it, while the doc and this
  # script both claimed the second echelon still decided. The valve waives the
  # MARKER; it never waives a contradiction the second echelon can name.
  HINT_OUT="$(second_echelon_hint)" && {
    echo "FAIL: not reviewed — the marker requirement is relaxed, but the output still matches a known failure shape."
    echo "REPORT: $OUT (raw output kept for inspection)"
    printf '%s\n' "$HINT_OUT"
    exit 1
  }
elif [ -n "$SENTINEL_LINE" ]; then
  not_reviewed "the completion marker says $SENTINEL_N finding(s), but $TOTAL finding line(s) are present — the output is out of sync with its own sign-off (typically a truncated report)."
elif [ "$SENTINEL_CUT" = 1 ]; then
  not_reviewed "the completion marker is there but broken — no complete '$SENTINEL: <N>' line, the output ends mid-marker. A corrupted sign-off outweighs any finding lines above it: the report is truncated."
elif [ "$SENTINEL_SEEN" = 1 ]; then
  # Split out from the truncation branch: a whole token with a count that is not
  # a plain integer (`: +1`, `: 1.0`, `: one`) used to be reported as "the
  # output ends mid-marker", which named the wrong defect — the marker is
  # intact, the number is not. Same verdict, honest reason.
  not_reviewed "the completion marker line is malformed — '$SENTINEL: <N>' takes a plain decimal count and nothing else on the line. With an unreadable count a finished report cannot be told from a truncated one."
elif [ "$TOTAL" -gt 0 ] && second_echelon_hint >/dev/null 2>&1; then
  # The backup branch below is the weakest acceptance in this script, so it is
  # the one place where the old shape detectors keep a say — as a VETO, never
  # as a reason to accept. The T-024 gate proved why: a 502 page and a JSON
  # error envelope, each with a well-formed finding line inside, were accepted
  # as reviews. The original justification ("no provider dump contains such a
  # line") was a denylist claim wearing the whitelist's clothes — an argument
  # from what nobody had imagined yet.
  not_reviewed "there are $TOTAL well-formed finding line(s), but no completion marker AND the output also matches a known provider/CLI failure shape. Without the marker, that contradiction is not resolvable in our favour."
elif [ "$TOTAL" -gt 0 ]; then
  # Finding lines without the marker used to be ACCEPTED here (`OK` + a loud
  # `NOTE`) as "backup proof that this is a report". T-029 retired that
  # acceptance, and the reason is data, not taste:
  #   * it was insurance against an UNMEASURED risk — "the model will forget
  #     the marker". The 14.08.2026 live run over the whole wave (29 commits,
  #     31 files, luna/max, 1236 s) measured it: the real model signed off with
  #     `CODEX-REVIEW-COMPLETE: 9` as the last line of the report
  #     (optimize/reports/2026-08-14-codex-review-final-wave.md);
  #   * the price of that insurance was a hole in the contract Codex itself
  #     rated P1: any output carrying one well-formed finding line was accepted
  #     without the marker, so an UNKNOWN failure shape with such a line inside
  #     read as a review.
  # One live observation is not a law, so the branch is not simply deleted —
  # it now FAILS with the recovery path named in the message. If the provider
  # ever does start eating tails, `PF_CODEX_SENTINEL_OPTIONAL=1` waives the
  # marker for that run (the valve above), and the second echelon still vetoes
  # known failure shapes. Work continues; it just continues deliberately,
  # by a human decision, instead of silently.
  echo "FAIL: not reviewed — there are $TOTAL well-formed finding line(s), but no '$SENTINEL: <N>' completion marker. Finding lines are evidence of structure, never proof that a review ran: an unknown provider/CLI failure shape carrying one such line looks exactly like this."
  echo "REPORT: $OUT (raw output kept for inspection)"
  second_echelon_hint || true
  echo "HINT: what to do, in this order —"
  echo "HINT:   1. read $OUT: if it IS a real review, the model simply dropped the final line; re-run, the marker is required by the prompt ('$SENTINEL: <N>' as the very last line, <N> = number of findings);"
  echo "HINT:   2. if it happens repeatedly, the provider is likely truncating tails. Then, and only then, re-run once with PF_CODEX_SENTINEL_OPTIONAL=1 — that waives the MARKER for that run (it does not waive the failure-shape veto) and prints its price;"
  echo "HINT:   3. do not treat this output as a clean review: 'not reviewed' is not 'no findings'."
  exit 1
elif [ "$SENTINEL_CASE" = 1 ]; then
  not_reviewed "the completion marker appears only in the wrong case — the contract line is '$SENTINEL: <N>', spelled exactly like that. Treated as 'not reviewed'."
else
  not_reviewed "no '$SENTINEL: <N>' line in the output, so there is no proof a review ran at all. Anything without that marker is treated as 'not reviewed', whatever the text looks like."
fi

echo "OK: Codex review finished in ${ELAPSED}s ($MODEL/$EFFORT, $CODE_COUNT code files)"
echo "REPORT: $OUT"
echo "FINDINGS: P1=$P1 P2=$P2 P3=$P3 (total $TOTAL)"
if [ "$TOTAL" = 0 ]; then
  echo "VERDICT: no prioritized findings — read the report before trusting this"
  sed -n '9,14p' "$OUT" | untrusted
else
  echo "VERDICT: findings present — read $OUT in full"
  grep -nE '^[-*] +\[P[123]\]' "$OUT" | head -10
fi
exit 0
