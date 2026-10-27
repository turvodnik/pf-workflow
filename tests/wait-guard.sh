#!/bin/bash
# tests/wait-guard.sh — bash test suite for the wait-guard.sh Stop hook (T-110).
#
# Every case builds its own project in a mktemp dir (a HANDOFF registry, a
# transcript JSONL) and feeds the hook the JSON Claude Code would send on
# Stop. Asserts the exit code AND the stderr line — "silent success" is not a
# pass. Non-zero exit on any failure. Runs on bash 3.2 (macOS), no jq needed.
#
# Layout: in the canon this file sits in hooks/tests/ next to ../wait-guard.sh;
# in the pf-workflow distribution sync-from-tools.sh puts it in tests/ with
# the hook in ../hooks/wait-guard.sh — both are resolved below.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HOOK=""
for cand in "$HERE/../wait-guard.sh" "$HERE/../hooks/wait-guard.sh"; do
  if [ -f "$cand" ]; then HOOK="$(cd "$(dirname "$cand")" && pwd)/wait-guard.sh"; break; fi
done
if [ -z "$HOOK" ]; then
  echo "FAIL: wait-guard.sh not found next to $HERE (tried ../ and ../hooks/)" >&2
  exit 2
fi
[ -x "$HOOK" ] || { echo "FAIL: $HOOK is not executable" >&2; exit 2; }

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wait-guard-tests.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

SID="fda3bf59-d602-451d-a7f2-a255d4dfdab1"

# --- fixtures -------------------------------------------------------------
new_project() {  # $1 name → prints the project dir
  local p="$ROOT/$1"
  mkdir -p "$p/.agents/runtime/handoff"
  printf '%s\n' "$p"
}

write_handoff() {  # $1 project, $2 file name, $3 status, $4 session_id, $5 running(yes|no)
  local f="$1/.agents/runtime/handoff/$2"
  {
    printf -- '---\nstatus: %s\nsession_id: %s\ntask: тест\nupdated: 2026-09-16 21:00\n---\n\n' "$3" "$4"
    printf '# HANDOFF: тест\n\n## Реестр волны\n\n| Задание | Тикеты | Субагент | Статус |\n|---|---|---|---|\n'
    if [ "$5" = yes ]; then
      printf '| A (волна 1) | T-001 | pf-executor (opus) | запущен 21:00 |\n'
    else
      printf '| A (волна 1) | T-001 | pf-executor (opus) | сводка принята |\n'
    fi
    printf '\nПобудка запущена в прозе — не строка реестра.\n'
  } > "$f"
}

# transcript: a human turn, an assistant Bash run_in_background, tool_result,
# then either a blocking wait or just text.
write_transcript() {  # $1 path, $2 mode: wait|nowait|monitor|sidechain-wait|prevturn-wait
  local f="$1" mode="$2"
  {
    printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":"Запусти волну"}}\n'
    printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"sleep 5","run_in_background":true}}]}}\n'
    printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"started"}]}}\n'
    case "$mode" in
      wait)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"TaskOutput","input":{"task_id":"abc","block":true,"timeout":600000}}]}}\n'
        printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"y","content":"done"}]}}\n'
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Сводка принята."}]}}\n' ;;
      monitor)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Monitor","input":{"command":"cat log","until":"DONE"}}]}}\n' ;;
      nonblock)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"TaskOutput","input":{"task_id":"abc","block":false}}]}}\n'
        printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"y","content":"running"}]}}\n'
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Жду."}]}}\n' ;;
      sidechain-wait)
        printf '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"tool_use","name":"TaskOutput","input":{"task_id":"abc","block":true}}]}}\n'
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Жду."}]}}\n' ;;
      prevturn-wait)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"TaskOutput","input":{"task_id":"abc","block":true}}]}}\n'
        printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":"<task-notification>done</task-notification>"}}\n'
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Жду."}]}}\n' ;;
      wait-then-edit)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"TaskOutput","input":{"task_id":"abc","block":true}}]}}\n'
        printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"y","content":"job A done"}]}}\n'
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"HANDOFF.md","old_string":"A запущен","new_string":"A сводка принята"}}]}}\n'
        printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"z","content":"ok"}]}}\n'
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Сводка A принята. Жду B."}]}}\n' ;;
      edit-then-wait)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"HANDOFF.md","old_string":"x","new_string":"y"}}]}}\n'
        printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"z","content":"ok"}]}}\n'
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"TaskOutput","input":{"task_id":"abc","block":true}}]}}\n'
        printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"y","content":"done"}]}}\n'
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Готово."}]}}\n' ;;
      bash-until)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"until [ -f done.flag ]; do sleep 20; done; cat done.flag","timeout":600000}}]}}\n' ;;
      bash-while)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"while pgrep -f council.sh >/dev/null; do sleep 5; done"}}]}}\n' ;;
      bash-wait)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"bash council.sh --wait /tmp/marker --timeout 500"}}]}}\n' ;;
      bash-bg)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"until [ -f done.flag ]; do sleep 20; done","run_in_background":true}}]}}\n' ;;
      bash-echo-until)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"echo \\"until we meet\\" >> notes.md; git status --while-x"}}]}}\n' ;;
      bash-cd-until)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"cd /tmp/x && until [ -f done.flag ]; do sleep 20; done"}}]}}\n' ;;
      bash-for-do)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"for f in *.log; do wc -l \\"$f\\"; done"}}]}}\n' ;;
      bash-quoted-until)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"bash -c \\"until [ -f x ]; do sleep 1; done\\""}}]}}\n' ;;
      bash-plain)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"git status --short"}}]}}\n' ;;
      nowait|*)
        printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Жду."}]}}\n' ;;
    esac
  } > "$f"
}

