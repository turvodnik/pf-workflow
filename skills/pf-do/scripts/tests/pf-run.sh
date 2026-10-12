#!/usr/bin/env bash
# tests/pf-run.sh — table-driven tests for pf-run.sh (T-116, output compressor).
# One command: `bash tests/pf-run.sh`. Every scenario runs the SUT under the
# curated minimal PATH from lib.sh (plus `mv`, which the SUT needs and the base
# toolset lacks) — a tool the SUT silently depends on shows up here as a red
# test, not as a surprise on a machine without it. bash 3.2 clean.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TESTS_DIR/lib.sh"

SUT="$TESTS_DIR/../pf-run.sh"
[ -f "$SUT" ] || { echo "cannot find SUT at $SUT"; exit 90; }
WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/pf-run-tests-work.XXXXXXXX")"
echo "$WORKROOT" >> "$CLEANUP_DIRS_FILE"

echo "pf-run.sh test suite"
echo "SUT: $SUT"
echo "bash: $BASH_BIN ($("$BASH_BIN" --version | head -1))"

MP="$WORKROOT/minpath"; make_minpath "$MP" mv

# gen <n> [fail-every] — a generator script printing n lines ("line i"), with
# "FAIL case i" every <fail-every> lines when given; exit code from $GEN_RC.
GEN="$WORKROOT/gen.sh"
cat >"$GEN" <<'EOS'
#!/usr/bin/env bash
n="$1"; every="${2:-0}"; rc="${GEN_RC:-0}"
i=1
while [ "$i" -le "$n" ]; do
  if [ "$every" -gt 0 ] && [ $((i % every)) -eq 0 ]; then echo "FAIL case $i"; else echo "line $i"; fi
  i=$((i + 1))
done
exit "$rc"
EOS
chmod +x "$GEN"

