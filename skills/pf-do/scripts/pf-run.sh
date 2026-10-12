#!/usr/bin/env bash
# pf-run.sh — output compressor for long-running commands (T-116, "context diet").
#
#   pf-run.sh -- <command> [args…]
#
# Runs the command with stdout AND stderr merged into one log file (an installer
# or a build prints its failures to stderr; leaving stderr in the window would
# defeat the diet), then prints a digest to stdout instead of the whole output:
#
#   short output (fewer than PF_RUN_SHORT lines, default 60) — printed as is,
#     no file is written (nothing to save, nothing to forget);
#   long output — first 10 lines, an omission marker, the last 30 lines
#     (60 when the command failed — the failure is usually at the end),
#     a "matches" block with up to 20 lines from the OMITTED middle that look
#     like failures (PF_RUN_MATCH, default `^[[:space:]]*(FAIL|ERROR|Traceback|✗)`), and one
#     final line:
#
#       saved: <path> (<N> lines, rc=<code>)
#
#   The `saved:` line is the proof to quote in «Результат»: the reviewer opens
#   the file, the chat does not carry 1 500 lines of test output.
#
# The command's exit code is preserved (`pf-run.sh -- false` exits 1).
#
# Log directory, first that applies: $PF_RUN_DIR; <git toplevel>/.agents/runtime/out
# (gitignored); ${TMPDIR:-/tmp}/pf-run. Name: <YYYY-MM-DD>-<n>.log, n picked
# with noclobber so two parallel executors never share a file. The log holds
# the raw output only (grep-able); the command line goes to a sibling
# <name>.cmd so the log can be reproduced.
#
# Environment knobs: PF_RUN_DIR, PF_RUN_SHORT (default 60), PF_RUN_HEAD (10),
# PF_RUN_TAIL (30), PF_RUN_TAIL_FAIL (60), PF_RUN_MATCH (extended regex),
# PF_RUN_MATCH_MAX (20). bash 3.2 clean (macOS /bin/bash); tools: head, tail,
# grep, sed, date, mkdir, mktemp, git (optional, for the default directory).
set -uo pipefail

usage() {
  echo "usage: pf-run.sh -- <command> [args...]" >&2
  echo "       runs the command, saves the full output to a log, prints a digest; exit code = the command's" >&2
}

if [ "${1:-}" = "--" ]; then shift; fi
if [ $# -eq 0 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  [ $# -eq 0 ] && exit 64
  exit 0
fi
case "$1" in
  -*) echo "pf-run: unknown option '$1' (the wrapper takes no options; put the command after --)" >&2; usage; exit 64 ;;
esac

SHORT="${PF_RUN_SHORT:-60}"
HEAD_N="${PF_RUN_HEAD:-10}"
TAIL_N="${PF_RUN_TAIL:-30}"
TAIL_FAIL_N="${PF_RUN_TAIL_FAIL:-60}"
# Anchored to the line start (after indentation): a PASS line whose label merely
# mentions "FAIL" is not a failure — 20 false hits on the codex-review suite otherwise.
MATCH_RE="${PF_RUN_MATCH:-^[[:space:]]*(FAIL|ERROR|Traceback|✗)}"
MATCH_MAX="${PF_RUN_MATCH_MAX:-20}"

# --- where the log lives ------------------------------------------------------
pick_dir() {
  if [ -n "${PF_RUN_DIR:-}" ]; then
    printf '%s' "$PF_RUN_DIR"; return
  fi
  local top
  if top="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
    printf '%s' "$top/.agents/runtime/out"; return
  fi
  printf '%s' "${TMPDIR:-/tmp}/pf-run"
}

OUT_DIR="$(pick_dir)"
if ! mkdir -p "$OUT_DIR" 2>/dev/null || [ ! -w "$OUT_DIR" ]; then
  echo "pf-run: cannot write to log directory: $OUT_DIR (set PF_RUN_DIR)" >&2
  exit 65
fi
# Absolute, physical path: the saved: line is quoted in «Результат» and must resolve from any cwd.
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"

# --- run to a temp file first; decide short/long after the fact ---------------
TMP_LOG="$(mktemp "$OUT_DIR/.pf-run.XXXXXXXX")" || { echo "pf-run: mktemp failed in $OUT_DIR" >&2; exit 65; }
trap 'rm -f "$TMP_LOG"' EXIT

"$@" >"$TMP_LOG" 2>&1
rc=$?

# Count lines the way a reader does: a last line without "\n" still counts.
count_lines() {
  local n
  n=$(grep -c '' "$1" 2>/dev/null) || n=0
  printf '%s' "$n"
}
total="$(count_lines "$TMP_LOG")"

if [ "$total" -lt "$SHORT" ]; then
  cat "$TMP_LOG"
  exit "$rc"
fi

# --- long output: claim a numbered log name (noclobber = atomic create) ------
today="$(date +%Y-%m-%d)"
n=1
LOG=""
while [ "$n" -le 10000 ]; do
  candidate="$OUT_DIR/$today-$n.log"
  if ( set -C; : >"$candidate" ) 2>/dev/null; then
    LOG="$candidate"; break
  fi
  n=$((n + 1))
done
if [ -z "$LOG" ]; then
  echo "pf-run: could not allocate a log name in $OUT_DIR" >&2
  cat "$TMP_LOG"
  exit "$rc"
fi
mv -f "$TMP_LOG" "$LOG" || { cat "$TMP_LOG"; exit "$rc"; }
trap - EXIT
# %q keeps argument boundaries (an argument with spaces or shell metacharacters
# is re-runnable from the sidecar as written).
printf '%q ' "$@" >"${LOG%.log}.cmd"; printf '\n' >>"${LOG%.log}.cmd"

if [ "$rc" -ne 0 ]; then tail_n="$TAIL_FAIL_N"; else tail_n="$TAIL_N"; fi
if [ "$tail_n" -gt "$total" ]; then tail_n="$total"; fi
omitted=$((total - HEAD_N - tail_n))

if [ "$omitted" -le 0 ]; then
  # head + tail would cover (or overlap) the whole file — print it once, whole.
  cat "$LOG"
else
  head -n "$HEAD_N" "$LOG"
  echo "… [$omitted lines omitted — full log: $LOG]"
  # Failure-looking lines from the omitted middle only (head/tail are already shown).
  mid_from=$((HEAD_N + 1))
  mid_to=$((total - tail_n))
  matches="$(sed -n "${mid_from},${mid_to}p" "$LOG" | grep -E -- "$MATCH_RE" 2>/dev/null || true)"
  if [ -n "$matches" ]; then
    m_total="$(printf '%s\n' "$matches" | grep -c '')"
    if [ "$m_total" -gt "$MATCH_MAX" ]; then m_shown="$MATCH_MAX"; else m_shown="$m_total"; fi
    echo "--- matches ($m_shown of $m_total lines matching /$MATCH_RE/ in the omitted part) ---"
    printf '%s\n' "$matches" | head -n "$MATCH_MAX"
    echo "--- end matches ---"
  fi
  tail -n "$tail_n" "$LOG"
fi
echo "saved: $LOG ($total lines, rc=$rc)"
exit "$rc"