stdin_json() {  # $1 session_id, $2 transcript, $3 cwd, $4 stop_hook_active (true|false)
  printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop","stop_hook_active":%s,"cwd":"%s"}' "$1" "$2" "$4" "$3"
}

run_hook() {  # stdin from caller; sets RC, ERR
  ERR="$(bash "$HOOK" 2>&1 >/dev/null)"; RC=$?
}

expect() {  # $1 name, $2 expected rc, $3 substring expected in stderr
  if [ "$RC" -eq "$2" ] && printf '%s' "$ERR" | grep -q -- "$3"; then
    pass "$1 → rc=$RC, stderr: $ERR"
  else
    fail "$1 → expected rc=$2 and stderr containing «${3}», got rc=$RC, stderr: $ERR"
  fi
}

# --- cases ----------------------------------------------------------------
# 1. own active HANDOFF with «запущен» + turn without a blocking wait → BLOCK
P="$(new_project p1)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "1 own running + no wait" 2 "registry has running jobs (A (волна 1) / T-001"
printf '%s' "$ERR" | grep -q "call TaskOutput(block=true) or a foreground Bash until-loop" && pass "1a block reason names the remedy" || fail "1a block reason lacks the remedy text: $ERR"

# 2. foreign active HANDOFF (other session_id) with «запущен» → skipped
P="$(new_project p2)"; write_handoff "$P" "2026-09-15-foreign.md" active "c628720f" yes
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "2 foreign active registry" 0 "skipped: no own registry"

# 3. own «запущен» + TaskOutput block=true in this turn → ok
P="$(new_project p3)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" wait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "3 own running + TaskOutput block=true" 0 "blocking wait"

# 3b. Monitor is a background stream, NOT a blocking wait → BLOCK (decision, fix round 1)
P="$(new_project p3b)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" monitor
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "3b Monitor is not a wait" 2 "registry has running jobs"

# 3i. last call = foreground Bash until-loop → ok; while-loop and --wait too
for m in bash-until bash-while bash-wait; do
  P="$(new_project "p3i-$m")"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
  write_transcript "$P/t.jsonl" "$m"
  run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
  expect "3i last call = foreground Bash ($m)" 0 "blocking wait"
done

# 3i2. the keyword inside a string is prose, not a wait → BLOCK; after `cd … &&` it is a wait → ok
P="$(new_project p3i2)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" bash-echo-until
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "3i2 Bash echo \"until we meet\" is not a wait" 2 "registry has running jobs"
P="$(new_project p3i3)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" bash-cd-until
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "3i3 Bash cd … && until-loop is a wait" 0 "blocking wait"
P="$(new_project p3i4)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" bash-for-do
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "3i4 Bash for … ; do loop is not a wait" 2 "registry has running jobs"
P="$(new_project p3i5)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" bash-quoted-until
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "3i5 Bash quoted until … ; do (bash -c) is a wait" 0 "blocking wait"

# 3j. last call = Bash run_in_background (even with an until-loop inside) → BLOCK
P="$(new_project p3j)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" bash-bg
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "3j Bash run_in_background is not a wait" 2 "registry has running jobs"

# 3k. last call = plain foreground Bash without a wait loop → BLOCK
P="$(new_project p3k)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" bash-plain
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "3k plain Bash is not a wait" 2 "registry has running jobs"

# 3c. TaskOutput with block=false is NOT a blocking wait → BLOCK
P="$(new_project p3c)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" nonblock
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "3c TaskOutput block=false is not a wait" 2 "registry has running jobs"

# 3d. a blocking wait only on a sidechain record does not count → BLOCK
P="$(new_project p3d)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" sidechain-wait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "3d sidechain wait ignored" 2 "registry has running jobs"

# 3e. a blocking wait in the PREVIOUS turn (before a task-notification) → BLOCK
P="$(new_project p3e)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" prevturn-wait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "3e wait in previous turn only" 2 "registry has running jobs"

# 8b. `status: active   # comment` in the frontmatter is still active → BLOCK (💭-1)
P="$(new_project p8b)"
printf -- '---\nstatus: active   # оставлен для ревью\nsession_id: %s # оркестратор\n---\n\n| A | T-001 | x | запущен |\n' "$SID" > "$P/.agents/runtime/handoff/2026-09-16-c.md"
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "8b frontmatter values with # comments" 2 "registry has running jobs"

# 3f. waited for A, then edited the registry, then prose while B runs → BLOCK
#     (the wait must be the LAST tool call of the turn — council review P2)
P="$(new_project p3f)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" wait-then-edit
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "3f wait, then Edit, then prose" 2 "registry has running jobs"

# 3g. edits first, the blocking wait last → ok
P="$(new_project p3g)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" edit-then-wait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "3g Edit, then wait last" 0 "blocking wait"

# 3h. long frontmatter (30 lines) still recognised → BLOCK
P="$(new_project p3h)"
{ printf -- '---\nstatus: active\n'; for i in $(seq 1 26); do printf 'note%s: x\n' "$i"; done; printf 'session_id: %s\nupdated: now\n---\n\n| A | T-001 | x | запущен |\n' "$SID"; } > "$P/.agents/runtime/handoff/2026-09-16-long.md"
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "3h 30-line frontmatter" 2 "registry has running jobs"

# 4. own active HANDOFF without «запущен» → ok
P="$(new_project p4)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" no
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "4 own registry, nothing running" 0 "no running jobs"

# 5. stop_hook_active: true → exit 0, even with a running job and no wait
P="$(new_project p5)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" true)
expect "5 stop_hook_active" 0 "stop_hook_active"