# run <dir> <args…> — run the SUT with PF_RUN_DIR=<dir> under the curated PATH;
# sets OUT (stdout+stderr), RC, and NLINES (lines of OUT).
run() {
  local dir="$1"; shift
  OUT="$( PF_RUN_DIR="$dir" PATH="$MP" "$BASH_BIN" "$SUT" "$@" 2>&1 )"; RC=$?
  NLINES="$(printf '%s\n' "$OUT" | grep -c '')"
}
saved_path() { printf '%s\n' "$OUT" | sed -n 's/^saved: \(.*\) ([0-9]* lines, rc=[0-9]*)$/\1/p' | tail -1; }
count_logs() { local n=0 f; for f in "$1"/*.log; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }

# ===========================================================================
group "Long output: 300 lines -> digest <= 45 lines + saved:"
# ===========================================================================
d="$WORKROOT/d-long"
run "$d" -- "$GEN" 300
if [ "$RC" = 0 ] && [ "$NLINES" -le 45 ]; then pass "300 lines -> $NLINES lines on stdout (<= 45), rc 0"; else fail "300 lines -> $NLINES lines, rc=$RC" "$OUT"; fi
p="$(saved_path)"
if [ -n "$p" ] && [ -f "$p" ]; then pass "saved: line names an existing file ($p)"; else fail "saved: line missing or file absent" "$OUT"; fi
if [ "$(grep -c '' "$p")" = 300 ]; then pass "the log holds all 300 lines"; else fail "log line count $(grep -c '' "$p") != 300"; fi
if printf '%s\n' "$OUT" | grep -q '^saved: .* (300 lines, rc=0)$'; then pass "saved: reports (300 lines, rc=0)"; else fail "saved: format" "$(printf '%s\n' "$OUT" | tail -1)"; fi
if printf '%s\n' "$OUT" | sed -n '1p;10p' | tr '\n' ' ' | grep -q '^line 1 line 10 $'; then pass "first 10 lines are the head"; else fail "head lines" "$(printf '%s\n' "$OUT" | head -10)"; fi
if printf '%s\n' "$OUT" | grep -q '^line 271$' && printf '%s\n' "$OUT" | grep -q '^line 300$' && ! printf '%s\n' "$OUT" | grep -q '^line 270$'; then pass "tail is exactly the last 30 lines (271..300)"; else fail "tail lines" "$OUT"; fi
if printf '%s\n' "$OUT" | grep -q '^… \[260 lines omitted — full log: '; then pass "omission marker names the count and the log"; else fail "omission marker" "$OUT"; fi
if ! printf '%s\n' "$OUT" | grep -q -- '--- matches'; then pass "no matches block when nothing in the middle matches"; else fail "spurious matches block" "$OUT"; fi
if [ -f "${p%.log}.cmd" ] && grep -q 'gen.sh 300' "${p%.log}.cmd"; then pass "sibling .cmd records the command line"; else fail ".cmd sidecar"; fi
if [ "$(basename "$p")" != "$(basename "$p" | sed -n 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]*\.log$/&/p')" ]; then fail "log name pattern <date>-<n>.log" "$p"; else pass "log name is <YYYY-MM-DD>-<n>.log"; fi

# ===========================================================================
group "Exit code is the command's"
# ===========================================================================
d="$WORKROOT/d-rc"
run "$d" -- false
if [ "$RC" = 1 ]; then pass "pf-run.sh -- false -> rc 1"; else fail "-- false -> rc $RC" "$OUT"; fi
run "$d" -- true
if [ "$RC" = 0 ]; then pass "pf-run.sh -- true -> rc 0"; else fail "-- true -> rc $RC"; fi
GEN_RC=3 run "$d" -- "$GEN" 300
if [ "$RC" = 3 ]; then pass "long failing output -> rc 3 preserved"; else fail "rc $RC != 3" "$OUT"; fi
if printf '%s\n' "$OUT" | grep -q '(300 lines, rc=3)$'; then pass "saved: reports rc=3"; else fail "saved: rc" "$(printf '%s\n' "$OUT" | tail -1)"; fi
if printf '%s\n' "$OUT" | grep -q '^line 241$' && ! printf '%s\n' "$OUT" | grep -q '^line 240$'; then pass "failure -> tail is 60 lines (241..300)"; else fail "fail tail 60" "$OUT"; fi
if [ "$NLINES" -le 75 ]; then pass "failure digest stays compact ($NLINES lines)"; else fail "failure digest $NLINES lines" "$OUT"; fi

# ===========================================================================
group "Short output: printed as is, no file"
# ===========================================================================
d="$WORKROOT/d-short"
run "$d" -- "$GEN" 59
if [ "$RC" = 0 ] && [ "$NLINES" = 59 ] && printf '%s\n' "$OUT" | sed -n '59p' | grep -q '^line 59$'; then pass "59 lines -> 59 lines, verbatim"; else fail "short verbatim (n=$NLINES rc=$RC)" "$OUT"; fi
if ! printf '%s\n' "$OUT" | grep -q '^saved:'; then pass "no saved: line for short output"; else fail "saved: on short output" "$OUT"; fi
if [ "$(count_logs "$d")" = 0 ] && [ -z "$(ls -A "$d" 2>/dev/null)" ]; then pass "negative control: no file left in PF_RUN_DIR"; else fail "files left for short output" "$(ls -A "$d")"; fi
GEN_RC=2 run "$d" -- "$GEN" 5
if [ "$RC" = 2 ] && [ "$NLINES" = 5 ]; then pass "short failing output -> verbatim, rc 2"; else fail "short fail (n=$NLINES rc=$RC)"; fi
run "$d" -- "$GEN" 60
if printf '%s\n' "$OUT" | grep -q '^saved:'; then pass "threshold: 60 lines is long (file written)"; else fail "60 lines not treated as long" "$OUT"; fi
if [ "$NLINES" -le 45 ]; then pass "60-line digest is <= 45 lines ($NLINES)"; else fail "60-line digest $NLINES lines" "$OUT"; fi
if ! printf '%s\n' "$OUT" | sort | uniq -d | grep -q '^line '; then pass "no line printed twice when head and tail nearly meet"; else fail "duplicate lines in digest" "$OUT"; fi
d="$WORKROOT/d-short2"
PF_RUN_SHORT=10 run "$d" -- "$GEN" 20
if printf '%s\n' "$OUT" | grep -q '(20 lines, rc=0)$' && [ "$(count_logs "$d")" = 1 ]; then pass "PF_RUN_SHORT=10 lowers the threshold"; else fail "PF_RUN_SHORT" "$OUT"; fi

# ===========================================================================
group "matches block: failure-looking lines from the omitted middle"
# ===========================================================================
d="$WORKROOT/d-match"
GEN_RC=1 run "$d" -- "$GEN" 300 7      # FAIL case 7, 14, … 294 — 42 hits, ~32 in the middle
if printf '%s\n' "$OUT" | grep -q '^--- matches (20 of [0-9]* lines matching '; then pass "matches block capped at 20 and reports the total"; else fail "matches header" "$(printf '%s\n' "$OUT" | grep -- '--- matches')"; fi
m="$(printf '%s\n' "$OUT" | sed -n '/^--- matches/,/^--- end matches/p' | grep -c '^FAIL case ')"
if [ "$m" = 20 ]; then pass "exactly 20 FAIL lines listed"; else fail "matches listed $m" "$OUT"; fi
if printf '%s\n' "$OUT" | sed -n '/^--- matches/,/^--- end matches/p' | grep -q '^FAIL case 14$' && ! printf '%s\n' "$OUT" | sed -n '/^--- matches/,/^--- end matches/p' | grep -q '^FAIL case 7$'; then pass "matches come from the middle only (7 is in the head, 14 is not)"; else fail "matches range" "$OUT"; fi
if ! printf '%s\n' "$OUT" | sed -n '/^--- matches/,/^--- end matches/p' | grep -q '^FAIL case 294$'; then pass "tail lines are not repeated in matches (294 is in the tail)"; else fail "tail duplicated in matches" "$OUT"; fi
run "$d" -- "$GEN" 300 100            # FAIL case 100, 200 in the middle, 300 in the tail
if printf '%s\n' "$OUT" | grep -q '^--- matches (2 of 2 lines' && printf '%s\n' "$OUT" | grep -c '^FAIL case 300$' | grep -q '^1$'; then pass "2 middle hits -> (2 of 2); tail hit shown once, in the tail"; else fail "matches small" "$OUT"; fi
if [ "$NLINES" = 46 ]; then pass "matches block adds exactly hits+2 lines (42 + 4 = 46)"; else fail "digest with 2 matches: $NLINES lines, expected 46" "$OUT"; fi
PF_RUN_MATCH='line 150' run "$d" -- "$GEN" 300
if printf '%s\n' "$OUT" | sed -n '/^--- matches/,/^--- end matches/p' | grep -q '^line 150$'; then pass "PF_RUN_MATCH overrides the pattern"; else fail "PF_RUN_MATCH" "$OUT"; fi
# Traceback / ERROR / ✗ — the default alternation, each alone in the middle.
GEN2="$WORKROOT/gen2.sh"
printf '%s\n' '#!/usr/bin/env bash' 'i=1; while [ $i -le 200 ]; do case $i in 50) echo "Traceback (most recent call last):";; 90) echo "ERROR: boom";; 120) echo "✗ lost";; *) echo "line $i";; esac; i=$((i+1)); done' >"$GEN2"; chmod +x "$GEN2"
run "$d" -- "$GEN2"
if printf '%s\n' "$OUT" | grep -q '^--- matches (3 of 3' && printf '%s\n' "$OUT" | grep -q '^✗ lost$'; then pass "default pattern catches Traceback, ERROR and ✗"; else fail "default pattern" "$OUT"; fi
# A label that merely mentions FAIL/ERROR mid-line is not a failure (the codex-review suite has 22 such PASS lines).
GEN3="$WORKROOT/gen3.sh"
printf '%s\n' '#!/usr/bin/env bash' 'i=1; while [ $i -le 200 ]; do case $i in 50) echo "PASS  output must read as FAIL: not reviewed";; 90) echo "  FAIL  indented real failure";; *) echo "line $i";; esac; i=$((i+1)); done' >"$GEN3"; chmod +x "$GEN3"
run "$d" -- "$GEN3"
if printf '%s\n' "$OUT" | grep -q '^--- matches (1 of 1' && printf '%s\n' "$OUT" | grep -q '^  FAIL  indented real failure$'; then pass "pattern is anchored: PASS line mentioning FAIL skipped, indented FAIL caught"; else fail "anchored pattern" "$OUT"; fi

# ===========================================================================
group "stderr is captured too; log directory choice; parallel names"
# ===========================================================================
d="$WORKROOT/d-stderr"
ERRGEN="$WORKROOT/errgen.sh"
printf '%s\n' '#!/usr/bin/env bash' 'i=1; while [ $i -le 100 ]; do echo "err $i" >&2; i=$((i+1)); done; exit 4' >"$ERRGEN"; chmod +x "$ERRGEN"
run "$d" -- "$ERRGEN"
p="$(saved_path)"
if [ "$RC" = 4 ] && [ -n "$p" ] && [ "$(grep -c '^err ' "$p")" = 100 ]; then pass "100 stderr lines land in the log, rc 4 kept"; else fail "stderr capture (rc=$RC)" "$OUT"; fi
if [ "$NLINES" -le 75 ]; then pass "stderr-only failure is digested ($NLINES lines)"; else fail "stderr digest $NLINES" "$OUT"; fi

# default directory: <git toplevel>/.agents/runtime/out when PF_RUN_DIR is unset
repo="$(new_repo)"; repo="$(cd "$repo" && pwd -P)"   # git prints the physical path (/private/var on macOS)
OUT="$( cd "$repo/" && mkdir -p sub && cd sub && env -u PF_RUN_DIR PATH="$MP" "$BASH_BIN" "$SUT" -- "$GEN" 100 2>&1 )"; RC=$?
p="$(saved_path)"
case "$p" in "$repo/.agents/runtime/out/"*.log) pass "no PF_RUN_DIR + git repo -> <toplevel>/.agents/runtime/out/ (from a subdir)";; *) fail "default dir in repo" "$OUT";; esac
rm -rf "$repo"

# no repo, no PF_RUN_DIR -> $TMPDIR/pf-run
nogit="$WORKROOT/nogit"; mkdir -p "$nogit"
OUT="$( cd "$nogit" && env -u PF_RUN_DIR TMPDIR="$WORKROOT/tmpd" PATH="$MP" "$BASH_BIN" "$SUT" -- "$GEN" 100 2>&1 )"; RC=$?
p="$(saved_path)"
case "$p" in "$(cd "$WORKROOT/tmpd/pf-run" && pwd -P)/"*.log) pass "no PF_RUN_DIR + no repo -> \$TMPDIR/pf-run/ (physical path)";; *) fail "fallback dir" "$OUT";; esac

# unwritable directory -> loud failure, distinct rc
ro="$WORKROOT/ro"; mkdir -p "$ro"; chmod 500 "$ro"
run "$ro" -- "$GEN" 100
if [ "$RC" = 65 ] && printf '%s\n' "$OUT" | grep -q '^pf-run: cannot write'; then pass "unwritable PF_RUN_DIR -> rc 65 with a message (not a silent success)"; else fail "unwritable dir (rc=$RC)" "$OUT"; fi
chmod 700 "$ro"

# sequential numbering: two long runs -> -1.log and -2.log; a third after
# deleting -1 reuses the free slot without touching -2.
d="$WORKROOT/d-seq"
run "$d" -- "$GEN" 100; p1="$(saved_path)"
run "$d" -- "$GEN" 100; p2="$(saved_path)"
if [ "$(basename "$p1")" = "$(date +%Y-%m-%d)-1.log" ] && [ "$(basename "$p2")" = "$(date +%Y-%m-%d)-2.log" ]; then pass "numbering: -1.log then -2.log"; else fail "numbering" "$p1 / $p2"; fi
rm -f "$p1" "${p1%.log}.cmd"
run "$d" -- "$GEN" 100; p3="$(saved_path)"
if [ "$(basename "$p3")" = "$(date +%Y-%m-%d)-1.log" ] && [ -f "$p2" ] && [ "$(grep -c '' "$p2")" = 100 ]; then pass "a freed slot (-1) is reused; -2.log untouched"; else fail "slot reuse" "$p3"; fi
# parallel: 8 concurrent long runs must produce 8 distinct logs, none overwritten
d="$WORKROOT/d-par"; mkdir -p "$d"
i=1; while [ "$i" -le 8 ]; do ( PF_RUN_DIR="$d" PATH="$MP" "$BASH_BIN" "$SUT" -- "$GEN" 100 >/dev/null 2>&1 ) & i=$((i + 1)); done; wait
if [ "$(count_logs "$d")" = 8 ]; then pass "8 parallel runs -> 8 distinct logs (noclobber)"; else fail "parallel logs: $(count_logs "$d")"; fi
bad=0; for f in "$d"/*.log; do [ "$(grep -c '' "$f")" = 100 ] || bad=1; done
if [ "$bad" = 0 ]; then pass "every parallel log is complete (100 lines)"; else fail "a parallel log is truncated"; fi

# ===========================================================================
group "Usage and arguments"
# ===========================================================================
d="$WORKROOT/d-usage"
run "$d"
if [ "$RC" = 64 ] && printf '%s\n' "$OUT" | grep -q '^usage:'; then pass "no command -> usage, rc 64"; else fail "no command (rc=$RC)" "$OUT"; fi
run "$d" -- --help
if [ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^usage:'; then pass "--help -> usage, rc 0"; else fail "--help (rc=$RC)" "$OUT"; fi
run "$d" "$GEN" 100
if printf '%s\n' "$OUT" | grep -q '^saved:'; then pass "the -- separator is optional"; else fail "without --" "$OUT"; fi
run "$d" -n 5
if [ "$RC" = 64 ] && printf '%s\n' "$OUT" | grep -q "unknown option '-n'"; then pass "a leading option (-n 5) without -- -> usage, rc 64, not rc 127"; else fail "leading option (rc=$RC)" "$OUT"; fi
# relative PF_RUN_DIR -> absolute physical path in saved:
rel="rel-out-$$"; OUT="$( cd "$WORKROOT" && PF_RUN_DIR="$rel" PATH="$MP" "$BASH_BIN" "$SUT" -- "$GEN" 100 2>&1 )"; RC=$?
p="$(saved_path)"
case "$p" in /*) if [ -f "$p" ] && [ "$(dirname "$p")" = "$(cd "$WORKROOT/$rel" && pwd -P)" ]; then pass "relative PF_RUN_DIR is reported as an absolute physical path"; else fail "relative dir resolved wrongly" "$p"; fi ;; *) fail "saved: path is relative" "$p" ;; esac
run "$d" -- "$GEN" 100 0 "arg with space"
cmdf="$(saved_path | sed 's/\.log$/.cmd/')"
if [ "$RC" = 0 ] && grep -q 'arg\\ with\\ space' "$cmdf"; then pass "arguments with spaces are recorded shell-quoted in .cmd"; else fail "args with spaces" "$(cat "$cmdf")"; fi
# The sidecar must be re-runnable as written: eval it and compare with the original output.
replay="$( PATH="$MP" "$BASH_BIN" -c "eval \"\$(cat '$cmdf')\"" 2>&1 | grep -c '' )"
if [ "$replay" = 100 ]; then pass ".cmd sidecar replays the command (100 lines)"; else fail ".cmd replay: $replay lines" "$(cat "$cmdf")"; fi
if [ -z "$(find "$d" -maxdepth 1 -name '.pf-run.*' -print -quit)" ]; then pass "no temp files left behind"; else fail "temp files left" "$(ls -A "$d")"; fi

finish
