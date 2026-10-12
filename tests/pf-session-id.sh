#!/bin/bash
# tests/pf-session-id.sh — the pf-session-id.sh SessionStart hook (T-191, QA Ж-5).
# Layout as tests/wait-guard.sh: canon hooks/tests/ next to ../pf-session-id.sh,
# the pf-workflow distribution tests/ with the hook in ../hooks/. bash 3.2.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HOOK=""
for cand in "$HERE/../pf-session-id.sh" "$HERE/../hooks/pf-session-id.sh"; do
  if [ -f "$cand" ]; then HOOK="$(cd "$(dirname "$cand")" && pwd)/pf-session-id.sh"; break; fi
done
[ -n "$HOOK" ] || { echo "FAIL: pf-session-id.sh not found next to $HERE" >&2; exit 2; }
[ -x "$HOOK" ] || { echo "FAIL: $HOOK is not executable" >&2; exit 2; }

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pf-session-id-tests.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
LINE='Сессия: fda3bf59 — это значение поля session_id в HANDOFF/реестре'
IN='{"session_id":"fda3bf59-d602-451d-a7f2-a255d4dfdab1","hook_event_name":"SessionStart","source":"startup","cwd":"/tmp"}'

run() {  # run <label> <expected stdout> <stdin> [VAR=value ...]
  local label="$1" want="$2" inp="$3" out rc; shift 3
  out="$(printf '%s' "$inp" | env CLAUDE_SETTINGS_PATH="${S:-$ROOT/none.json}" "$@" bash "$HOOK" 2>/dev/null)"; rc=$?
  if [ "$rc" = 0 ] && [ "$out" = "$want" ]; then pass "$label"; else fail "$label → rc=$rc, stdout: «${out}», wanted «${want}»"; fi
}

S=""
run "1 startup -> the line with the first 8 chars of session_id" "$LINE" "$IN"
run "2 PF_COUNCIL_RUN=1 (a council.sh child) -> silent" "" "$IN" PF_COUNCIL_RUN=1
run "3 no session_id -> silent" "" '{"source":"startup"}'
run "4 garbage / empty stdin -> silent, rc 0" "" 'garbage{'
run "5 a short id (< 8 chars) -> silent" "" '{"session_id":"abc"}'
run "6 an id with shell metacharacters -> silent (never echoed)" "" '{"session_id":"$(touch x)aaaa"}'

# pf-handoff's start hook in the same settings file
PH="$ROOT/Mike's pf-handoff/hooks"; mkdir -p "$PH"
printf '#!/bin/bash\nprintf "Сессия: %%s — это значение поля session_id в HANDOFF/реестре\\n" x\n' > "$PH/sessionstart.sh"; chmod +x "$PH/sessionstart.sh"
S="$ROOT/s-new.json"
python3 - "$S" "$PH/sessionstart.sh" <<'PYEOF'
import json, sys
json.dump({"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "bash \"%s\"" % sys.argv[2]}]}]}}, open(sys.argv[1], "w"))
PYEOF
run "7 pf-handoff's sessionstart.sh registered and printing the line -> silent (no duplicate)" "" "$IN"
printf '#!/bin/bash\necho "Прочитай HANDOFF"\n' > "$PH/sessionstart.sh"
run "8 an older pf-handoff (registered, no such line) -> the line is printed" "$LINE" "$IN"
rm -f "$PH/sessionstart.sh"
run "9 registered but the file is gone -> the line is printed" "$LINE" "$IN"
printf '{"hooks": "broken"' > "$S"
run "10 broken settings JSON -> the line is printed, rc 0" "$LINE" "$IN"
S=""

# 11. stdin bound: 10 MB without a newline ends fast
head -c 10485760 /dev/zero | tr '\0' 'a' > "$ROOT/big.json"
s=$(date +%s); out="$(bash "$HOOK" < "$ROOT/big.json" 2>/dev/null)"; rc=$?; e=$(date +%s)
if [ "$rc" = 0 ] && [ -z "$out" ] && [ $((e - s)) -le 2 ]; then pass "11 10 MB stdin without a newline -> silent, rc 0, $((e - s)) s"; else fail "11 big stdin -> rc=$rc, $((e - s)) s, out: $out"; fi

echo
echo "pf-session-id tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