# 6. broken stdin → exit 0 + skipped
run_hook < <(printf '{"session_id": "abc", "cwd": ')
expect "6 broken stdin JSON" 0 "skipped"
run_hook < /dev/null
expect "6b empty stdin" 0 "skipped"
run_hook < <(printf '[1,2,3]')
expect "6c stdin JSON not an object" 0 "skipped"

# 7. never break the session: transcript_path does not exist → exit 0 skipped
P="$(new_project p7)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
run_hook < <(stdin_json "$SID" "$P/missing.jsonl" "$P" false)
expect "7 missing transcript_path" 0 "skipped (transcript_path"

# 8. HANDOFF without frontmatter (but with «запущен» and the id in prose) → exit 0
P="$(new_project p8)"
printf '# HANDOFF без frontmatter\nsession_id: %s\n\n| A | T-001 | x | запущен |\n' "$SID" > "$P/.agents/runtime/handoff/2026-09-16-nofm.md"
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "8 HANDOFF without frontmatter" 0 "skipped: no own registry"

# 9. closed HANDOFF with own id and «запущен» → not a registry → exit 0
P="$(new_project p9)"; write_handoff "$P" "2026-09-10-old.md" closed "$SID" yes
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "9 closed HANDOFF ignored" 0 "skipped: no own registry"

# 10. session_id stored as an 8-char prefix (real HANDOFF form) matches → BLOCK
P="$(new_project p10)"; write_handoff "$P" "2026-09-16-run.md" active "fda3bf59" yes
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "10 8-char prefix session_id matches" 2 "registry has running jobs"

# 10b. a too-short prefix or the «—» placeholder never matches → skipped
P="$(new_project p10b)"; write_handoff "$P" "a.md" active "fda3" yes; write_handoff "$P" "b.md" active "—" yes
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "10b short prefix / placeholder do not match" 0 "skipped: no own registry"

# 11. autopilot-run.md registry (no pf-handoff companion) with session_id → BLOCK
P="$(new_project p11)"
printf '# Реестр автопилота · тест · 2026-09-16\nsession_id: %s\n\n| Задание | Тикеты | Субагент | Статус |\n|---|---|---|---|\n| B (волна 1) | T-002 | pf-executor | запущен 21:10 |\n' "$SID" > "$P/.agents/runtime/autopilot-run.md"
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "11 autopilot-run.md own registry" 2 "B (волна 1) / T-002"

# 12. project without .agents/runtime → exit 0, no noise beyond one line
P="$ROOT/p12"; mkdir -p "$P"; write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "12 no .agents/runtime" 0 "no .agents/runtime"

# 13. cwd is a subdirectory of the project → the registry is still found
P="$(new_project p13)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes; mkdir -p "$P/sub/dir"
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P/sub/dir" false)
expect "13 cwd in a subdirectory" 2 "registry has running jobs"

# 14. transcript with a broken line in the middle → the rest is still parsed
P="$(new_project p14)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" wait; printf '{"type":"assistant", broken\n' >> "$P/t.jsonl"
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "14 broken transcript line tolerated" 0 "blocking wait"

# 15. the hook never writes to stdout (a Stop hook's stdout is parsed as JSON by the harness)
P="$(new_project p15)"; write_handoff "$P" "2026-09-16-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" nowait
OUT="$(bash "$HOOK" 2>/dev/null < <(stdin_json "$SID" "$P/t.jsonl" "$P" false))"
if [ -z "$OUT" ]; then pass "15 stdout stays empty"; else fail "15 hook wrote to stdout: $OUT"; fi

# --- T-154: «запущен» counts only in the status column (the LAST cell) ------
# Live false blocks (audit 02.10, 7a row 2): 20.09 the word stood in the
# history cell of row C whose status was done; 21.09 the status read
# «НЕ запущен». A running gate written INSIDE the status cell («сводка принята
# …; гейт запущен 14:33» — real rows of 15.09) must still block: that is the
# I-029 stall the hook exists for, so "the cell starts with" would be wrong.
write_row() {  # $1 project, $2 one registry row → own active HANDOFF with that row
  local f="$1/.agents/runtime/handoff/2026-10-03-run.md"
  {
    printf -- '---\nstatus: active\nsession_id: %s\ntask: тест\nupdated: 2026-10-03 01:00\n---\n\n' "$SID"
    printf '| Задание | Тикеты | История | Статус |\n|---|---|---|---|\n'
    printf '%s\n' "$2"
  } > "$f"
}
row_case() {  # $1 name, $2 registry row, $3 expected rc, $4 stderr substring, $5 project suffix
  local P
  P="$(new_project "p16-$5")"
  write_row "$P" "$2"; write_transcript "$P/t.jsonl" nowait
  run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
  expect "$1" "$3" "$4"
}
row_case "16 «запущен» only in the history cell, status done" \
  '| C | T-144 | запущен 11:22 → гейт запущен 18:15 → ре-гейт ЧИСТО | **done** — ff в main 613848a |' 0 "no running jobs" a
row_case "17 status «НЕ запущен — ПАУЗА»" \
  '| E2E | — | ждёт решения | НЕ запущен — ПАУЗА Vladimir 00:23 |' 0 "no running jobs" b
row_case "18 status «не запущено»" \
  '| A1 | T-246 | — | не запущено |' 0 "no running jobs" c
row_case "19 status «**НЕ** запущен»" \
  '| D | T-101 | — | **НЕ** запущен (ждёт C) |' 0 "no running jobs" d
row_case "20 a running gate inside the status cell still blocks" \
  '| A | T-099 | сводка 13:50 | сводка принята DONE_WITH_CONCERNS (a1bb8dd); гейт запущен 14:33 |' 2 "registry has running jobs (A / T-099" e
row_case "21 status «**запущен** 14:29 (вынесен вперёд)»" \
  '| H | T-105 | — | **запущен** 14:29 (вынесен вперёд) |' 2 "registry has running jobs (H / T-105" f
row_case "22 status «перезапущен 12:00» (a restart runs too)" \
  '| F | T-104 | фикс-раунд 1 | перезапущен 12:00 |' 2 "registry has running jobs (F / T-104" g

# «Статус» is not always the last column: 6 of 66 live registry tables
# (two client projects) keep it in the middle — `| Задание | Тикеты |
# Субагент | BASE | Статус | fix_rounds | … |`. The column is found by its
# header there; a literal "last cell" rule would switch the hook off for them.
write_table() {  # $1 project, $2 header row, $3 data row → own active HANDOFF
  local f="$1/.agents/runtime/handoff/2026-10-03-run.md" sep
  sep=$(printf '%s' "$2" | sed 's/[^|]/-/g')
  {
    printf -- '---\nstatus: active\nsession_id: %s\ntask: тест\nupdated: 2026-10-03 01:00\n---\n\n' "$SID"
    printf '%s\n%s\n%s\n' "$2" "$sep" "$3"
  } > "$f"
}
table_case() {  # $1 name, $2 header, $3 row, $4 expected rc, $5 stderr substring, $6 project suffix
  local P
  P="$(new_project "p23-$6")"
  write_table "$P" "$2" "$3"; write_transcript "$P/t.jsonl" nowait
  run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
  expect "$1" "$4" "$5"
}
MID_HDR='| Задание | Тикеты | Субагент | BASE | Статус | fix_rounds | Токены факт |'
table_case "23 «Статус» in the middle (a client project layout), status «запущен» → blocks" "$MID_HDR" \
  '| — | Side Project | арх. a8b02c28 | — | запущен | — | — |' 2 "registry has running jobs (— / Side Project" a
table_case "24 «Статус» in the middle, «запущен» only in another column, status done" "$MID_HDR" \
  '| B | T-246 | исп. запущен 11:00 | 2d1ba54d | **done** слито | 1/3 | 2.1 M |' 0 "no running jobs" b
table_case "25 «Статус» in the middle and a stray | inside a cell → the whole row is checked" "$MID_HDR" \
  '| C | T-247 | исп. a | b | 9f00aa1 | запущен 12:00 | 0/3 | — |' 2 "registry has running jobs (C / T-247" c

# A registry row appended after prose, far below its header (live: a client
# project's 2026-09-26 autopilot HANDOFF, rows 203–211) is read with the latest header
# of the file — not as a header-less table.
P="$(new_project p26)"
{
  printf -- '---\nstatus: active\nsession_id: %s\ntask: тест\nupdated: 2026-10-03 01:00\n---\n\n' "$SID"
  printf '%s\n%s\n' "$MID_HDR" '|---|---|---|---|---|---|---|'
  printf '%s\n' '| A2 | T-223 | исп. ac01831d | bfa171e2 | **done** слито | 1/3 | 1.1 M |'
  printf '\n- Владелец 27.09: Side Project — старт сейчас параллельно.\n'
  printf '%s\n' '| — | Side Project | арх. a8b02c28 | — | запущен | — | — |'
} > "$P/.agents/runtime/handoff/2026-10-03-run.md"
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "26 an orphan row after prose uses the latest header («Статус» in the middle) → blocks" 2 "registry has running jobs (— / Side Project"

# The 20.09 shape exactly: the orchestrator appended extra columns (— | — |
# history) BEFORE the status, so the row has more cells than the header, and
# «запущен» sits in that history column. «Статус» is the last header column →
# the row's last cell decides (Codex P1 suggested checking more of a
# misaligned row; that would bring this live false block back).
P="$(new_project p27)"
{
  printf -- '---\nstatus: active\nsession_id: %s\ntask: тест\nupdated: 2026-10-03 01:00\n---\n\n' "$SID"
  printf '| Задание | Тикеты | Субагент | Статус |\n|---|---|---|---|\n'
  printf '%s\n' '| C | T-144+T-145 | opus/high | — | — | сводка review 18:12; гейт запущен 18:15; ре-гейт ЧИСТО | **done** — ff в main 613848a |'
} > "$P/.agents/runtime/handoff/2026-10-03-run.md"
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "27 the 20.09 row: extra columns before «Статус», «запущен» in history, status done" 0 "no running jobs"

# An escaped pipe inside the last «Статус» cell (`\|`, valid markdown) keeps
# the cell whole: «запущен 14:00 \| ждёт B» is a running job (review 03.10 💭2).
P="$(new_project p28)"
{
  printf -- '---\nstatus: active\nsession_id: %s\ntask: тест\nupdated: 2026-10-03 01:00\n---\n\n' "$SID"
  printf '| Задание | Тикеты | Статус |\n|---|---|---|\n'
  printf '%s\n' '| B | T-200 | запущен 14:00 \| ждёт B |'
} > "$P/.agents/runtime/handoff/2026-10-03-run.md"
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "28 escaped pipe in the last «Статус» cell («запущен 14:00 \\| ждёт B») → blocks" 2 "registry has running jobs (B / T-200"

# --- foreign input (T-166) -----------------------------------------------
# A platform that is not Claude Code (Grok runs ~/.claude/settings.json hooks
# with camelCase JSON) or a broken payload: rc 0, EMPTY stdout (the skip
# reason goes to stderr only), never a block.
P="$(new_project p29)"; write_handoff "$P" "2026-10-10-run.md" active "$SID" yes
write_transcript "$P/t.jsonl" nowait
F_GROK="$(printf '{"sessionId":"%s","hookEventName":"Stop","transcriptPath":"%s","stopHookActive":false,"cwd":"%s"}' "$SID" "$P/t.jsonl" "$P")"
for inp in "" "garbage{" "$F_GROK"; do
  case "$inp" in "") lbl="empty stdin" ;; "garbage{") lbl="garbage{" ;; *) lbl="Grok camelCase" ;; esac
  OUT="$(cd "$P" && printf '%s' "$inp" | bash "$HOOK" 2>/dev/null)"; RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    pass "29 foreign: $lbl → rc=0, empty stdout"
  else
    fail "29 foreign: $lbl → expected rc=0 and empty stdout, got rc=$RC, stdout: $OUT"
  fi
done

# --- hostile registry files (QA 11.10, Ж-1) --------------------------------
# A symlink to /dev/zero (an endless line), a 10 MB file without a newline, a
# FIFO and a directory named *.md in the handoff dir of a foreign repository:
# each is skipped or read only up to 1 MB / 5000 lines BEFORE any parsing —
# the hook ends fast (<= 2 s) with rc 0 and stays small. Measured through a
# python runner that samples the process group's RSS and kills it at 10 s.
P="$(new_project p30)"
ln -s /dev/zero "$P/.agents/runtime/handoff/zz.md"
head -c 10485760 /dev/zero | tr '\0' 'a' > "$P/.agents/runtime/handoff/big.md"
mkfifo "$P/.agents/runtime/handoff/fifo.md" 2>/dev/null || true
mkdir -p "$P/.agents/runtime/handoff/dir.md"
ln -s /dev/zero "$P/.agents/runtime/autopilot-run.md"
write_transcript "$P/t.jsonl" nowait
stdin_json "$SID" "$P/t.jsonl" "$P" false > "$ROOT/p30.in"
cat > "$ROOT/bounded.py" <<'PYEOF'
import os, signal, subprocess, sys, time
t0 = time.time(); peak = 0; killed = False
p = subprocess.Popen(sys.argv[2:], stdin=open(sys.argv[1], "rb"), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
while p.poll() is None:
    out = subprocess.run(["ps", "-o", "rss=", "-g", str(p.pid)], capture_output=True, text=True).stdout
    peak = max(peak, sum(int(x) for x in out.split() if x.isdigit()))
    if time.time() - t0 > 10:
        os.killpg(p.pid, signal.SIGKILL); killed = True; break
    time.sleep(0.05)
err = p.communicate()[1].decode(errors="replace").strip().replace("\n", " | ")
print("%.2f %s %s %d %s" % (time.time() - t0, p.returncode, killed, peak, err))
PYEOF
M="$(python3 "$ROOT/bounded.py" "$ROOT/p30.in" bash "$HOOK")"
set -- $M
if [ "$2" = 0 ] && [ "$3" = False ] && awk -v t="$1" 'BEGIN { exit !(t <= 2.0) }' && [ "$4" -lt 204800 ]; then
  pass "30 symlink->/dev/zero, 10 MB one-line file, FIFO, dir.md, autopilot-run.md->/dev/zero -> rc 0 in ${1}s, peak RSS ${4} KB"
else
  fail "30 hostile registry files -> expected rc 0, <= 2 s, < 200 MB; got: $M"
fi
# ... and a regular registry next to them is still read (the guard is not
# switched off wholesale): an own running job blocks as in case 1.
# Bounded too: a hook that still reads /dev/zero must fail this case, not hang the suite.
write_handoff "$P" "2026-10-11-own.md" active "$SID" yes
M="$(python3 "$ROOT/bounded.py" "$ROOT/p30.in" bash "$HOOK")"
set -- $M
if [ "$2" = 2 ] && [ "$3" = False ] && printf '%s' "$M" | grep -q "registry has running jobs (A (волна 1) / T-001"; then
  pass "31 hostile files skipped, the own regular registry still blocks (rc 2 in ${1}s)"
else
  fail "31 hostile files + own registry -> expected rc 2 with the running row; got: $M"
fi

# 32. A long live HANDOFF: the running row stands on line 4000 (live
# registries reach ~500 lines; the old 200-line limit switched the guard off
# for them — fix round 1, 🟡-2). Still seen → BLOCK.
P="$(new_project p32)"
{
  printf -- '---\nstatus: active\nsession_id: %s\ntask: тест\nupdated: 2026-10-12 01:00\n---\n\n' "$SID"
  printf '| Задание | Тикеты | Статус |\n|---|---|---|\n| A | T-001 | done |\n'
  i=11; while [ "$i" -lt 4000 ]; do printf 'заметка %s\n' "$i"; i=$((i + 1)); done
  printf '%s\n' '| Z | T-999 | запущен 01:00 |'
} > "$P/.agents/runtime/handoff/2026-10-12-long.md"
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "32 running row on line $(grep -n 'T-999' "$P/.agents/runtime/handoff/2026-10-12-long.md" | cut -d: -f1) of a long own HANDOFF -> blocks" 2 "registry has running jobs (Z / T-999"

# --- R02 (2.1.1): the full id, exact equality; legacy 8-char compatibility ---
SID_A="01a164b4-0000-7000-8000-000000000001"; SID_B="01a164b4-ffff-7000-8000-000000000002"
# 33. a 9+-character prefix is no longer "own" (only exact equality or the legacy 8)
P="$(new_project p33)"; write_handoff "$P" "2026-10-23-run.md" active "fda3bf59-d602" yes
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "33 a 13-char prefix of the id is not own (exact equality)" 0 "skipped: no own registry"
# 34. two sessions share the first 8 characters: B's full-id registry makes the
# legacy 8-char value ambiguous → A does not take it; B still blocks on its own.
P="$(new_project p34)"; write_handoff "$P" "2026-10-23-legacy.md" active "01a164b4" yes
write_handoff "$P" "2026-10-23-b.md" active "$SID_B" yes
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID_A" "$P/t.jsonl" "$P" false)
expect "34 session A: the legacy 8-char registry is ambiguous next to B's full id -> not own" 0 "skipped: no own registry"
run_hook < <(stdin_json "$SID_B" "$P/t.jsonl" "$P" false)
expect "34a session B: its full-id registry is own -> blocks" 2 "registry has running jobs"
# 35. a full id of another session is never own, even with the same first 8
P="$(new_project p35)"; write_handoff "$P" "2026-10-23-b.md" active "$SID_B" yes
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID_A" "$P/t.jsonl" "$P" false)
expect "35 B's full id, session A with the same 8 chars -> not own" 0 "skipped: no own registry"
# 36. compatibility: a legacy 8-char autopilot-run.md alone is still guarded.
P="$(new_project p36)"
printf '# Реестр автопилота\nsession_id: fda3bf59\n\n| Задание | Тикеты | Статус |\n|---|---|---|\n| C | T-003 | запущен |\n' > "$P/.agents/runtime/autopilot-run.md"
write_transcript "$P/t.jsonl" nowait
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "36 legacy 8-char autopilot-run.md alone -> still own, blocks" 2 "C / T-003"
# 36a. two legacy registries with the same 8 chars: the prefix is ambiguous
# (the shared contract: no other registry with that prefix) -> neither is own.
write_handoff "$P" "2026-10-20-old.md" active "fda3bf59" yes
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "36a two legacy registries with one prefix -> ambiguous, not own" 0 "skipped: no own registry"

# --- R08 (2.1.1): the outcome of the last blocking wait counts ----------------
# wait_transcript <file> <tool name> <input json> <tool_result content json> [is_error] [extra record json]
wait_transcript() {
  {
    printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":"Запусти волну"}}\n'
    printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_w1","name":"%s","input":%s}]}}\n' "$2" "$3"
    printf '{"type":"user","isSidechain":false%s,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_w1","content":%s%s}]}}\n' "${6:+,$6}" "$4" "${5:+,\"is_error\":true}"
    printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Задание ещё идёт."}]}}\n'
  } > "$1"
}
TO_RUNNING='"<retrieval_status>timeout</retrieval_status>\n\n<task_id>b1</task_id>\n\n<task_type>local_agent</task_type>\n\n<status>running</status>"'
TO_DONE='"<retrieval_status>success</retrieval_status>\n\n<task_id>b1</task_id>\n\n<status>completed</status>\n\n<output>ok</output>"'
P="$(new_project p37)"; write_handoff "$P" "2026-10-23-run.md" active "$SID" yes
# 37. TaskOutput(block) timed out, the job still running → BLOCK (was: allowed)
wait_transcript "$P/t.jsonl" TaskOutput '{"task_id":"b1","block":true,"timeout":600000}' "$TO_RUNNING"
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "37 TaskOutput timed out, job running -> blocks" 2 "last blocking wait timed out"
printf '%s' "$ERR" | grep -q "record a deliberate stop in the registry" && pass "37a the reason names the deliberate-stop path" || fail "37a no deliberate-stop path in: $ERR"
# 37b. the same timeout as a list of text blocks → BLOCK
wait_transcript "$P/t.jsonl" TaskOutput '{"task_id":"b1","block":true}' '[{"type":"text","text":"<retrieval_status>timeout</retrieval_status> <status>running</status>"}]'
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "37b timeout result as content blocks -> blocks" 2 "last blocking wait timed out"
# 38. TaskOutput(block) came back finished → allowed
wait_transcript "$P/t.jsonl" TaskOutput '{"task_id":"b1","block":true}' "$TO_DONE"
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "38 TaskOutput finished -> allowed" 0 "made a blocking wait"
# 38a. finished TaskOutput whose job OUTPUT mentions <status>running</status> → allowed
wait_transcript "$P/t.jsonl" TaskOutput '{"task_id":"b1","block":true}' '"<retrieval_status>success</retrieval_status>\n\n<status>completed</status>\n\n<output>log: <status>running</status> Command timed out after 1m</output>"'
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "38a finished TaskOutput, timeout-looking words only inside <output> -> allowed" 0 "made a blocking wait"
# 38b. the structured toolUseResult decides when present (timeout + running → BLOCK)
wait_transcript "$P/t.jsonl" TaskOutput '{"task_id":"b1","block":true}' '"(no text)"' "" '"toolUseResult":{"retrieval_status":"timeout","task":{"task_id":"b1","status":"running"}}'
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "38b structured toolUseResult timeout -> blocks" 2 "last blocking wait timed out"
# 38c. a finished Bash wait (no is_error) that merely prints the phrase → allowed
wait_transcript "$P/t.jsonl" Bash '{"command":"until [ -f done.flag ]; do sleep 20; done; cat done.flag"}' '"Command timed out after 2m (quoted from an old log)"'
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "38c finished Bash wait printing the phrase, rc 0 -> allowed" 0 "made a blocking wait"
# 39. foreground Bash until-loop killed by the tool timeout → BLOCK
wait_transcript "$P/t.jsonl" Bash '{"command":"until [ -f done.flag ]; do sleep 20; done","timeout":600000}' '"Exit code 143\nCommand timed out after 10m 0s"' err
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "39 Bash until-loop timed out -> blocks" 2 "last blocking wait timed out"
# 40. council.sh --wait reported its own wait timeout → BLOCK
wait_transcript "$P/t.jsonl" Bash '{"command":"bash council.sh --wait /tmp/m --timeout 500"}' '"Exit code 1\nFAIL: wait timeout (500 s)"' err
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "40 --wait timed out -> blocks" 2 "last blocking wait timed out"
# 41. Bash until-loop finished → allowed
wait_transcript "$P/t.jsonl" Bash '{"command":"until [ -f done.flag ]; do sleep 20; done; cat done.flag"}' '"DONE"'
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "41 Bash until-loop finished -> allowed" 0 "made a blocking wait"
# 42. deliberate stop: after the timeout the registry row was re-marked → allowed
wait_transcript "$P/t.jsonl" TaskOutput '{"task_id":"b1","block":true}' "$TO_RUNNING"
write_handoff "$P" "2026-10-23-run.md" active "$SID" no
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" false)
expect "42 timeout + registry re-marked (deliberate stop) -> allowed" 0 "no running jobs"
# 43. bounded: the continuation after the nudge passes (no endless wait)
write_handoff "$P" "2026-10-23-run.md" active "$SID" yes
run_hook < <(stdin_json "$SID" "$P/t.jsonl" "$P" true)
expect "43 timeout but stop_hook_active -> passes (one nudge per turn)" 0 "stop_hook_active"

echo
echo "wait-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
