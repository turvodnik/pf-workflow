#!/usr/bin/env bash
# tests/council.sh — table-driven tests for council.sh (T-112).
# One command: `bash tests/council.sh`. Never invokes a real helper: agy, grok
# and codex are fixtures/fake-helper on a curated PATH, driven by mode files;
# codex-review.sh is fixtures/fake-codex-review.sh placed next to a COPY of
# the SUT, so the `review --commit` path is covered without touching the
# real reviewer. bash 3.2 clean (see lib.sh header).
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TESTS_DIR/lib.sh"

REAL_SUT="$TESTS_DIR/../council.sh"
[ -f "$REAL_SUT" ] || { echo "cannot find SUT at $REAL_SUT"; exit 90; }
WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/council-tests-work.XXXXXXXX")"
echo "$WORKROOT" >> "$CLEANUP_DIRS_FILE"

# A copy of the SUT with the fake codex-review.sh beside it.
SUTDIR="$WORKROOT/sut"; mkdir -p "$SUTDIR"
cp "$REAL_SUT" "$SUTDIR/council.sh"; cp "$TESTS_DIR/fixtures/fake-codex-review.sh" "$SUTDIR/codex-review.sh"
SUT="$SUTDIR/council.sh"
# The launcher's secret scan (T-171) — the fake one unless a test overrides it.
export PF_SECRET_SCAN="$TESTS_DIR/fixtures/fake-secret-scan"

echo "council.sh test suite"
echo "SUT: $REAL_SUT (copied to $SUT)"
echo "bash: $BASH_BIN ($("$BASH_BIN" --version | head -1))"

# Curated PATH: the tools council.sh needs, jq, and the three fake helpers.
TOOLS="bash git printf tr grep date dirname basename mkdir sed cat rm cp mktemp wc head tail sleep cut nohup ps jq sort diff awk mv readlink cksum chmod"   # chmod: the stubs plant executable hooks / fsmonitor programs
MP="$WORKROOT/minpath"; mkdir -p "$MP"
for tool in $TOOLS; do
  src="$(PATH="$FULL_PATH" command -v "$tool" 2>/dev/null)" || { echo "harness setup: '$tool' not found" >&2; exit 90; }
  ln -sf "$src" "$MP/$tool"
done
for h in agy grok codex claude; do ln -sf "$TESTS_DIR/fixtures/fake-helper" "$MP/$h"; done
MP_NO_AGY="$WORKROOT/minpath-no-agy"; mkdir -p "$MP_NO_AGY"
for f in "$MP"/*; do [ "$(basename "$f")" = agy ] || ln -sf "$(readlink "$f")" "$MP_NO_AGY/$(basename "$f")"; done

# --- per-scenario setup ------------------------------------------------------
# scenario <name> — fresh repo + council.json (all helpers, cap 20) + stub
# control dir; sets $REPO and $CTL.
scenario() {
  REPO="$(new_repo)"
  mkdir -p "$REPO/.agents"
  printf '%s' '{"enabled": true, "backends": ["agy","grok","codex"], "daily_cap": 20, "delegate": false}' > "$REPO/.agents/council.json"
  printf '%s' '{"enabled": true}' > "$REPO/.agents/codex-review.json"   # Codex's own consent (§12); removed where a test needs it absent
  CTL="$WORKROOT/ctl-$1"; rm -rf "$CTL"; mkdir -p "$CTL"
}
set_mode() { printf '%s' "$2" > "$CTL/$1.mode"; }
calls() { cat "$CTL/calls" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
# run <timeout> <path> <args...> — SUT in $REPO with STUB_CTL exported (plus
# $EXTRA_ENV — one VAR=value (used by the canary test below).
# stdout+stderr in $out, rc in $rc.
EXTRA_ENV=""
run() {
  local t="$1" p="$2"; shift 2
  out="$( cd "$REPO" && sut_run "$t" "$p" STUB_CTL="$CTL" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" ${EXTRA_ENV:+"$EXTRA_ENV"} -- "$@" 2>&1 )"; rc=$?
}
first_line() { printf '%s\n' "$out" | head -1; }
ledger_rows() { f="$REPO/.agents/runtime/council-ledger.tsv"; if [ -f "$f" ]; then grep -c "^$(date +%Y-%m-%d)" "$f" || true; else echo 0; fi; }
# spend_rows — today's rows the daily cap counts (T-127): 7-column rows and
# outcome OK / FAIL:timeout / FAIL:other. Refusals (quota, login) and SKIPs
# are rows too, but take no slot.
spend_rows() { f="$REPO/.agents/runtime/council-ledger.tsv"; if [ -f "$f" ]; then awk -F'\t' -v d="$(date +%Y-%m-%d)" 'index($1, d) == 1 && (NF < 8 || $8 == "OK" || $8 == "FAIL:timeout" || $8 == "FAIL:other") { n++ } END { print n + 0 }' "$f"; else echo 0; fi; }
# last_outcome <helper> — outcome column of the last row of that helper.
last_outcome() { awk -F'\t' -v h="$1" '$2 == h { o = (NF >= 8) ? $8 : "n/a" } END { print o }' "$REPO/.agents/runtime/council-ledger.tsv" 2>/dev/null; }
check() { # check <label> <condition-rc> [detail]
  if [ "$2" = 0 ]; then pass "$1"; else fail "$1" "${3:-}"; fi
}

# ===========================================================================
group "consent: no council.json / enabled=false -> FAIL disabled, no helper called"
# ===========================================================================
scenario nocfg; rm -f "$REPO/.agents/council.json"
run 10 "$MP" consult -q "ping"
check "no council.json -> FAIL: council disabled, rc 1" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: council disabled for this project'; echo $? )" "rc=$rc out=$out"
check "no council.json -> no helper invoked" "$( [ -z "$(calls)" ] && echo 0 || echo 1 )" "calls=$(calls)"

scenario cfgfalse; printf '%s' '{"enabled": false}' > "$REPO/.agents/council.json"
run 10 "$MP" consult -q "ping"
check "enabled=false -> FAIL: council disabled" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: council disabled'; echo $? )" "out=$out"
printf '%s' '{"enabled": "true"}' > "$REPO/.agents/council.json"
run 10 "$MP" consult -q "ping"
check "enabled=\"true\" (a string) -> FAIL: council disabled (only the JSON boolean counts)" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: council disabled' && [ -z "$(calls)" ]; echo $? )" "out=$out"
MP_PY="$WORKROOT/minpath-py"; mkdir -p "$MP_PY"
for f in "$MP"/*; do [ "$(basename "$f")" = jq ] || ln -sf "$(readlink "$f")" "$MP_PY/$(basename "$f")"; done
ln -sf "$(PATH="$FULL_PATH" command -v python3)" "$MP_PY/python3"
run 10 "$MP_PY" consult -q "ping"
check "enabled=\"true\" on the python3 path (no jq) -> FAIL: council disabled" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: council disabled'; echo $? )" "out=$out"
printf '%s' '{"enabled": true}' > "$REPO/.agents/council.json"
run 10 "$MP_PY" consult -q "ping"
check "python3 path (no jq): a real boolean true is consent -> OK: agy" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: agy'; echo $? )" "out=$out"
printf '%s' '{"enabled": true, "daily_cap": -5}' > "$REPO/.agents/council.json"
run 10 "$MP" consult -q "ping"
check "daily_cap not a whole number -> loud FAIL, no helper" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: daily_cap' && [ "$(grep -c agy "$CTL/calls")" = 1 ]; echo $? )" "out=$out"

# ===========================================================================
group "order and fallback: agy quota -> grok answers; codex never called"
# ===========================================================================
scenario fallback; set_mode agy quota
run 20 "$MP" consult -q "answer with one word: pong"
l1="$(printf '%s\n' "$out" | sed -n 1p)"; l2="$(printf '%s\n' "$out" | sed -n 2p)"
check "line 1 = FAIL: agy quota (<CLI text>)" "$( printf '%s' "$l1" | grep -q "^FAIL: agy quota (.*usage limit"; echo $? )" "l1=$l1"
check "line 2 = OK: grok <path>, rc 0" "$( [ "$rc" = 0 ] && printf '%s' "$l2" | grep -q '^OK: grok .*/\.agents/runtime/council/.*-consult-grok-1\.md$'; echo $? )" "rc=$rc l2=$l2"
check "call order agy, grok — codex not asked" "$( [ "$(calls)" = "agy grok" ] && echo 0 || echo 1 )" "calls=$(calls)"
ans="${l2#OK: grok }"
check "answer file header line = material-not-verdict" "$( [ "$(head -1 "$ans")" = "Council answer — material, not a verdict; verify before acting" ] && echo 0 || echo 1 )" "head=$(head -1 "$ans" 2>&1)"
check "answer file carries the helper's text" "$( grep -q 'pong (grok)' "$ans"; echo $? )"
row="$(tail -1 "$REPO/.agents/runtime/council-ledger.tsv")"
check "ledger: two rows today, ONE spend row (the quota refusal is a row with outcome FAIL:quota, no cap slot)" "$( [ "$(ledger_rows)" = 2 ] && [ "$(spend_rows)" = 1 ] && [ "$(last_outcome agy)" = "FAIL:quota" ] && echo 0 || echo 1 )" "rows=$(ledger_rows) spend=$(spend_rows) agy=$(last_outcome agy)"
check "ledger row: grok · consult · 202 · 9 · 0.0123 · path · OK (8 columns)" "$( printf '%s' "$row" | grep -q "	grok	consult	202	9	0.0123	$ans	OK\$" && [ "$(printf '%s\n' "$row" | awk -F'\t' '{ print NF }')" = 8 ]; echo $? )" "row=$row"
check "chain line closes a fallback run: chain: agy:QUOTA grok:OK" "$( [ "$(printf '%s\n' "$out" | sed -n 3p)" = "chain: agy:QUOTA grok:OK" ] && echo 0 || echo 1 )" "out=$out"
check "answer dir and ledger are ignored through the LOCAL .git/info/exclude (Ж-7), the project's .gitignore untouched" "$( cd "$REPO" && git check-ignore -q .agents/runtime/council/x.md && git check-ignore -q .agents/runtime/council-ledger.tsv && git check-ignore -q .claude/worktrees/t-1/x && grep -qxF /.agents/runtime/council-ledger.tsv .git/info/exclude && [ ! -e .gitignore ]; echo $? )" "$(cat "$REPO/.git/info/exclude" 2>&1)"
check "consult prompt carries the form (## Options) and the question" "$( grep -q '^## Options' "$CTL/grok.prompt" && grep -q 'answer with one word: pong' "$CTL/grok.prompt"; echo $? )"

# ===========================================================================
group "the states, one by one"
# ===========================================================================
scenario s_notinst
run 10 "$MP" consult -q ping --order nonexistent
check "SKIP: nonexistent unknown backend (typo in council.json backends?), rc 1 — a name outside agy/grok/codex is a config typo, not a missing install" "$( [ "$rc" = 1 ] && [ "$(first_line)" = "SKIP: nonexistent unknown backend (typo in council.json backends?)" ] && echo 0 || echo 1 )" "rc=$rc out=$out"
run 10 "$MP_NO_AGY" consult -q ping --order agy
check "agy absent from PATH -> SKIP: agy not installed" "$( [ "$rc" = 1 ] && [ "$(first_line)" = "SKIP: agy not installed" ] && echo 0 || echo 1 )" "out=$out"

scenario s_notenabled; printf '%s' '{"enabled": true, "backends": ["agy"], "daily_cap": 20}' > "$REPO/.agents/council.json"
run 10 "$MP" consult -q ping --order grok
check "helper outside council.json backends -> SKIP: grok not enabled" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^SKIP: grok not enabled'; echo $? )" "out=$out"
check "not-enabled helper never invoked" "$( [ -z "$(calls)" ] && echo 0 || echo 1 )"

scenario s_login; set_mode agy login
run 10 "$MP" consult -q ping --order agy
check "FAIL: agy not logged in (<CLI text>), rc 1" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: agy not logged in (.*not logged in'; echo $? )" "out=$out"
check "not-logged-in: a row with outcome FAIL:login, answer '-', zero spend rows" "$( [ "$(ledger_rows)" = 1 ] && [ "$(spend_rows)" = 0 ] && tail -1 "$REPO/.agents/runtime/council-ledger.tsv" | grep -q "	agy	consult	-	-	-	-	FAIL:login\$"; echo $? )" "rows=$(ledger_rows) spend=$(spend_rows) row=$(tail -1 "$REPO/.agents/runtime/council-ledger.tsv" 2>&1)"

scenario s_quota; set_mode codex quota
run 10 "$MP" consult -q pong --order codex
check "--order codex under quota -> stdout STARTS with FAIL: codex quota, rc != 0" "$( [ "$rc" != 0 ] && printf '%s' "$out" | head -1 | grep -q '^FAIL: codex quota (You.ve hit your usage limit'; echo $? )" "rc=$rc out=$out"

scenario s_timeout; set_mode agy hang
run 20 "$MP" consult -q ping --order agy --timeout 1
check "hung helper -> FAIL: agy timeout (1s; ... --timeout hint), rc 1" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: agy timeout (1s; prompt [0-9]* bytes — raise --timeout'; echo $? )" "rc=$rc out=$out"
check "timeout IS logged (it may have cost): row with '-' numbers" "$( tail -1 "$REPO/.agents/runtime/council-ledger.tsv" | grep -q "	agy	consult	-	-	-	"; echo $? )" "row=$(tail -1 "$REPO/.agents/runtime/council-ledger.tsv" 2>&1)"

scenario s_crash; set_mode agy crash
run 10 "$MP" consult -q ping --order agy
check "crashing helper -> FAIL: agy error (rc=2; подробности: <raw file>) — the CLI's text is not quoted, the raw file holds it" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q "^FAIL: agy error (rc=2; подробности: .*/\.agents/runtime/council/$(date +%Y-%m-%d)-consult-agy-1\.md\.raw)\$" && ! printf '%s' "$out" | grep -q boom && grep -q boom "$REPO/.agents/runtime/council/$(date +%Y-%m-%d)-consult-agy-1.md.raw"; echo $? )" "out=$out"
check "error after a live run IS logged (the CLI ran, it may have billed): outcome FAIL:other, a spend row" "$( [ "$(ledger_rows)" = 1 ] && [ "$(spend_rows)" = 1 ] && tail -1 "$REPO/.agents/runtime/council-ledger.tsv" | grep -q "	agy	consult	-	-	-	.*-consult-agy-1\.md\.raw	FAIL:other\$"; echo $? )" "row=$(tail -1 "$REPO/.agents/runtime/council-ledger.tsv" 2>&1)"
run 10 "$MP" consult -q ping --order agy
check "second crash -> its own -2.md.raw; two ledger rows on two distinct paths" "$( [ -f "$REPO/.agents/runtime/council/$(date +%Y-%m-%d)-consult-agy-2.md.raw" ] && [ "$(cut -f7 "$REPO/.agents/runtime/council-ledger.tsv" | grep -c 'md.raw$')" = 2 ] && [ "$(cut -f7 "$REPO/.agents/runtime/council-ledger.tsv" | sort -u | grep -c 'md.raw$')" = 2 ] && echo 0 || echo 1 )" "$(ls "$REPO/.agents/runtime/council/")"
set_mode agy quota429
run 10 "$MP" consult -q ping --order agy
check "Gemini-429 body (contains the word error) -> FAIL: agy quota, row FAIL:quota (no spend slot), no .raw" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: agy quota (.*RESOURCE_EXHAUSTED' && [ "$(ledger_rows)" = 3 ] && [ "$(spend_rows)" = 2 ] && [ "$(last_outcome agy)" = "FAIL:quota" ] && [ ! -e "$REPO/.agents/runtime/council/$(date +%Y-%m-%d)-consult-agy-3.md.raw" ]; echo $? )" "out=$out rows=$(ledger_rows) spend=$(spend_rows)"
set_mode agy empty
run 10 "$MP" consult -q ping --order agy
check "rc 0 with an empty response -> FAIL: agy error (rc=0 but empty response ...), logged as a spend row" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: agy error (rc=0 but empty response' && [ "$(spend_rows)" = 3 ] && [ "$(last_outcome agy)" = "FAIL:other" ]; echo $? )" "out=$out spend=$(spend_rows)"

scenario s_ok
run 10 "$MP" consult -q ping
check "all good -> OK: agy <path>, rc 0, exactly one line" "$( [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$out" | grep -q '^OK: agy .*-consult-agy-1\.md$'; echo $? )" "rc=$rc out=$out"
check "agy ran read-only: --mode plan, --sandbox, no write flags" "$( grep -qx -- '--mode' "$CTL/agy.args" && grep -qx -- 'plan' "$CTL/agy.args" && grep -qx -- '--sandbox' "$CTL/agy.args" && [ ! -f "$CTL/agy.forbidden" ]; echo $? )" "args=$(tr '\n' ' ' < "$CTL/agy.args")"
run 10 "$MP" consult -q ping --order grok
check "grok ran read-only: --permission-mode plan, no web, no subagents, max-turns 3" "$( a="$CTL/grok.args"; grep -qx -- '--permission-mode' "$a" && grep -qx -- 'plan' "$a" && grep -qx -- '--disable-web-search' "$a" && grep -qx -- '--no-subagents' "$a" && grep -qx -- '--max-turns' "$a" && grep -qx -- '3' "$a" && [ ! -f "$CTL/grok.forbidden" ]; echo $? )" "args=$(tr '\n' ' ' < "$CTL/grok.args")"
run 10 "$MP" consult -q ping --order codex
check "codex consult ran read-only: --sandbox read-only --ephemeral, prompt via stdin (-), usage from JSONL" "$( a="$CTL/codex.args"; grep -qx -- '--sandbox' "$a" && grep -qx -- 'read-only' "$a" && grep -qx -- '--ephemeral' "$a" && [ "$(tail -1 "$a")" = "-" ] && grep -q '^## Options' "$CTL/codex.prompt" && [ ! -f "$CTL/codex.forbidden" ] && tail -1 "$REPO/.agents/runtime/council-ledger.tsv" | grep -q "	codex	consult	303	11	-	"; echo $? )" "row=$(tail -1 "$REPO/.agents/runtime/council-ledger.tsv") args=$(tr '\n' ' ' < "$CTL/codex.args")"
rm -f "$REPO/.agents/codex-review.json"
run 10 "$MP" consult -q ping --order codex
check "no codex-review.json -> SKIP: codex not consented, codex never run (council.json is not Codex's consent, §12)" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^SKIP: codex not consented' && [ "$(grep -c codex "$CTL/calls")" = 1 ]; echo $? )" "out=$out"
printf '%s' '{"enabled": false}' > "$REPO/.agents/codex-review.json"
run 10 "$MP" consult -q ping --order codex
check "codex-review.json enabled=false -> SKIP: codex not consented" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^SKIP: codex not consented'; echo $? )" "out=$out"

scenario s_async
run 10 "$MP" consult -q ping --async
marker="${out#PENDING: }"
check "--async -> PENDING: <marker>, rc 0" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^PENDING: .*/\.agents/runtime/council/.*-consult-[0-9]*\.pending$'; echo $? )" "rc=$rc out=$out"
run 30 "$MP" --wait "$marker" --timeout 20
check "--wait -> the detached run's OK line, rc 0" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: agy '; echo $? )" "rc=$rc out=$out"
scenario s_async_hang; set_mode agy hang
run 10 "$MP" consult -q ping --async --timeout 1 --order agy,grok
marker="${out#PENDING: }"
run 30 "$MP" --wait "$marker" --timeout 20
check "--async + hung helper: --wait shows FAIL: agy timeout then OK: grok (the watchdog killed one helper, not the council)" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: agy timeout (1s;' && printf '%s\n' "$out" | sed -n 2p | grep -q '^OK: grok '; echo $? )" "rc=$rc out=$out"
scenario s_async_cap
mkdir -p "$REPO/.agents/runtime/council"
{ printf '# header\n'; i=0; while [ "$i" -lt 18 ]; do i=$((i + 1)); printf '%s 10:%02d\tagy\tconsult\t1\t1\t-\tx\n' "$(date +%Y-%m-%d)" "$i"; done; } > "$REPO/.agents/runtime/council-ledger.tsv"
printf '# fake pending run\n' > "$REPO/.agents/runtime/council/$(date +%Y-%m-%d)-000000-consult-1.pending"
run 10 "$MP" consult -q ping
check "a detached run still pending reserves a cap slot: 18 rows + 1 pending + this = 20 -> OK" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: agy'; echo $? )" "out=$out"
run 10 "$MP" consult -q ping
check "... and the next call hits the cap (19 rows + 1 pending)" "$( [ "$rc" = 1 ] && [ "$(first_line)" = "FAIL: daily cap reached (20/20)" ] && echo 0 || echo 1 )" "out=$out"
printf '0\n' > "$REPO/.agents/runtime/council/$(date +%Y-%m-%d)-000000-consult-1.pending.done"
run 10 "$MP" consult -q ping
check "a signed-off marker reserves nothing" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: agy'; echo $? )" "out=$out"
run 10 "$MP" --wait "$REPO/nonexistent.pending"
check "--wait on a missing marker -> FAIL, rc 1" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: no such marker'; echo $? )" "out=$out"

# ===========================================================================
group "daily cap: 20 rows today -> FAIL before any helper runs"
# ===========================================================================
scenario cap
mkdir -p "$REPO/.agents/runtime"
{ printf '# header\n'
  i=0; while [ "$i" -lt 20 ]; do i=$((i + 1)); printf '%s 10:%02d\tagy\tconsult\t1\t1\t-\tx\n' "$(date +%Y-%m-%d)" "$i"; done
  printf '2000-01-01 10:00\tagy\tconsult\t1\t1\t-\tx\n'; } > "$REPO/.agents/runtime/council-ledger.tsv"
run 10 "$MP" consult -q ping
check "FAIL: daily cap reached (20/20), rc 1" "$( [ "$rc" = 1 ] && [ "$(first_line)" = "FAIL: daily cap reached (20/20)" ] && echo 0 || echo 1 )" "rc=$rc out=$out"
check "no helper invoked at the cap" "$( [ -z "$(calls)" ] && echo 0 || echo 1 )" "calls=$(calls)"
printf '%s' '{"enabled": true, "backends": ["agy","grok","codex"], "daily_cap": 21}' > "$REPO/.agents/council.json"
run 10 "$MP" consult -q ping
check "cap 21 with 20 rows -> one more call goes through (old-date rows not counted)" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: agy'; echo $? )" "out=$out"

# ===========================================================================
group "review: --diff and --commit (detached worktree, codex via codex-review.sh)"
# ===========================================================================
scenario rev_diff
printf 'diff --git a/a.sh b/a.sh\n+echo hello-from-diff\n' > "$REPO/change.diff"
run 10 "$MP" review --diff change.diff --order grok
check "review --diff -> OK: grok <path>-review-grok-1.md" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: grok .*-review-grok-1\.md$'; echo $? )" "out=$out"
check "review prompt: verdict form + the diff text" "$( grep -q '^## Verdict' "$CTL/grok.prompt" && grep -q '^## Checked and not found' "$CTL/grok.prompt" && grep -q 'hello-from-diff' "$CTL/grok.prompt"; echo $? )"
cwd="$(grep -A1 -x -- '--cwd' "$CTL/grok.args" | tail -1)"
check "review --diff: helper runs from an empty dir, not the live checkout; prompt says 'no tree is provided'" "$( [ "$cwd" != "$REPO" ] && [ ! -e "$cwd/seed.sh" ] && grep -q 'no tree is provided' "$CTL/grok.prompt"; echo $? )" "cwd=$cwd"
run 10 "$MP" review --diff change.diff --order codex
check "review --diff with codex -> codex exec (not codex-review.sh), read-only" "$( [ "$rc" = 0 ] && [ "$(calls)" = "grok codex" ] && grep -qx -- 'read-only' "$CTL/codex.args"; echo $? )" "calls=$(calls) out=$out"

scenario rev_commit
( cd "$REPO" && echo 'x=2' > seed.sh && PATH="$FULL_PATH" git commit -qam 'second' )
sha="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 20 "$MP" review --commit "$sha" --order agy
check "review --commit -> OK: agy, diff of the commit in the prompt, tree line honest" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: agy ' && grep -q 'x=2' "$CTL/agy.prompt" && grep -q 'the tree it belongs to' "$CTL/agy.prompt"; echo $? )" "out=$out"
check "detached worktree removed afterwards" "$( [ "$( cd "$REPO" && PATH="$FULL_PATH" git worktree list | wc -l | tr -d ' ')" = 1 ] && echo 0 || echo 1 )" "$( cd "$REPO" && PATH="$FULL_PATH" git worktree list )"
run 20 "$MP" review --commit "$sha" --order codex
check "review --commit with codex -> codex-review.sh --commit <sha>, never --yes" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: codex ' && grep -qx -- "$sha" "$CTL/codex-review.args" && ! grep -qx -- '--yes' "$CTL/codex-review.args"; echo $? )" "out=$out args=$(tr '\n' ' ' < "$CTL/codex-review.args" 2>&1)"
check "codex-review report copied under the council header" "$( f="${out#OK: codex }"; [ "$(head -1 "$f")" = "Council answer — material, not a verdict; verify before acting" ] && grep -q 'example finding' "$f"; echo $? )"
rm -f "$REPO/.agents/codex-review.json"; rm -f "$CTL/codex-review.args"
run 20 "$MP" review --commit "$sha" --order codex
check "review --commit, no codex-review.json -> SKIP: codex not consented, codex-review.sh not even called" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^SKIP: codex not consented' && [ ! -f "$CTL/codex-review.args" ]; echo $? )" "out=$out"
printf '%s' '{"enabled": true}' > "$REPO/.agents/codex-review.json"
printf 'SKIP: the human declined Codex review for this project\n' > "$CTL/codex-review.mode"
rows_before="$(spend_rows)"
run 20 "$MP" review --commit "$sha" --order codex
check "codex-review SKIP -> SKIP: codex ..., rc 1, a SKIP row and no new spend row" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^SKIP: codex the human declined' && [ "$(spend_rows)" = "$rows_before" ] && [ "$(last_outcome codex)" = SKIP ]; echo $? )" "out=$out spend=$(spend_rows) before=$rows_before codex=$(last_outcome codex)"
printf '' > "$REPO/empty.diff"; rm -f "$CTL/calls"
run 10 "$MP" review --diff empty.diff --order agy
check "--diff empty file -> FAIL before any helper (no 25k-token prompt for nothing)" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --diff needs a readable, non-empty regular file' && [ -z "$(calls)" ]; echo $? )" "out=$out"
run 10 "$MP" consult -f "$REPO" --order agy
check "-f directory -> FAIL, no helper" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: -f needs' && [ -z "$(calls)" ]; echo $? )" "out=$out"
run 10 "$MP" consult -q ping --order 'agy;touch /tmp/x'
check "--order with shell characters -> FAIL before anything runs" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --order takes helper names' && [ -z "$(calls)" ]; echo $? )" "out=$out"
run 10 "$MP" review --commit deadbeef --order agy
check "unknown commit -> FAIL, no helper called" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q "^FAIL: unknown commit" ; echo $? )" "out=$out"

# ===========================================================================
group "parallel: every helper at once, lines in --order order"
# ===========================================================================
scenario par; set_mode grok quota
run 20 "$MP" parallel -q ping
check "three lines: OK agy / FAIL grok quota / OK codex, rc 0" "$( [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | sed -n 1p | cut -c1-8)" = "OK: agy " ] && printf '%s\n' "$out" | sed -n 2p | grep -q '^FAIL: grok quota' && [ "$(printf '%s\n' "$out" | sed -n 3p | cut -c1-10)" = "OK: codex " ]; echo $? )" "rc=$rc out=$out"
check "all three helpers were invoked" "$( c="$(calls)"; printf '%s' "$c" | grep -q agy && printf '%s' "$c" | grep -q grok && printf '%s' "$c" | grep -q codex; echo $? )" "calls=$(calls)"
check "ledger: three rows, two spend rows (the quota refusal takes no slot)" "$( [ "$(ledger_rows)" = 3 ] && [ "$(spend_rows)" = 2 ] && [ "$(last_outcome grok)" = "FAIL:quota" ] && echo 0 || echo 1 )" "rows=$(ledger_rows) spend=$(spend_rows)"
printf '%s' '{"enabled": true, "backends": ["agy","grok","codex"], "daily_cap": 4}' > "$REPO/.agents/council.json"
rm -f "$CTL/grok.mode"   # grok answers again
run 20 "$MP" parallel -q ping --order nonexistent,agy,grok
check "parallel cap: a SKIPped helper takes no slot (2 rows + 2 launches = cap 4 -> both OK)" "$( [ "$rc" = 0 ] && [ "$(first_line)" = "SKIP: nonexistent unknown backend (typo in council.json backends?)" ] && printf '%s\n' "$out" | sed -n 2p | grep -q '^OK: agy' && printf '%s\n' "$out" | sed -n 3p | grep -q '^OK: grok'; echo $? )" "rc=$rc out=$out"
run 20 "$MP" parallel -q ping --order agy,grok
check "parallel cap: at the cap one FAIL line, rc 1, no helper runs" "$( [ "$rc" = 1 ] && [ "$out" = "FAIL: daily cap reached (4/4)" ] && [ "$(spend_rows)" = 4 ] && echo 0 || echo 1 )" "rc=$rc out=$out spend=$(spend_rows)"

# ===========================================================================
group "delegate: a helper writes code in an isolated worktree (T-113)"
# ===========================================================================
# del_scenario <name> — scenario + a committed ticket file + delegate: true
# (unless the test flips it) + a worktree path OUTSIDE the repo; sets $TICKET, $DWT.
del_scenario() {
  scenario "$1"
  mkdir -p "$REPO/.agents/runtime/tasks"
  printf '# T-900-drill\n\n## Задача\n\nadd helper-work.txt with one line\n' > "$REPO/.agents/runtime/tasks/T-900-drill.md"
  printf 'project rules marker: RULE-X\n' > "$REPO/AGENTS.md"
  printf '%s' '{"enabled": true, "backends": ["agy","grok","codex"], "daily_cap": 20, "delegate": true}' > "$REPO/.agents/council.json"
  ( cd "$REPO" && PATH="$FULL_PATH" git add -A && PATH="$FULL_PATH" git commit -qm 'ticket' )
  TICKET="$REPO/.agents/runtime/tasks/T-900-drill.md"
  DWT="$(cd "$WORKROOT" && pwd -P)/wt-$1"; rm -rf "$DWT"   # physical path: git prints /private/var on macOS
}
wt_commits() { ( cd "$DWT" && PATH="$FULL_PATH" git log --oneline "$1..HEAD" ) 2>/dev/null; }

del_scenario del_disabled
printf '%s' '{"enabled": true, "backends": ["agy","grok","codex"], "daily_cap": 20, "delegate": false}' > "$REPO/.agents/council.json"
set_mode agy commit
run 20 "$MP" delegate --ticket "$TICKET" --worktree "$DWT"
check "delegate: false -> FAIL: delegate disabled by project, rc != 0" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: delegate disabled by project'; echo $? )" "rc=$rc out=$out"
check "... helper not invoked, no worktree created, no ledger row" "$( [ -z "$(calls)" ] && [ ! -e "$DWT" ] && [ "$(ledger_rows)" = 0 ] && echo 0 || echo 1 )" "calls=$(calls)"
printf '%s' '{"enabled": true, "backends": ["agy","grok","codex"], "daily_cap": 20, "delegate": "true"}' > "$REPO/.agents/council.json"
run 20 "$MP" delegate --ticket "$TICKET" --worktree "$DWT"
check "delegate: \"true\" (a string) -> still FAIL: delegate disabled" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: delegate disabled by project' && [ -z "$(calls)" ]; echo $? )" "out=$out"

del_scenario del_ok; set_mode agy commit
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" delegate --ticket "$TICKET" --worktree "$DWT"
report="${out#OK: agy }"
check "stub writes a file in the worktree and commits -> OK: agy <report>, rc 0" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q "^OK: agy .*/\.agents/runtime/council/.*-delegate-agy-T-900-drill\.md\$"; echo $? )" "rc=$rc out=$out"
check "worktree created on branch delegate/T-900-drill from the repo HEAD; one helper commit" "$( [ "$( cd "$DWT" && PATH="$FULL_PATH" git rev-parse --abbrev-ref HEAD )" = "delegate/T-900-drill" ] && [ "$(wt_commits "$base" | wc -l | tr -d ' ')" = 1 ] && wt_commits "$base" | grep -q 'agy: helper-work.txt'; echo $? )" "$(wt_commits "$base")"
check "branch is not merged into the main branch" "$( cd "$REPO" && ! PATH="$FULL_PATH" git branch --merged HEAD | grep -q 'delegate/T-900-drill'; echo $? )"
check "report: header, commit line, clean status, main tree clean, helper's message" "$( [ "$(head -1 "$report")" = "Council answer — material, not a verdict; verify before acting" ] && grep -q '^## Commits' "$report" && grep -q 'agy: helper-work.txt' "$report" && grep -q '^(clean)$' "$report" && grep -q '^- main tree check: clean' "$report" && grep -q 'pong (agy)' "$report"; echo $? )" "$(head -12 "$report" 2>&1)"
check "helper ran IN the worktree, in edit mode, sandboxed, no bypass flag" "$( [ "$(cat "$CTL/agy.cwd")" = "$DWT" ] && grep -qx -- '--mode' "$CTL/agy.args" && grep -qx -- 'accept-edits' "$CTL/agy.args" && grep -qx -- '--sandbox' "$CTL/agy.args" && [ ! -f "$CTL/agy.forbidden" ]; echo $? )" "cwd=$(cat "$CTL/agy.cwd") args=$(tr '\n' ' ' < "$CTL/agy.args")"
check "prompt = contract + project AGENTS.md + the ticket; says: do not touch files outside, put Результат in the final message" "$( grep -q 'pf-do contract' "$CTL/agy.prompt" && grep -q 'RULE-X' "$CTL/agy.prompt" && grep -q 'add helper-work.txt with one line' "$CTL/agy.prompt" && grep -q 'Never touch the ticket file' "$CTL/agy.prompt" && grep -q 'Результат' "$CTL/agy.prompt"; echo $? )"
check "main repo tree unchanged by the run (helper files stay in the worktree)" "$( [ ! -e "$REPO/helper-work.txt" ] && [ -z "$( cd "$REPO" && PATH="$FULL_PATH" git status --porcelain | grep -v '\.agents/runtime/council' )" ] && echo 0 || echo 1 )" "$( cd "$REPO" && PATH="$FULL_PATH" git status --porcelain )"
check "ledger row: agy · delegate · 101 · 7 · report path · OK" "$( tail -1 "$REPO/.agents/runtime/council-ledger.tsv" | grep -q "	agy	delegate	101	7	-	$report	OK\$"; echo $? )" "row=$(tail -1 "$REPO/.agents/runtime/council-ledger.tsv")"
rm -f "$CTL/calls"
run 30 "$MP" delegate --ticket "$TICKET" --worktree "$DWT"
check "re-run on the now-clean worktree: helper runs again, second report is -2 (no overwrite)" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q -- '-delegate-agy-T-900-drill-2\.md$' && [ -f "$report" ]; echo $? )" "out=$out"

del_scenario del_outside; set_mode agy outside
printf '%s' "$REPO/leaked.txt" > "$CTL/outside.path"
run 30 "$MP" delegate --ticket "$TICKET" --worktree "$DWT"
report="$(printf '%s' "$out" | sed -n 's/.*report: \(.*\))$/\1/p')"
check "stub writes a file in the MAIN tree -> FAIL: agy touched files outside worktree (1 path(s): ?? leaked.txt ...), rc != 0" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: agy touched files outside worktree (1 path(s): ?? leaked.txt'; echo $? )" "rc=$rc out=$out"
check "... the report exists and names the leaked path (the gate must see it); ledger row logged (the CLI ran)" "$( [ -f "$report" ] && grep -q '^## Files changed outside the worktree' "$report" && grep -q '^?? leaked.txt' "$report" && [ "$(ledger_rows)" = 1 ]; echo $? )" "report=$report"
check "... no fallback to the next helper once one has worked in the tree (codex, grok not asked)" "$( [ "$(calls)" = "agy" ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] && echo 0 || echo 1 )" "calls=$(calls) out=$out"
check "... worktree and its commit are kept for inspection (never removed)" "$( [ -d "$DWT" ] && [ -f "$DWT/helper-work.txt" ] && echo 0 || echo 1 )"
rm -f "$REPO/leaked.txt"
del_scenario del_outside_dir; set_mode agy outside
mkdir -p "$REPO/udir"; printf 'a\n' > "$REPO/udir/a.txt"          # an already-untracked directory in the main tree
printf '%s' "$REPO/udir/b.txt" > "$CTL/outside.path"
run 30 "$MP" delegate --ticket "$TICKET" --worktree "$DWT"
check "stub writes a NEW file inside an already-untracked directory of the main tree -> still FAIL outside (?? udir/b.txt; -uall, not a folded ?? udir/)" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: agy touched files outside worktree (1 path(s): ?? udir/b.txt'; echo $? )" "rc=$rc out=$out"
rm -rf "$REPO/udir"
del_scenario del_outside_untracked; set_mode agy outside
printf 'unsaved journal\n' > "$REPO/notes.md"                      # an ALREADY-untracked file of the main tree, before the run
printf '%s' "$REPO/notes.md" > "$CTL/outside.path"                 # the stub overwrites it (content changes, status does not)
run 30 "$MP" delegate --ticket "$TICKET" --worktree "$DWT"
check "stub OVERWRITES a file that was already untracked before the run -> still FAIL outside (1 path(s): ?? notes.md) — content hash, not just status (T-124 review)" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: agy touched files outside worktree (1 path(s): ?? notes.md' && [ "$(cat "$REPO/notes.md")" = leak ]; echo $? )" "rc=$rc out=$out"
rm -f "$REPO/notes.md"

del_scenario del_dirty; set_mode agy commit
( cd "$REPO" && PATH="$FULL_PATH" git worktree add -q "$DWT" -b delegate/T-900-drill ) && printf 'wip\n' > "$DWT/wip.txt"
run 20 "$MP" delegate --ticket "$TICKET" --worktree "$DWT"
check "existing worktree with an uncommitted file -> FAIL: worktree dirty, rc != 0, helper not invoked" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q "^FAIL: worktree dirty ($DWT)" && [ -z "$(calls)" ]; echo $? )" "rc=$rc out=$out"
rm -f "$DWT/wip.txt"
run 30 "$MP" delegate --ticket "$TICKET" --worktree "$DWT"
check "same worktree once clean -> OK (an existing worktree of the repo is reused)" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: agy '; echo $? )" "out=$out"
mkdir -p "$WORKROOT/notawt-del"; rm -f "$CTL/calls"
run 20 "$MP" delegate --ticket "$TICKET" --worktree "$WORKROOT/notawt-del"
check "existing directory that is not a worktree of the repo -> FAIL, helper not invoked" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --worktree exists but is not a worktree' && [ -z "$(calls)" ]; echo $? )" "out=$out"

del_scenario del_order; set_mode agy quota; set_mode codex commit
run 30 "$MP" delegate --ticket "$TICKET" --worktree "$DWT"
check "default delegate order agy -> codex -> grok: agy quota, codex answers; grok not asked" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: agy quota' && printf '%s\n' "$out" | sed -n 2p | grep -q '^OK: codex ' && [ "$(calls)" = "agy codex" ]; echo $? )" "rc=$rc out=$out calls=$(calls)"
check "codex delegate: -C <worktree>, --sandbox workspace-write, network off, prompt on stdin, no bypass flag" "$( a="$CTL/codex.args"; grep -qx -- "$DWT" "$a" && grep -qx -- '-C' "$a" && grep -qx -- 'workspace-write' "$a" && grep -qx -- 'sandbox_workspace_write.network_access=false' "$a" && [ "$(tail -1 "$a")" = "-" ] && grep -q 'pf-do contract' "$CTL/codex.prompt" && [ ! -f "$CTL/codex.forbidden" ] && [ "$(cat "$CTL/codex.cwd")" = "$DWT" ]; echo $? )" "args=$(tr '\n' ' ' < "$CTL/codex.args")"
check "worktree created only once, agy's refusal did not consume it: codex's commit is there" "$( wt_commits "$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )" | grep -q 'codex: helper-work.txt'; echo $? )"
del_scenario del_grok; set_mode grok commit
run 30 "$MP" delegate --ticket "$TICKET" --worktree "$DWT" --order grok
check "grok delegate: --cwd <worktree>, --permission-mode acceptEdits, web off, no subagents, no bypass flag" "$( a="$CTL/grok.args"; [ "$rc" = 0 ] && grep -A1 -x -- '--cwd' "$a" | tail -1 | grep -qx -- "$DWT" && grep -A1 -x -- '--permission-mode' "$a" | tail -1 | grep -qx 'acceptEdits' && grep -qx -- '--disable-web-search' "$a" && grep -qx -- '--no-subagents' "$a" && [ ! -f "$CTL/grok.forbidden" ]; echo $? )" "rc=$rc out=$out args=$(tr '\n' ' ' < "$CTL/grok.args")"
check "grok delegate allowlist: exactly the documented rules (file tools, git add/commit + read-only git, bash, sh, cd) and nothing wider" "$( [ "$(grep -A1 -x -- '--allow' "$CTL/grok.args" | grep -v -- '^--allow$' | grep -v '^--$' | LC_ALL=C sort | tr '\n' '|')" = "$(printf '%s\n' 'Bash(bash:*)' 'Bash(cd:*)' 'Bash(git add:*)' 'Bash(git commit:*)' 'Bash(git diff:*)' 'Bash(git log:*)' 'Bash(git rev-parse:*)' 'Bash(git show:*)' 'Bash(git status:*)' 'Bash(sh:*)' Edit MultiEdit Write | LC_ALL=C sort | tr '\n' '|')" ] && echo 0 || echo 1 )" "$(grep -A1 -x -- '--allow' "$CTL/grok.args" | tr '\n' ' ')"
rm -f "$REPO/.agents/codex-review.json"; rm -f "$CTL/calls"; rm -rf "$DWT"; ( cd "$REPO" && PATH="$FULL_PATH" git worktree prune && PATH="$FULL_PATH" git branch -qD delegate/T-900-drill )
run 20 "$MP" delegate --ticket "$TICKET" --worktree "$DWT" --order codex
check "codex delegate without codex-review.json -> SKIP: codex not consented; codex never run; the unused worktree is taken back" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q '^SKIP: codex not consented' && [ -z "$(calls)" ] && [ ! -e "$DWT" ]; echo $? )" "out=$out"

del_scenario del_uncommitted; set_mode agy dirty
run 30 "$MP" delegate --ticket "$TICKET" --worktree "$DWT"
report="$(first_line)"; report="${report#OK: agy }"
check "helper leaves work uncommitted -> OK plus a NOTE line naming the count; report shows the porcelain line" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: agy ' && printf '%s\n' "$out" | sed -n 2p | grep -q '^NOTE: 1 path(s) left uncommitted in' && grep -q '^?? helper-work.txt' "$report"; echo $? )" "rc=$rc out=$out"
del_scenario del_nochange   # stub mode ok: answers, changes nothing
run 30 "$MP" delegate --ticket "$TICKET" --worktree "$DWT" --order agy
check "helper exits 0 but changed nothing -> FAIL: agy error (rc=0 but no changes in worktree ...), report kept, ledger row" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: agy error (rc=0 but no changes in worktree' && [ "$(ledger_rows)" = 1 ]; echo $? )" "rc=$rc out=$out"
set_mode codex commit; rm -f "$CTL/calls"
run 30 "$MP" delegate --ticket "$TICKET" --worktree "$DWT" --order agy,codex
check "a helper that changed nothing falls through (the base is intact): agy no-changes FAIL, then OK: codex with its commit" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: agy error (rc=0 but no changes' && printf '%s\n' "$out" | sed -n 2p | grep -q '^OK: codex ' && [ "$(calls)" = "agy codex" ]; echo $? )" "rc=$rc out=$out"
del_scenario del_quota_after; set_mode agy quota-after-commit; set_mode codex commit
run 30 "$MP" delegate --ticket "$TICKET" --worktree "$DWT"
check "quota text AFTER the helper committed -> FAIL: agy error (rc=1 after changing the worktree ...), NOT quota; no fallback; worktree and commit kept" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: agy error (rc=1 after changing the worktree' && [ "$(calls)" = "agy" ] && [ -d "$DWT" ] && wt_commits "$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )" | grep -q 'agy: helper-work.txt' && [ "$(ledger_rows)" = 1 ]; echo $? )" "rc=$rc out=$out calls=$(calls)"
del_scenario del_branch; set_mode agy commit
( cd "$REPO" && PATH="$FULL_PATH" git worktree add -q "$DWT" -b other-work )
run 20 "$MP" delegate --ticket "$TICKET" --worktree "$DWT"
check "existing clean worktree on another branch -> FAIL (commits would land on the wrong branch), helper not invoked" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q "^FAIL: --worktree is on branch 'other-work', not delegate/T-900-drill" && [ -z "$(calls)" ]; echo $? )" "out=$out"
del_scenario del_args; set_mode agy commit
run 20 "$MP" delegate --ticket "$TICKET" --worktree "$REPO/inner-wt"
check "--worktree inside the repository -> FAIL before anything runs" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --worktree must lie outside' && [ -z "$(calls)" ]; echo $? )" "out=$out"
rm -f "$CTL/calls"
run 20 "$MP" delegate --ticket "$TICKET" --worktree "$DWT" -q "also this"
check "delegate with -q -> FAIL (delegate takes --ticket and --worktree only)" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: delegate takes --ticket and --worktree' && [ -z "$(calls)" ]; echo $? )" "out=$out"
run 20 "$MP" consult -q ping --worktree "$DWT"
check "--worktree outside delegate -> FAIL" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --ticket, --worktree and --repo belong to delegate' && [ -z "$(calls)" ]; echo $? )" "out=$out"
rm -f "$CTL/calls"
run 20 "$MP" delegate --ticket "$REPO/no-such-ticket.md" --worktree "$DWT"
check "missing --ticket file -> FAIL before any helper, no worktree created" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --ticket needs a readable, non-empty regular file' && [ -z "$(calls)" ] && [ ! -e "$DWT" ]; echo $? )" "out=$out"
del_scenario del_async; set_mode agy commit
run 20 "$MP" delegate --ticket "$TICKET" --worktree "$DWT" --async
marker="${out#PENDING: }"
run 40 "$MP" --wait "$marker" --timeout 30
check "delegate --async -> PENDING, then --wait shows OK: agy (ticket/worktree survive the relaunch)" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: agy .*-delegate-agy-T-900-drill\.md$' && [ -f "$DWT/helper-work.txt" ]; echo $? )" "rc=$rc out=$out"

# ===========================================================================
group "delegate --audit: worktree inside the project, removed after the report, journal entry (T-124)"
# ===========================================================================
# The audited project is $REPO; its physical path is what the SUT prints
# (pwd -P: /private/var on macOS). Worktree list of a repo with no extra
# worktree = exactly one line.
wt_count() { ( cd "$REPO" && PATH="$FULL_PATH" git worktree list ) | grep -c .; }
# jgrep <grep args> — grep over the project's journal of today, reading the
# file directly (no `cat | grep -q`: under pipefail an early grep exit can
# SIGPIPE the cat). Regex quantifiers inside a "$( … )" condition must not
# contain a comma: bash 3.2 brace-expands "{7,}" there and splits the word.
JOURNAL_NAME="$(date +%Y-%m-%d).md"
jgrep() { grep "$@" "$REPO/.agents/journal/$JOURNAL_NAME" 2>/dev/null; }
journal() { cat "$REPO/.agents/journal/$JOURNAL_NAME" 2>/dev/null; }

del_scenario del_audit_ok; set_mode agy commit
PREPO="$(cd "$REPO" && pwd -P)"; base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" delegate --audit --project "$REPO" --ticket "$TICKET" --order agy
note="$(printf '%s\n' "$out" | grep '^NOTE: audit worktree ')"
check "audit: OK: agy <report>, then NOTE: audit worktree <project>/.claude/worktrees/audit-<date> removed; branch delegate/T-900-drill-audit-<date>; rc 0" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: agy .*-delegate-agy-T-900-drill\.md$' && printf '%s' "$note" | grep -q "^NOTE: audit worktree $PREPO/\.claude/worktrees/audit-$(date +%Y-%m-%d) removed; branch delegate/T-900-drill-audit-$(date +%Y-%m-%d) keeps the findings\$"; echo $? )" "rc=$rc out=$out"
check "audit: worktree removed after the report (worktree list = 1 line, directory gone), .claude/worktrees/ created, branch delegate/T-900-drill keeps the helper's commit" "$( [ "$(wt_count)" = 1 ] && [ ! -e "$PREPO/.claude/worktrees/audit-$(date +%Y-%m-%d)" ] && [ -d "$PREPO/.claude/worktrees" ] && ( cd "$REPO" && PATH="$FULL_PATH" git log --oneline "$base..delegate/T-900-drill-audit-$(date +%Y-%m-%d)" ) | grep -q 'agy: helper-work.txt'; echo $? )" "wt=$(cd "$REPO" && PATH="$FULL_PATH" git worktree list)"
check "audit: helper ran IN the audit worktree (cwd = <project>/.claude/worktrees/audit-<date>)" "$(if [ "$(cat "$CTL/agy.cwd")" = "$PREPO/.claude/worktrees/audit-$(date +%Y-%m-%d)" ]; then echo 0; else echo 1; fi)" "cwd=$(cat "$CTL/agy.cwd")"
check "audit: journal entry '## HH:MM · council delegate --audit · agy' in <project>/.agents/journal/<date>.md naming the worktree, the branch and 'removed'" "$( jgrep -qE '^## [0-9]{2}:[0-9]{2} · council delegate --audit · agy$' && jgrep -q "worktree $PREPO/.claude/worktrees/audit-" && jgrep -q "delegate/T-900-drill-audit-$(date +%Y-%m-%d)" && jgrep -q 'worktree — removed' && jgrep -qE "^Коммит: delegate/T-900-drill-audit-$(date +%Y-%m-%d) @ [0-9a-f]{7}[0-9a-f]* [(]база [0-9a-f]{7}[0-9a-f]*[)][.]\$"; echo $? )" "journal=$(journal)"
check "audit: prompt carries the audit contract — closed packets before reporting, journal INSIDE the worktree, no claims file, leave it clean" "$( grep -q 'AUDIT under the project' "$CTL/agy.prompt" && grep -q 'read the closed task packets' "$CTL/agy.prompt" && grep -q 'INSIDE this worktree' "$CTL/agy.prompt" && grep -q 'do not write to any' "$CTL/agy.prompt" && grep -q 'Leave the worktree CLEAN' "$CTL/agy.prompt" && grep -q 'RULE-X' "$CTL/agy.prompt"; echo $? )"
check "audit: main tree moved only by the launcher (journal, council dir) — the helper's file is not there; ledger row OK" "$(if [ ! -e "$REPO/helper-work.txt" ] && [ -z "$( cd "$REPO" && PATH="$FULL_PATH" git status --porcelain | grep -v '\.agents/runtime/council\|\.agents/journal/\|\.claude/' )" ] && [ "$(last_outcome agy)" = OK ]; then echo 0; else echo 1; fi)" "$( cd "$REPO" && PATH="$FULL_PATH" git status --porcelain )"
# Without --project the project is the root this runs in (cwd = $REPO in run).
# A REPEAT with the same ticket and no manual clean-up (the next night): the
# first run's branch stays, so the second gets -2, cut from the CURRENT head.
rm -f "$CTL/calls"
run 30 "$MP" delegate --audit --ticket "$TICKET" --order agy
check "audit without --project, repeated with the same ticket: the project root this runs in, same default worktree path, removed again, branch -2 (no manual branch -D needed)" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q "^NOTE: audit worktree $PREPO/\.claude/worktrees/audit-$(date +%Y-%m-%d) removed; branch delegate/T-900-drill-audit-$(date +%Y-%m-%d)-2 keeps" && [ "$(wt_count)" = 1 ] && [ "$( cd "$REPO" && PATH="$FULL_PATH" git log --oneline "$base..delegate/T-900-drill-audit-$(date +%Y-%m-%d)-2" | grep -c . )" = 1 ]; echo $? )" "rc=$rc out=$out branches=$(cd "$REPO" && PATH="$FULL_PATH" git branch | tr '\n' ' ')"

del_scenario del_audit_dirty; set_mode agy dirty
PREPO="$(cd "$REPO" && pwd -P)"
run 30 "$MP" delegate --audit --project "$REPO" --ticket "$TICKET" --order agy
check "helper leaves an uncommitted file -> FAIL: audit worktree dirty <path>, rc != 0 even though the helper's own line is OK + NOTE" "$( [ "$rc" != 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: agy ' && printf '%s\n' "$out" | grep -q "^FAIL: audit worktree dirty $PREPO/\.claude/worktrees/audit-$(date +%Y-%m-%d) .*branch delegate/T-900-drill-audit-$(date +%Y-%m-%d)\$"; echo $? )" "rc=$rc out=$out"
check "... the dirty worktree is KEPT for a human (list = 2, file still there), journal entry says KEPT — dirty" "$( [ "$(wt_count)" = 2 ] && [ -f "$PREPO/.claude/worktrees/audit-$(date +%Y-%m-%d)/helper-work.txt" ] && jgrep -q '· council delegate --audit · agy' && jgrep -q 'KEPT — dirty'; echo $? )" "journal=$(journal)"

del_scenario del_audit_outside; set_mode agy commit
PREPO="$(cd "$REPO" && pwd -P)"
run 20 "$MP" delegate --audit --project "$REPO" --ticket "$TICKET" --worktree "$WORKROOT/outside-audit"
check "--audit with --worktree outside the project -> FAIL: --worktree <path> outside <project>/.claude/worktrees, rc 1, helper not invoked" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q "^FAIL: --worktree .*/outside-audit outside $PREPO/\.claude/worktrees" && [ -z "$(calls)" ]; echo $? )" "rc=$rc out=$out"
check "... nothing created: worktree list unchanged (1 line), the outside path does not exist" "$(if [ "$(wt_count)" = 1 ] && [ ! -e "$WORKROOT/outside-audit" ]; then echo 0; else echo 1; fi)"
run 20 "$MP" delegate --audit --project "$REPO" --ticket "$TICKET" --worktree "$REPO/.claude/worktrees/../../escape"
check "... a '..' escape under the right prefix is refused too (physical parent != <project>/.claude/worktrees)" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q "outside $PREPO/\.claude/worktrees" && [ ! -e "$REPO/escape" ] && [ -z "$(calls)" ]; echo $? )" "out=$out"
check "... a refused path creates nothing: no <project>/.claude/worktrees directory yet" "$(if [ ! -e "$REPO/.claude/worktrees" ]; then echo 0; else echo 1; fi)" "$(ls -la "$REPO/.claude" 2>&1)"
mkdir -p "$REPO/.claude" "$WORKROOT/evil"; ln -s "$WORKROOT/evil" "$REPO/.claude/worktrees"   # H1: .claude/worktrees is a symlink OUT of the project
run 20 "$MP" delegate --audit --project "$REPO" --ticket "$TICKET"
check "H1: <project>/.claude/worktrees is a symlink pointing outside -> FAIL outside (both sides resolved physically would agree; the expected root is built from the project path), nothing created, helper not invoked" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q "^FAIL: --worktree .* outside $PREPO/\.claude/worktrees" && [ -z "$(ls -A "$WORKROOT/evil")" ] && [ "$(wt_count)" = 1 ] && [ -z "$(calls)" ]; echo $? )" "rc=$rc out=$out"
rm -f "$REPO/.claude/worktrees"
run 20 "$MP" delegate --audit --project "$REPO" --ticket "$TICKET" --worktree "$REPO/.claude/worktrees/night-1"
check "... an explicit direct child of <project>/.claude/worktrees is accepted and removed after the report" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q "^NOTE: audit worktree $PREPO/\.claude/worktrees/night-1 removed; branch delegate/T-900-drill-night-1 keeps" && [ "$(wt_count)" = 1 ]; echo $? )" "rc=$rc out=$out"
rm -f "$CTL/calls"
run 20 "$MP" delegate --project "$REPO" --ticket "$TICKET" --worktree "$DWT"
check "--project without --audit -> FAIL, helper not invoked" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --project belongs to delegate --audit' && [ -z "$(calls)" ]; echo $? )" "out=$out"
run 20 "$MP" delegate --audit --repo "$REPO" --ticket "$TICKET"
check "--audit with --repo -> FAIL (the audited project's repository holds the worktree)" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --audit takes --project' && [ -z "$(calls)" ]; echo $? )" "out=$out"
run 20 "$MP" consult -q ping --audit
check "--audit outside delegate -> FAIL" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --audit and --project belong to delegate' && [ -z "$(calls)" ]; echo $? )" "out=$out"

del_scenario del_audit_chain; set_mode agy quota; set_mode codex commit
PREPO="$(cd "$REPO" && pwd -P)"
run 30 "$MP" delegate --audit --project "$REPO" --ticket "$TICKET"
check "audit fallback: agy quota -> the worktree stays for codex, codex works, THEN it is removed; journal names codex" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: agy quota' && printf '%s\n' "$out" | sed -n 2p | grep -q '^OK: codex ' && printf '%s\n' "$out" | sed -n 3p | grep -q '^NOTE: audit worktree .* removed' && [ "$(calls)" = "agy codex" ] && [ "$(wt_count)" = 1 ] && jgrep -q '· council delegate --audit · codex$'; echo $? )" "rc=$rc out=$out calls=$(calls)"

del_scenario del_audit_async; set_mode agy commit
PREPO="$(cd "$REPO" && pwd -P)"
run 20 "$MP" delegate --audit --project "$REPO" --ticket "$TICKET" --async
marker="${out#PENDING: }"
run 40 "$MP" --wait "$marker" --timeout 30
check "delegate --audit --async -> --wait shows OK: agy and NOTE: audit worktree removed (the flags survive the relaunch)" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: agy ' && printf '%s\n' "$out" | grep -q "^NOTE: audit worktree $PREPO/\.claude/worktrees/audit-" && [ "$(wt_count)" = 1 ]; echo $? )" "rc=$rc out=$out"

# ===========================================================================
group "T-127: fallback chain, order from council.json, outcome column, --stats"
# ===========================================================================
# (b) review --diff, no --order: the json array is the order; agy refuses
# (quota), grok answers; the run closes with the chain line.
scenario t127_chain; set_mode agy quota
printf 'diff --git a/a.sh b/a.sh\n+echo chain-test\n' > "$REPO/change.diff"
run 20 "$MP" review --diff change.diff
check "review --diff, agy quota -> grok OK: chain: agy:QUOTA grok:OK on the last line, rc 0" "$( [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | tail -1)" = "chain: agy:QUOTA grok:OK" ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: agy quota' && printf '%s\n' "$out" | sed -n 2p | grep -q '^OK: grok '; echo $? )" "rc=$rc out=$out"
check "(c) the ledger's last row has 8 fields, outcome OK; agy's row FAIL:quota with answer '-'" "$( [ "$(awk -F'\t' '{ print NF }' "$REPO/.agents/runtime/council-ledger.tsv" | tail -1)" = 8 ] && [ "$(last_outcome grok)" = OK ] && grep -q "	agy	review	-	-	-	-	FAIL:quota$" "$REPO/.agents/runtime/council-ledger.tsv"; echo $? )" "$(cat "$REPO/.agents/runtime/council-ledger.tsv")"
check "ledger header names the outcome column" "$( [ "$(head -1 "$REPO/.agents/runtime/council-ledger.tsv")" = "$(printf '# date\thelper\tmode\tinput\toutput\tcost\tanswer\toutcome')" ] && echo 0 || echo 1 )" "$(head -1 "$REPO/.agents/runtime/council-ledger.tsv")"
rm -f "$CTL/agy.mode"
run 10 "$MP" consult -q ping
check "a single OK stays exactly one line (no chain line when only one helper was tried)" "$(if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ]; then echo 0; else echo 1; fi)" "out=$out"
run 10 "$MP" consult -q ping --order nonexistent,agy
check "a SKIP is a chain token too: chain: nonexistent:SKIP agy:OK; SKIP row in the ledger, no spend slot" "$(if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | tail -1)" = "chain: nonexistent:SKIP agy:OK" ] && [ "$(last_outcome nonexistent)" = SKIP ]; then echo 0; else echo 1; fi)" "out=$out"
set_mode agy hang; set_mode grok crash
run 20 "$MP" consult -q ping --order agy,grok,codex --timeout 1
check "timeout then crash then OK: chain: agy:TIMEOUT grok:ERROR codex:OK; outcomes FAIL:timeout / FAIL:other" "$(if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | tail -1)" = "chain: agy:TIMEOUT grok:ERROR codex:OK" ] && [ "$(last_outcome agy)" = "FAIL:timeout" ] && [ "$(last_outcome grok)" = "FAIL:other" ]; then echo 0; else echo 1; fi)" "out=$out"
rm -f "$CTL/agy.mode" "$CTL/grok.mode"
# codex under quota through codex-review.sh (review --commit): the new
# `FAIL: QUOTA (until <date>)` line of codex-review.sh reads as quota here.
( cd "$REPO" && echo 'y=1' > seed.sh && PATH="$FULL_PATH" git commit -qam 'second' )
sha="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
printf "FAIL: QUOTA (until 2026-09-20) — Codex review did not produce output (exit=1, 1s, limit 540s). Treat as 'not reviewed', never as 'clean'.\n" > "$CTL/codex-review.mode"
run 20 "$MP" review --commit "$sha" --order codex,grok
check "codex-review.sh FAIL: QUOTA -> FAIL: codex quota (...), grok answers, chain: codex:QUOTA grok:OK" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex quota (FAIL: QUOTA (until 2026-09-20)' && [ "$(printf '%s\n' "$out" | tail -1)" = "chain: codex:QUOTA grok:OK" ] && [ "$(last_outcome codex)" = "FAIL:quota" ]; echo $? )" "rc=$rc out=$out"
rm -f "$CTL/codex-review.mode"

# Order from council.json: the array is the order; --order still overrides.
scenario t127_order
printf '%s' '{"enabled": true, "backends": ["grok","agy"], "daily_cap": 20}' > "$REPO/.agents/council.json"
run 10 "$MP" consult -q ping
check "backends [grok, agy], no --order -> grok is asked first and answers" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: grok ' && [ "$(calls)" = "grok" ]; echo $? )" "out=$out calls=$(calls)"
run 10 "$MP" consult -q ping --order agy
check "--order agy overrides the json order" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: agy '; echo $? )" "out=$out"
run 10 "$MP" consult -q ping --order codex
check "a helper outside backends stays SKIP: not enabled (the array is both the set and the order)" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^SKIP: codex not enabled'; echo $? )" "out=$out"
printf '%s' '{"enabled": true}' > "$REPO/.agents/council.json"; rm -f "$CTL/calls"
run 10 "$MP" consult -q ping
check "no backends array -> agy,grok,codex as before" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: agy '; echo $? )" "out=$out"

# A pre-T-127 ledger (7 columns): the header is upgraded on the first run
# that writes, old rows keep 7 fields and read as n/a.
scenario t127_old; mkdir -p "$REPO/.agents/runtime"
{ printf '# date\thelper\tmode\tinput\toutput\tcost\tanswer\n'
  printf '2026-09-16 20:51\tagy\tconsult\t25123\t5681\t-\told.md\n'
  printf '2026-09-16 20:52\tgrok\tconsult\t30830\t750\t0.02\told2.md\n'; } > "$REPO/.agents/runtime/council-ledger.tsv"
run 10 "$MP" consult -q ping --order agy
check "old 7-column ledger: header upgraded to 8 names, old rows untouched (7 fields), new row 8 fields" "$(if [ "$rc" = 0 ] && [ "$(head -1 "$REPO/.agents/runtime/council-ledger.tsv" | awk -F'\t' '{ print NF }')" = 8 ] && [ "$(sed -n 2p "$REPO/.agents/runtime/council-ledger.tsv" | awk -F'\t' '{ print NF }')" = 7 ] && [ "$(tail -1 "$REPO/.agents/runtime/council-ledger.tsv" | awk -F'\t' '{ print NF }')" = 8 ] && [ "$(grep -c '^#' "$REPO/.agents/runtime/council-ledger.tsv")" = 1 ]; then echo 0; else echo 1; fi)" "$(cat "$REPO/.agents/runtime/council-ledger.tsv")"
# (d) --stats: helper × outcome table; old rows under n/a; --since filters.
run 10 "$MP" --stats
check "--stats: rc 0, a row for each of agy / grok / codex, old rows under n/a, today's OK counted" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '^helper ' && printf '%s\n' "$out" | grep -qE '^agy +1 +0 +0 +0 +0 +0 +0 +1 +2$' && printf '%s\n' "$out" | grep -qE '^grok +0 +0 +0 +0 +0 +0 +0 +1 +1$' && printf '%s\n' "$out" | grep -qE '^codex +0 +0 +0 +0 +0 +0 +0 +0 +0$'; echo $? )" "rc=$rc out=$out"
run 10 "$MP" --stats --since "$(date +%Y-%m-%d)"
check "--stats --since today: the 2026-09-16 rows drop out (agy 1 OK, 0 n/a)" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qE '^agy +1 +0 +0 +0 +0 +0 +0 +0 +1$' && printf '%s\n' "$out" | grep -qE '^grok +0 +0 +0 +0 +0 +0 +0 +0 +0$'; echo $? )" "out=$out"
run 10 "$MP" --stats --since 2026-9-1
check "--since not YYYY-MM-DD -> FAIL, rc 1" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --since takes YYYY-MM-DD'; echo $? )" "out=$out"
rm -f "$REPO/.agents/council.json"
run 10 "$MP" --stats
check "--stats needs no council.json (read-only): rc 0 without consent" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qE '^agy +1 '; echo $? )" "rc=$rc out=$out"
# (h) a damaged row (3 fields): WARN on stderr, the table still prints, rc 0.
printf 'broken\trow\there\n' >> "$REPO/.agents/runtime/council-ledger.tsv"
err="$( cd "$REPO" && sut_run 10 "$MP" STUB_CTL="$CTL" HOME="$HOME" -- --stats 2>&1 >/dev/null )"; rc=$?
run 10 "$MP" --stats
check "damaged 3-field row -> 'WARN: ledger line 5 has 3 field(s), skipped' on stderr, rc 0, table intact" "$( [ "$rc" = 0 ] && [ "$err" = "WARN: ledger line 5 has 3 field(s), skipped" ] && printf '%s\n' "$out" | grep -qE '^agy +1 +0 +0 +0 +0 +0 +0 +1 +2$'; echo $? )" "rc=$rc err=$err out=$out"
so="$( cd "$REPO" && sut_run 10 "$MP" STUB_CTL="$CTL" HOME="$HOME" -- --stats 2>/dev/null )"
check "... and the WARN is not on stdout (a parser of the table never sees it)" "$( ! printf '%s\n' "$so" | grep -q '^WARN'; echo $? )" "stdout=$so"

# Negative control on the cap: refusals take no slot. 19 spend rows today +
# agy quota -> grok still runs; then the 20th spend row closes the day.
scenario t127_cap; set_mode agy quota; mkdir -p "$REPO/.agents/runtime"
{ printf '# date\thelper\tmode\tinput\toutput\tcost\tanswer\toutcome\n'; i=0; while [ "$i" -lt 19 ]; do i=$((i + 1)); printf '%s 10:%02d\tagy\tconsult\t1\t1\t-\tx\tOK\n' "$(date +%Y-%m-%d)" "$i"; done; } > "$REPO/.agents/runtime/council-ledger.tsv"
run 20 "$MP" consult -q ping
check "19 spend rows + agy quota -> grok still asked (the refusal row is not a slot): chain: agy:QUOTA grok:OK" "$(if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | tail -1)" = "chain: agy:QUOTA grok:OK" ] && [ "$(spend_rows)" = 20 ] && [ "$(ledger_rows)" = 21 ]; then echo 0; else echo 1; fi)" "rc=$rc out=$out spend=$(spend_rows) rows=$(ledger_rows)"
run 20 "$MP" consult -q ping
check "20 spend rows -> FAIL: daily cap reached (20/20), nothing asked" "$(if [ "$rc" = 1 ] && [ "$(first_line)" = "FAIL: daily cap reached (20/20)" ]; then echo 0; else echo 1; fi)" "out=$out"

# The quota / login patterns are twins of codex-review.sh's (T-127): both
# files must carry byte-identical QUOTA_RE= and LOGIN_RE= lines.
REAL_CR="$TESTS_DIR/../codex-review.sh"
for v in QUOTA_RE LOGIN_RE; do
  a="$(grep -m1 "^$v=" "$REAL_SUT")"; b="$(grep -m1 "^$v=" "$REAL_CR")"
  check "twin: $v= identical in council.sh and codex-review.sh (and present in both)" "$( [ -n "$a" ] && [ "$a" = "$b" ] && echo 0 || echo 1 )" "council: $a
codex-review: $b"
done

# ===========================================================================
group "T-170: run / ask / check — fresh-context agents as CLI processes"
# ===========================================================================
# v3_scenario <name> [delegate] — scenario + a committed ticket with an id:
# line and a «Результат» section followed by another one; council.json with
# delegate as given (default true). Sets $TICKET, $PREPO (physical repo
# path, as git prints it) and $V3WT (the default executor worktree).
v3_scenario() {
  scenario "$1"
  mkdir -p "$REPO/.agents/runtime/tasks"
  printf -- '---\nid: T-900\ntitle: "drill ticket"\nstatus: review\n---\n\n## Задача\n\nadd helper-work.txt\n\n## Критерии приёмки\n\n- [ ] it exists\n\n## Результат (заполняет исполнитель)\n\nprior notes\n\n## Ограничения\n\nnone\n' > "$REPO/.agents/runtime/tasks/T-900-v3.md"
  printf 'project rules marker: RULE-X\n' > "$REPO/AGENTS.md"
  printf '{"enabled": true, "backends": ["agy","grok","codex"], "daily_cap": 20, "delegate": %s}' "${2:-true}" > "$REPO/.agents/council.json"
  ( cd "$REPO" && PATH="$FULL_PATH" git add -A && PATH="$FULL_PATH" git commit -qm 'ticket' )
  TICKET="$REPO/.agents/runtime/tasks/T-900-v3.md"
  PREPO="$(cd "$REPO" && pwd -P)"; V3WT="$PREPO/.claude/worktrees/t-900"
}
# section_of <heading prefix> — the ticket's lines from that "## " heading up to the next one.
section_of() { awk -v h="## $1" 'index($0, h) == 1 { on = 1; print; next } on && /^## / { exit } on { print }' "$TICKET"; }
roles() { # roles <role> <pa> <pm> <fa> <fm> [extra json] — council.json with one role
  printf '{"enabled": true, "backends": ["agy","grok","codex"], "daily_cap": 20, "delegate": true, "roles": {"%s": {"primary": {"agent": "%s", "model": "%s"}, "fallback": {"agent": "%s", "model": "%s"}}}%s}' "$1" "$2" "$3" "$4" "$5" "${6:-}" > "$REPO/.agents/council.json"
}

# --- run --role executor: the write path, guarded like delegate --------------
v3_scenario del_v3_off false; set_mode codex commit
run 20 "$MP" run --role executor --agent codex --model gpt-x --task "$TICKET"
check "v3-run: executor without \"delegate\": true -> FAIL: delegate disabled by project; no CLI started, no worktree, no ledger row" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: delegate disabled by project' && [ -z "$(calls)" ] && [ ! -e "$V3WT" ] && [ "$(ledger_rows)" = 0 ]; echo $? )" "rc=$rc out=$out calls=$(calls)"

v3_scenario del_v3_codex; set_mode codex dirty
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --agent codex --model gpt-x --task "$TICKET"
check "v3-run: executor codex -> OK: codex <report -run-executor-codex-T-900.md>, rc 0" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: codex .*/\.agents/runtime/council/.*-run-executor-codex-T-900\.md$'; echo $? )" "rc=$rc out=$out"
check "v3-run: worktree <repo>/.claude/worktrees/t-900 created on branch t-900 from HEAD; the LAUNCHER's commit «T-900: drill ticket (council run codex/gpt-x)» is there" "$( [ "$( cd "$V3WT" && PATH="$FULL_PATH" git rev-parse --abbrev-ref HEAD )" = t-900 ] && ( cd "$V3WT" && PATH="$FULL_PATH" git log --oneline "$base..HEAD" ) | grep -q 'T-900: drill ticket (council run codex/gpt-x)$' && [ "$(cat "$CTL/codex.cwd")" = "$V3WT" ]; echo $? )" "cwd=$(cat "$CTL/codex.cwd" 2>&1)"
check "v3-run: codex executor argv = workspace-write in -C <worktree>, network off, --model gpt-x, prompt on stdin, no bypass flag" "$( a="$CTL/codex.args"; grep -qx -- 'workspace-write' "$a" && grep -A1 -x -- '-C' "$a" | tail -1 | grep -qx -- "$V3WT" && grep -qx 'sandbox_workspace_write.network_access=false' "$a" && grep -A1 -x -- '--model' "$a" | tail -1 | grep -qx 'gpt-x' && [ "$(tail -1 "$a")" = "-" ] && [ ! -f "$CTL/codex.forbidden" ] && grep -q 'pf-do contract' "$CTL/codex.prompt" && grep -q 'RULE-X' "$CTL/codex.prompt"; echo $? )" "args=$(tr '\n' ' ' < "$CTL/codex.args")"
check "v3-run: the LAUNCHER wrote the outcome into «Результат» (before the next section), the message quoted; stdout says so" "$( sec="$(section_of 'Результат')"; printf '%s\n' "$sec" | grep -q '^prior notes$' && printf '%s\n' "$sec" | grep -q '^### council run · executor · codex/gpt-x · ' && printf '%s\n' "$sec" | grep -q '^> pong (codex)$' && printf '%s\n' "$sec" | grep -q '^- OK: codex ' && [ "$(grep -c '^## Ограничения' "$TICKET")" = 1 ] && printf '%s\n' "$out" | grep -q "^packet: «Результат» updated in $TICKET\$"; echo $? )" "$(cat "$TICKET")"
check "v3-run: main tree untouched by the helper (only the launcher's ticket write); stdout ≤ 15 lines" "$(if [ ! -e "$REPO/helper-work.txt" ] && [ -z "$( cd "$REPO" && PATH="$FULL_PATH" git status --porcelain | grep -v -e '\.agents/runtime/council' -e '\.claude/' -e 'T-900-v3\.md' )" ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -le 15 ]; then echo 0; else echo 1; fi)" "$( cd "$REPO" && PATH="$FULL_PATH" git status --porcelain )"
check "v3-run: ledger row mode run-executor, outcome OK" "$( tail -1 "$REPO/.agents/runtime/council-ledger.tsv" | grep -q '	codex	run-executor	303	11	-	.*	OK$'; echo $? )" "$(tail -1 "$REPO/.agents/runtime/council-ledger.tsv")"
rm -f "$CTL/calls"; printf 'wip\n' > "$V3WT/wip.txt"
run 20 "$MP" run --role executor --agent codex --task "$TICKET"
check "v3-run: existing executor worktree with an uncommitted file -> FAIL: worktree dirty, nothing started" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: worktree dirty' && [ -z "$(calls)" ]; echo $? )" "out=$out"
rm -f "$V3WT/wip.txt"

v3_scenario del_v3_claude; set_mode claude dirty; chmod 600 "$TICKET"
EXTRA_ENV="CLAUDECODE=1"
run 30 "$MP" run --role executor --agent claude --model sonnet --task "$TICKET"
EXTRA_ENV=""
check "v3-run: executor claude -> OK; claude -p in the worktree, acceptEdits + --permission-prompts none + allowlist, --model sonnet, no bypass, CLAUDECODE unset for the child" "$( a="$CTL/claude.args"; [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: claude ' && [ "$(cat "$CTL/claude.cwd")" = "$V3WT" ] && grep -qx -- '-p' "$a" && grep -A1 -x -- '--permission-mode' "$a" | tail -1 | grep -qx acceptEdits && grep -A1 -x -- '--permission-prompts' "$a" | tail -1 | grep -qx none && grep -qx 'Bash(git commit:\*)' "$a" && grep -qx 'Bash(cd:\*)' "$a" && grep -A1 -x -- '--model' "$a" | tail -1 | grep -qx sonnet && [ ! -f "$CTL/claude.forbidden" ] && [ ! -f "$CTL/claude.claudecode" ] && grep -q 'pf-do contract' "$CTL/claude.prompt"; echo $? )" "rc=$rc out=$out args=$(tr '\n' ' ' < "$CTL/claude.args" 2>&1)"
check "v3-run: claude runs without a session file (--no-session-persistence); the ticket keeps its file mode after the launcher's write" "$(if grep -qx -- '--no-session-persistence' "$CTL/claude.args" && [ "$(ls -l "$TICKET" | cut -c1-10)" = "-rw-------" ] && ! ls "$(dirname "$TICKET")"/*council* >/dev/null 2>&1; then echo 0; else echo 1; fi)" "mode=$(ls -l "$TICKET")"
check "v3-run: a '## Результат' line in the agent's message is quoted (> ## …), it opens no section of the ticket" "$( [ "$(grep -c '^## Результат' "$TICKET")" = 1 ] && grep -q '^> ## Результат$' "$TICKET"; echo $? )" "$(cat "$TICKET")"

v3_scenario del_v3_outside; set_mode codex outside
printf '%s' "$REPO/leaked.txt" > "$CTL/outside.path"
roles executor codex m1 claude m2
run 30 "$MP" run --role executor --task "$TICKET"
check "v3-run: executor writes into the main tree -> FAIL: codex touched files outside worktree; no fallback once the tree moved" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: codex touched files outside worktree (1 path(s): ?? leaked.txt' && [ "$(calls)" = codex ]; echo $? )" "rc=$rc out=$out calls=$(calls)"
rm -f "$REPO/leaked.txt"

v3_scenario del_v3_inside
run 20 "$MP" run --role executor --agent codex --task "$TICKET" --worktree "$REPO/sub/wt"
check "v3-run: --worktree inside the repo but not a direct child of .claude/worktrees -> FAIL before anything runs" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --worktree must be a direct child of' && [ -z "$(calls)" ] && [ ! -e "$REPO/sub" ]; echo $? )" "out=$out"
run 20 "$MP" run --role executor --agent codex --task "$TICKET" --worktree "$REPO/.claude/worktrees/../../x"
check "v3-run: a '..' in --worktree -> FAIL (no lexical escape)" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --worktree must be a plain path' && [ -z "$(calls)" ]; echo $? )" "out=$out"

# --- run --role reviewer: read-only, watched ----------------------------------
v3_scenario v3_rev
( cd "$REPO" && PATH="$FULL_PATH" git worktree add -q "$V3WT" -b t-900 2>/dev/null || { mkdir -p "$REPO/.claude/worktrees" && PATH="$FULL_PATH" git worktree add -q "$V3WT" -b t-900; } )
run 30 "$MP" run --agent claude --model opus --task "$TICKET"
check "v3-run: no --role = reviewer: claude -p --permission-mode plan in the worktree, OK, rc 0" "$( a="$CTL/claude.args"; [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: claude .*-run-reviewer-claude-T-900\.md$' && grep -A1 -x -- '--permission-mode' "$a" | tail -1 | grep -qx plan && ! grep -q 'acceptEdits' "$a" && [ "$(cat "$CTL/claude.cwd")" = "$V3WT" ] && grep -q 'READ-ONLY' "$CTL/claude.prompt" && grep -q 'Критерии приёмки' "$CTL/claude.prompt"; echo $? )" "rc=$rc out=$out"
check "v3-run: reviewer outcome lands in a NEW «Ревью» section at the end; «Результат» untouched" "$( sec="$(section_of 'Ревью')"; printf '%s\n' "$sec" | grep -q '^### council run · reviewer · claude/opus · ' && printf '%s\n' "$sec" | grep -q '^> pong (claude)$' && [ "$(tail -1 "$TICKET")" = '> fake done' ] && ! section_of 'Результат' | grep -q 'council run' && printf '%s\n' "$out" | grep -q '^packet: «Ревью» updated in'; echo $? )" "$(cat "$TICKET")"
set_mode claude dirty
run 30 "$MP" run --agent claude --task "$TICKET"
check "v3-run: a reviewer that writes a file in the worktree -> FAIL: claude wrote files as a read-only reviewer, rc 1" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: claude wrote files as a read-only reviewer (1 path(s): worktree: ?? helper-work.txt'; echo $? )" "rc=$rc out=$out"
rm -f "$V3WT/helper-work.txt"; rm -f "$CTL/claude.mode"
run 20 "$MP" run --agent codex --model gpt-r --task "$TICKET"
check "v3-run: reviewer codex runs --sandbox read-only, never workspace-write" "$( a="$CTL/codex.args"; [ "$rc" = 0 ] && grep -A1 -x -- '--sandbox' "$a" | tail -1 | grep -qx read-only && ! grep -q workspace-write "$a" && grep -A1 -x -- '--model' "$a" | tail -1 | grep -qx gpt-r; echo $? )" "rc=$rc out=$out args=$(tr '\n' ' ' < "$CTL/codex.args")"
run 20 "$MP" run --agent codex --task "$TICKET" --worktree "$REPO/.claude/worktrees/nope"
check "v3-run: reviewer with a --worktree that does not exist -> FAIL (a reviewer never creates one)" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --worktree does not exist' && [ ! -e "$REPO/.claude/worktrees/nope" ]; echo $? )" "out=$out"

# --- --dry-run and --async --------------------------------------------------
v3_scenario del_v3_dry
run 20 "$MP" run --role executor --agent codex --model gpt-x --task "$TICKET" --dry-run
check "v3-run: --dry-run prints 'DRY-RUN: cd <worktree> && codex exec … workspace-write …' and (T-187) 'secret scan: <scanner>' — two lines; starts nothing, creates no worktree, no ledger" "$( [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ] && printf '%s\n' "$out" | sed -n 1p | grep -q "^DRY-RUN: cd $V3WT && codex exec .*--sandbox workspace-write .*--model gpt-x -\$" && printf '%s\n' "$out" | sed -n 2p | grep -qxF "secret scan: $PF_SECRET_SCAN" && [ -z "$(calls)" ] && [ ! -e "$REPO/.claude" ] && [ ! -e "$REPO/.agents/runtime/council-ledger.tsv" ]; echo $? )" "rc=$rc out=$out"
run 20 "$MP" run --agent agy --model g --task "$TICKET" --dry-run
check "v3-run: --dry-run shows agy's argv-borne prompt by its size, never its text" "$( [ "$rc" = 0 ] && printf '%s' "$out" | grep -q -- '--print=<prompt: [0-9]* bytes> --mode plan --sandbox --model g --output-format json$' && ! printf '%s' "$out" | grep -q 'RULE-X'; echo $? )" "out=$out"
run 20 "$MP" run --role executor --agent codex --task "$TICKET" --dry-run --async
check "v3-run: --dry-run with --async -> FAIL" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --dry-run starts nothing'; echo $? )" "out=$out"
run 20 "$MP" consult -q ping --agent codex
check "v3-run: --agent outside run / ask -> FAIL" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --agent, --model, --role and --dry-run belong to run / ask'; echo $? )" "out=$out"
run 20 "$MP" run --role boss --agent codex --task "$TICKET"
check "v3-run: --role other than executor|reviewer -> FAIL" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q "^FAIL: --role takes executor or reviewer"; echo $? )" "out=$out"
set_mode grok dirty
run 20 "$MP" run --role executor --agent grok --model gk --task "$TICKET" --async
marker="${out#PENDING: }"
run 40 "$MP" --wait "$marker" --timeout 30
check "v3-run: executor --async -> PENDING, --wait shows OK: grok and the packet line (agent/model/role survive the relaunch)" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: grok .*-run-executor-grok-T-900\.md$' && printf '%s\n' "$out" | grep -q '^packet: «Результат» updated' && grep -A1 -x -- '--model' "$CTL/grok.args" | tail -1 | grep -qx gk && [ -f "$V3WT/helper-work.txt" ]; echo $? )" "rc=$rc out=$out"
check "t171: --wait passes the launcher's 'commit: <sha> T-900: …' line through (async executor)" "$( printf '%s\n' "$out" | grep -q '^commit: [0-9a-f]* T-900: drill ticket (council run grok/gk)$'; echo $? )" "out=$out"

# --- ask --------------------------------------------------------------------
v3_scenario v3_ask
printf 'Which option, A or B?\n' > "$REPO/q.md"
run 20 "$MP" ask --agent grok --model g1 -f q.md
check "v3-ask: ask grok -f -> OK line, then the answer text on stdout; read-only plan mode, --model g1" "$( a="$CTL/grok.args"; [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: grok .*-ask-grok-1\.md$' && printf '%s\n' "$out" | grep -qx 'pong (grok)' && grep -A1 -x -- '--permission-mode' "$a" | tail -1 | grep -qx plan && grep -A1 -x -- '--model' "$a" | tail -1 | grep -qx g1 && grep -q 'Which option, A or B?' "$CTL/grok.prompt" && grep -q 'do not create, edit' "$CTL/grok.prompt"; echo $? )" "rc=$rc out=$out"
check "v3-ask: ledger row mode ask" "$( tail -1 "$REPO/.agents/runtime/council-ledger.tsv" | grep -q '	grok	ask	202	9	0.0123	.*	OK$'; echo $? )" "$(tail -1 "$REPO/.agents/runtime/council-ledger.tsv")"
run 20 "$MP" ask --agent grok -q "async?" --async
marker="${out#PENDING: }"
run 40 "$MP" --wait "$marker" --timeout 30
check "v3-ask: ask --async -> --wait prints the OK line AND the answer text (the answer is the deliverable)" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: grok ' && printf '%s\n' "$out" | grep -qx 'pong (grok)' && ! printf '%s\n' "$out" | grep -q '^# '; echo $? )" "rc=$rc out=$out"
run 20 "$MP" ask --agent claude -q "is 2+2 four?"
check "v3-ask: ask claude -q -> claude -p --permission-mode plan, answer on stdout" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx 'pong (claude)' && grep -A1 -x -- '--permission-mode' "$CTL/claude.args" | tail -1 | grep -qx plan; echo $? )" "rc=$rc out=$out"
rm -f "$REPO/.agents/codex-review.json"; rm -f "$CTL/calls"
run 20 "$MP" ask --agent codex -q "ping"
check "v3-ask: ask codex without codex-review.json -> SKIP: codex not consented, rc 1, codex never started" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^SKIP: codex not consented' && [ -z "$(calls)" ]; echo $? )" "out=$out"
run 20 "$MP" ask -q "ping"
check "v3-ask: no --agent and no roles in council.json -> FAIL: ask needs --agent" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: ask needs --agent'; echo $? )" "out=$out"
run 20 "$MP" ask --agent gemini -q "ping"
check "v3-ask: unknown --agent -> FAIL before anything runs" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q "^FAIL: --agent takes claude, codex, agy or grok, got 'gemini'"; echo $? )" "out=$out"

# --- check --------------------------------------------------------------------
MP_CHK="$WORKROOT/minpath-check"; mkdir -p "$MP_CHK"
for f in "$MP"/*; do case "$(basename "$f")" in agy|grok) : ;; *) ln -sf "$(readlink "$f")" "$MP_CHK/$(basename "$f")" ;; esac; done
v3_scenario v3_check
run 30 "$MP_CHK" check
check "v3-check: agy and grok off PATH -> 'недоступен: agy (нет в PATH)', '… grok …'; claude and codex 'доступен:'; 4 lines, rc 0" "$( [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 4 ] && printf '%s\n' "$out" | grep -qx 'недоступен: agy (нет в PATH)' && printf '%s\n' "$out" | grep -qx 'недоступен: grok (нет в PATH)' && printf '%s\n' "$out" | grep -qx 'доступен: claude (claude 9.9.9 (fake))' && printf '%s\n' "$out" | grep -qx 'доступен: codex (codex 9.9.9 (fake))'; echo $? )" "rc=$rc out=$out"
check "v3-check: council.json gains available {claude:true, codex:true, agy:false, grok:false, checked}, the rest kept" "$( c="$REPO/.agents/council.json"; [ "$(PATH="$FULL_PATH" jq -c '[.available.claude, .available.codex, .available.agy, .available.grok, (.available.checked | test("^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$")), .enabled, .delegate, .daily_cap]' "$c")" = '[true,true,false,false,true,true,true,20]' ] && echo 0 || echo 1 )" "$(cat "$REPO/.agents/council.json")"
check "v3-check: only free probes ran (--version, codex login status) — no model call" "$( [ -z "$(calls)" ] && grep -qx 'codex login status' "$CTL/probes" && grep -qx 'claude --version' "$CTL/probes"; echo $? )" "calls=$(calls) probes=$(tr '\n' ';' < "$CTL/probes" 2>&1)"
printf 'loggedout' > "$CTL/codex.check"; printf 'vfail' > "$CTL/claude.check"
run 30 "$MP_CHK" check
check "v3-check: codex logged out -> 'недоступен: codex (не залогинен: …)'; a failing --version -> 'недоступен: claude (--version: rc 3 …)'; rc 0" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '^недоступен: codex (не залогинен: rc 1 — Not logged in)$' && printf '%s\n' "$out" | grep -q '^недоступен: claude (--version: rc 3 — claude: broken install)$' && [ "$(PATH="$FULL_PATH" jq -c '[.available.claude, .available.codex]' "$REPO/.agents/council.json")" = '[false,false]' ]; echo $? )" "rc=$rc out=$out"
rm -f "$CTL/codex.check" "$CTL/claude.check" "$REPO/.agents/codex-review.json"
run 30 "$MP_CHK" check
check "v3-check: codex without its consent -> 'недоступен: codex (нет согласия: …)'" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '^недоступен: codex (нет согласия: .agents/codex-review.json'; echo $? )" "out=$out"
rm -f "$REPO/.agents/council.json"
run 30 "$MP_CHK" check
check "v3-check: no council.json -> still 4 agent lines + a NOTE, rc 0, no file created (check needs no consent)" "$( [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | grep -c '^\(не\)\{0,1\}доступен: ')" = 4 ] && printf '%s\n' "$out" | grep -q '^NOTE: no .agents/council.json' && [ ! -e "$REPO/.agents/council.json" ]; echo $? )" "out=$out"
printf '{broken' > "$REPO/.agents/council.json"
run 30 "$MP_CHK" check
check "v3-check: council.json not valid JSON -> NOTE: availability NOT saved, file left as it was, rc 0" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '^NOTE: availability NOT saved' && [ "$(cat "$REPO/.agents/council.json")" = '{broken' ]; echo $? )" "out=$out"


# --- fix-round 1: model names, --dry-run honesty, check through a symlink ----
v3_scenario v3_model
rm -f "$CTL/calls"
run 20 "$MP" run --agent claude --model --dangerously-skip-permissions --task "$TICKET"
check "v3-run: --model starting with '-' (--dangerously-skip-permissions) -> FAIL: model names …, no CLI started" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q "^FAIL: model names are .* got '--dangerously-skip-permissions'" && [ -z "$(calls)" ] && [ ! -f "$CTL/claude.forbidden" ]; echo $? )" "rc=$rc out=$out calls=$(calls)"
run 20 "$MP" run --agent claude --model --dangerously-skip-permissions --task "$TICKET" --dry-run
check "v3-run: … and in --dry-run too: FAIL, no DRY-RUN line carrying the flag" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: model names are' && ! printf '%s' "$out" | grep -q '^DRY-RUN'; echo $? )" "rc=$rc out=$out"
roles reviewer codex '-c' grok g2
run 20 "$MP" run --task "$TICKET"
check "v3-run: a roles primary model '-c' -> FAIL before anything runs" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q "^FAIL: model names are .* got '-c'" && [ -z "$(calls)" ]; echo $? )" "rc=$rc out=$out"
roles reviewer codex c1 grok 'g 2'
run 20 "$MP" run --task "$TICKET"
check "v3-run: a roles fallback model with a space -> FAIL before anything runs" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q "^FAIL: model names are .* got 'g 2'" && [ -z "$(calls)" ]; echo $? )" "rc=$rc out=$out"

v3_scenario v3_dryhonest
roles reviewer codex_review x codex_delegate y
rm -f "$CTL/calls"
run 20 "$MP" run --task "$TICKET" --dry-run
check "v3-run: --dry-run whose roles name no real agent (codex_review, codex_delegate) -> SKIP ×2 + NOTE, rc 1; codex-review.sh never started, no command shown" "$( [ "$rc" = 1 ] && [ "$(printf '%s\n' "$out" | grep -c '^SKIP: codex_.* unknown agent')" = 2 ] && printf '%s\n' "$out" | grep -q '^NOTE: no candidate is usable here' && [ -z "$(calls)" ] && [ ! -f "$CTL/codex-review.args" ] && ! printf '%s' "$out" | grep -q 'DRY-RUN\|workspace-write'; echo $? )" "rc=$rc out=$out calls=$(calls)"
roles reviewer grok g1 grok g1
run 20 "$MP" run --task "$TICKET" --dry-run
check "v3-run: reviewer --dry-run without a worktree shows the directory a real run uses: cd <repo>" "$( [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "^DRY-RUN: cd $PREPO && grok --prompt-file .* --cwd $PREPO " ; echo $? )" "rc=$rc out=$out"
run 20 "$MP" run --task "$TICKET" --worktree "$REPO/.claude/worktrees/nope" --dry-run
check "v3-run: reviewer --dry-run with a --worktree that does not exist -> FAIL, rc 1 (as the real run)" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --worktree does not exist' && [ ! -e "$REPO/.claude" ]; echo $? )" "rc=$rc out=$out"

v3_scenario v3_checklink
OUTSIDE_JSON="$WORKROOT/user-settings.json"; printf '{"user": "keep me"}\n' > "$OUTSIDE_JSON"; cp "$OUTSIDE_JSON" "$WORKROOT/user-settings.orig"
mv "$REPO/.agents/council.json" "$REPO/.agents/council.real.json"
ln -s "$OUTSIDE_JSON" "$REPO/.agents/council.json"
run 30 "$MP_CHK" check
check "v3-check: council.json symlinked OUTSIDE the project -> the target is byte-for-byte unchanged, the link stays, NOTE on stderr, report printed, rc 0" "$(if [ "$rc" = 0 ] && cmp -s "$OUTSIDE_JSON" "$WORKROOT/user-settings.orig" && [ -L "$REPO/.agents/council.json" ] && printf '%s\n' "$out" | grep -q '^NOTE: .agents/council.json is a symlink — availability not saved' && [ "$(printf '%s\n' "$out" | grep -c '^\(не\)\{0,1\}доступен: ')" = 4 ]; then echo 0; else echo 1; fi)" "rc=$rc out=$out target=$(cat "$OUTSIDE_JSON")"
err="$( cd "$REPO" && sut_run 30 "$MP_CHK" STUB_CTL="$CTL" HOME="$HOME" -- check 2>&1 >/dev/null )"
check "v3-check: … the NOTE goes to stderr, not stdout" "$(if printf '%s\n' "$err" | grep -q '^NOTE: .agents/council.json is a symlink'; then echo 0; else echo 1; fi)" "stderr=$err"
rm -f "$REPO/.agents/council.json"; mkdir -p "$REPO/shared"; mv "$REPO/.agents/council.real.json" "$REPO/shared/council.json"
cp "$REPO/shared/council.json" "$WORKROOT/inner.orig"
( cd "$REPO/.agents" && ln -s ../shared/council.json council.json )
run 30 "$MP_CHK" check
check "v3-check: council.json symlinked INSIDE the project -> not written either (target unchanged, link kept), rc 0" "$(if [ "$rc" = 0 ] && cmp -s "$REPO/shared/council.json" "$WORKROOT/inner.orig" && [ -L "$REPO/.agents/council.json" ] && printf '%s\n' "$out" | grep -q '^NOTE: .agents/council.json is a symlink'; then echo 0; else echo 1; fi)" "rc=$rc out=$out"
rm -f "$REPO/.agents/council.json"; cp "$REPO/shared/council.json" "$REPO/.agents/council.json"; chmod 600 "$REPO/.agents/council.json"
run 30 "$MP_CHK" check
check "v3-check: a plain council.json IS written (available present) and keeps its mode (600)" "$(if [ "$rc" = 0 ] && [ "$(PATH="$FULL_PATH" jq -c '.available.claude' "$REPO/.agents/council.json")" = true ] && [ "$(ls -l "$REPO/.agents/council.json" | cut -c1-10)" = "-rw-------" ] && [ ! -L "$REPO/.agents/council.json" ]; then echo 0; else echo 1; fi)" "$(ls -l "$REPO/.agents/council.json")"

# --- fallback: roles.<role>.fallback ----------------------------------------
v3_scenario del_v3_fb_model; set_mode codex badmodel; set_mode claude dirty
roles executor codex gpt-bad claude sonnet
run 30 "$MP" run --role executor --task "$TICKET"
check "v3-fallback: primary model unknown to the CLI -> FAIL: codex unknown model, 'запасная: claude/sonnet (codex/gpt-bad: …)', OK: claude" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex unknown model (' && printf '%s\n' "$out" | sed -n 2p | grep -q '^запасная: claude/sonnet (codex/gpt-bad: unknown model' && printf '%s\n' "$out" | sed -n 3p | grep -q '^OK: claude ' && [ "$(calls)" = "codex claude" ] && printf '%s\n' "$out" | grep -qx 'chain: codex:MODEL claude:OK'; echo $? )" "rc=$rc out=$out calls=$(calls)"
check "v3-fallback: the packet names the agent that did the work (claude/sonnet); the fallback worked in the same worktree" "$( section_of 'Результат' | grep -q '^### council run · executor · claude/sonnet · ' && [ "$(cat "$CTL/claude.cwd")" = "$V3WT" ] && grep -A1 -x -- '--model' "$CTL/codex.args" | tail -1 | grep -qx gpt-bad; echo $? )" "$(cat "$TICKET")"

v3_scenario v3_fb_avail
roles reviewer codex c1 grok g2 ', "available": {"codex": false, "claude": true, "agy": true, "grok": true, "checked": "2026-10-10 09:00"}'
run 30 "$MP" run --task "$TICKET"
check "v3-fallback: available.codex false (from check) -> SKIP codex, 'запасная: grok/g2 (…)', codex never started" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^SKIP: codex unavailable per council.json available (checked 2026-10-10 09:00)' && printf '%s\n' "$out" | sed -n 2p | grep -q '^запасная: grok/g2 (codex/c1: unavailable per council.json' && printf '%s\n' "$out" | sed -n 3p | grep -q '^OK: grok ' && [ "$(calls)" = grok ]; echo $? )" "rc=$rc out=$out calls=$(calls)"
run 20 "$MP" run --task "$TICKET" --dry-run
check "v3-fallback: --dry-run follows the same choice: SKIP codex, запасная: grok/g2, the grok DRY-RUN line" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | sed -n 2p | grep -q '^запасная: grok/g2' && printf '%s\n' "$out" | sed -n 3p | grep -q '^DRY-RUN: cd .* && grok --prompt-file .* --permission-mode plan .*--model g2 --output-format json$'; echo $? )" "out=$out"

v3_scenario v3_fb_path
roles reviewer agy a1 grok g2
run 30 "$MP_NO_AGY" run --task "$TICKET"
check "v3-fallback: primary not on PATH -> SKIP: agy not installed, запасная: grok/g2, OK: grok" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | sed -n 1p | grep -qx 'SKIP: agy not installed' && printf '%s\n' "$out" | sed -n 2p | grep -qx 'запасная: grok/g2 (agy/a1: not installed)' && printf '%s\n' "$out" | sed -n 3p | grep -q '^OK: grok '; echo $? )" "rc=$rc out=$out"
set_mode agy quota; rm -f "$CTL/calls"
run 30 "$MP" run --task "$TICKET"
check "v3-fallback: primary quota -> FAIL: agy quota, запасная: grok/g2, OK: grok" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: agy quota' && printf '%s\n' "$out" | sed -n 2p | grep -q '^запасная: grok/g2 (agy/a1: quota' && [ "$(calls)" = "agy grok" ]; echo $? )" "rc=$rc out=$out"
set_mode agy crash; rm -f "$CTL/calls"
run 30 "$MP" run --task "$TICKET"
check "v3-fallback: primary crashes (a real error, not a refusal) -> FAIL: agy error, NO fallback, rc 1" "$( [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: agy error' && [ "$(calls)" = agy ] && ! printf '%s\n' "$out" | grep -q '^запасная'; echo $? )" "rc=$rc out=$out"
rm -f "$CTL/agy.mode" "$CTL/calls"
run 30 "$MP" run --agent grok --model g9 --task "$TICKET"
check "v3-fallback: explicit --agent/--model is the primary (grok/g9); roles' primary is not asked" "$( [ "$rc" = 0 ] && printf '%s' "$(first_line)" | grep -q '^OK: grok ' && [ "$(calls)" = grok ] && grep -A1 -x -- '--model' "$CTL/grok.args" | tail -1 | grep -qx g9; echo $? )" "rc=$rc out=$out calls=$(calls)"

# ===========================================================================
group "read-only invariant and secrets"
# ===========================================================================
# Every bypass token must sit on a comment line of council.sh — never in a
# command. `workspace-write` (codex's edit sandbox) is allowed on exactly one
# command line: the codex delegate. Counted on the REAL file, not the copy.
bad="$(grep -nE 'dangerously-skip-permissions|always-approve|bypassPermissions|danger-full-access|dangerously-bypass' "$REAL_SUT" | grep -vE '^[0-9]+:[[:space:]]*#')"
check "no forbidden flag outside comment lines in council.sh" "$( [ -z "$bad" ] && echo 0 || echo 1 )" "$bad"
total="$(grep -cE 'dangerously-skip-permissions|always-approve|bypassPermissions|danger-full-access|dangerously-bypass' "$REAL_SUT")"
echo "      (forbidden tokens appear on $total comment line(s) of council.sh — the header's ban block)"
ww="$(grep -nE 'workspace-write' "$REAL_SUT" | grep -vE '^[0-9]+:[[:space:]]*#')"
check "workspace-write outside comments: exactly one line, and it is run_codex_delegate" "$( [ "$(printf '%s\n' "$ww" | grep -c .)" = 1 ] && printf '%s' "$ww" | grep -q '^[0-9]*:run_codex_delegate()'; echo $? )" "$ww"
check "no stub ever received a forbidden flag across the whole suite" "$( [ -z "$(ls "$WORKROOT"/ctl-*/*.forbidden 2>/dev/null)" ] && echo 0 || echo 1 )" "$(ls "$WORKROOT"/ctl-*/*.forbidden 2>/dev/null)"
# ===========================================================================
group "T-171: run --role executor — the LAUNCHER commits, never the agent"
# ===========================================================================
wt_log() { ( cd "$V3WT" && PATH="$FULL_PATH" git log --format=%s "$1..HEAD" ) 2>/dev/null; }

v3_scenario del_t171_commit; set_mode codex dirty
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
hd="$PREPO/.git/hooks"; mkdir -p "$hd"; printf '#!/bin/sh\n: > "%s/hook-ran"\n' "$CTL" > "$hd/pre-commit"; chmod +x "$hd/pre-commit"
run 30 "$MP" run --role executor --agent codex --model gpt-x --task "$TICKET"
check "t171: stub writes a file, no commit -> OK, ONE launcher commit with the T-id subject, worktree clean" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^OK: codex ' && [ "$(wt_log "$base")" = 'T-900: drill ticket (council run codex/gpt-x)' ] && [ -z "$( cd "$V3WT" && PATH="$FULL_PATH" git status --porcelain )" ]; echo $? )" "rc=$rc out=$out log=$(wt_log "$base")"
check "t171: stdout names the commit ('commit: <sha> T-900: …') and the packet block carries it" "$( sha="$( cd "$V3WT" && PATH="$FULL_PATH" git rev-parse --short HEAD )"; printf '%s\n' "$out" | grep -qx "commit: $sha T-900: drill ticket (council run codex/gpt-x)" && section_of 'Результат' | grep -q "^- commit: $sha "; echo $? )" "out=$out"
check "t171-r2: the launcher's secret scan ran before its commit" "$(if [ "$(grep -c . "$CTL/scan-calls" 2>/dev/null)" = 1 ]; then echo 0; else echo 1; fi)"
check "t171: the repository's own pre-commit hook did NOT run (core.hooksPath=/dev/null)" "$(if [ -e "$CTL/hook-ran" ]; then echo 1; else echo 0; fi)"
check "t171: the executor prompt says not to commit, and no longer tells it to commit" "$( grep -q 'Do NOT commit: the orchestrator commits your changes' "$CTL/codex.prompt" && ! grep -q 'Commit here:' "$CTL/codex.prompt"; echo $? )"

v3_scenario del_t171_none
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --agent codex --model gpt-x --task "$TICKET"
check "t171: stub writes nothing -> no commit, 'нет изменений', rc 1" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -qx 'нет изменений — коммита нет' && [ -z "$(wt_log "$base")" ]; echo $? )" "rc=$rc out=$out"

v3_scenario del_t171_cfg; set_mode codex gitconfig
roles executor codex m1 claude m2; set_mode claude dirty
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --task "$TICKET"
check "t171: stub changes .git/config -> FAIL: codex changed .git/config or .git/hooks, no commit, no fallback" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex changed git control files (.git/config, hooks, worktree pointers) or the scan.s ledger / .gitignore — nothing committed, no git run after the agent; do not run git in this repository until a human has checked them (.*/\.git/config[;)]' && [ -z "$(wt_log "$base")" ] && ! grep -q claude "$CTL/calls"; echo $? )" "rc=$rc out=$out calls=$(calls)"

v3_scenario del_t171_hook; set_mode codex hook
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --agent codex --task "$TICKET"
check "t171: stub plants .git/hooks/pre-commit -> FAIL, no commit, the hook never ran" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex changed git control files (.git/config, hooks, worktree pointers) or the scan.s ledger / .gitignore — nothing committed, no git run after the agent; do not run git in this repository until a human has checked them (.*/hooks/pre-commit[;)]' && [ -z "$(wt_log "$base")" ] && [ ! -e "$CTL/hook-ran" ]; echo $? )" "rc=$rc out=$out"

v3_scenario del_t171_self; set_mode codex commit
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --agent codex --task "$TICKET"
check "t171: an agent that commits by itself -> FAIL: codex committed by itself; the launcher adds nothing" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex committed by itself (1 commit(s) on t-900)' && [ "$(wt_log "$base")" = 'codex: helper-work.txt' ]; echo $? )" "rc=$rc out=$out"

v3_scenario del_t171_fb; set_mode codex badmodel; set_mode claude dirty
roles executor codex gpt-bad claude sonnet
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --task "$TICKET"
check "t171: fallback after an unknown model -> the launcher commits the fallback's work, subject names claude/sonnet" "$( [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '^запасная: claude/sonnet' && [ "$(wt_log "$base")" = 'T-900: drill ticket (council run claude/sonnet)' ]; echo $? )" "rc=$rc out=$out log=$(wt_log "$base")"

# --- fix round 2: secret scan, ledger, guard before any git ---------------
v3_scenario del_t171_secret; set_mode codex secret; roles executor codex m1 claude m2; set_mode claude dirty
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --task "$TICKET"
check "t171-r2: a secret in the agent's work -> FAIL: secret scan failed, no commit, index reset, no fallback, value not printed" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex secret scan failed — nothing committed (✗ секрет-скан НЕ пройден)' && [ -z "$(wt_log "$base")" ] && [ -z "$( cd "$V3WT" && PATH="$FULL_PATH" git diff --cached --name-only )" ] && [ -f "$V3WT/leaked.py" ] && [ "$(calls)" = codex ] && ! printf '%s' "$out" | grep -q 'aB3dE5gH7'; echo $? )" "rc=$rc out=$out calls=$(calls)"

v3_scenario del_t171_ledger; set_mode codex ledger; roles executor codex m1 claude m2; set_mode claude dirty
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --task "$TICKET"
check "t171-r2: the agent edits .agents/security/false-positives.yaml -> FAIL (guard), no commit, no fallback, scanner not even asked" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex changed git control files .*/\.agents/security/false-positives\.yaml' && [ -z "$(wt_log "$base")" ] && [ "$(calls)" = codex ] && [ ! -e "$CTL/scan-calls" ]; echo $? )" "rc=$rc out=$out"

v3_scenario del_t171_noscan; set_mode codex dirty
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
EXTRA_ENV="PF_SECRET_SCAN=$WORKROOT/no-such-scanner"
run 30 "$MP" run --role executor --agent codex --task "$TICKET"
EXTRA_ENV=""
check "t171-r2: no scanner at the resolved path -> FAIL: secret scan unavailable, no commit (never a quiet skip)" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex secret scan unavailable (.*/no-such-scanner)' && [ -z "$(wt_log "$base")" ]; echo $? )" "rc=$rc out=$out"

# --- T-187: the bundled scanner (pf-workflow ships it next to council.sh) ---
# Order: PF_SECRET_SCAN -> canon ${PF_TOOLS:-$HOME/ai/_tools}/security/
# repo-hooks/pre-commit -> <dir of council.sh>/secret-scan/repo-hooks/
# pre-commit -> FAIL. Each stand-in writes its own marker, so the test sees
# WHICH scanner ran, not just that one did. PF_SECRET_SCAN is emptied and
# PF_TOOLS pointed at a missing dir for the harness itself (sut_run inherits
# the environment), then restored.
BUNDLED="$SUTDIR/secret-scan/repo-hooks/pre-commit"
mkdir -p "$(dirname "$BUNDLED")"
printf '#!/usr/bin/env bash\necho bundled >> "${STUB_CTL:?}/bundled-scan-calls"\nexec "%s"\n' "$TESTS_DIR/fixtures/fake-secret-scan" > "$BUNDLED"; chmod +x "$BUNDLED"
FAKE_TOOLS="$WORKROOT/fake-tools"; mkdir -p "$FAKE_TOOLS/security/repo-hooks"
printf '#!/usr/bin/env bash\necho canon >> "${STUB_CTL:?}/canon-scan-calls"\nexec "%s"\n' "$TESTS_DIR/fixtures/fake-secret-scan" > "$FAKE_TOOLS/security/repo-hooks/pre-commit"; chmod +x "$FAKE_TOOLS/security/repo-hooks/pre-commit"
export PF_SECRET_SCAN="" PF_TOOLS="$WORKROOT/no-such-tools"

v3_scenario del_t187_bundled; set_mode codex dirty
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --agent codex --model gpt-x --task "$TICKET"
# three calls of the chosen scanner per run: the final message (Ж-6), the index, the ticket block (🟡-1)
check "t187: bundled scanner — no PF_SECRET_SCAN, PF_TOOLS on a missing dir -> the copy next to council.sh scans, the launcher commits" "$(if [ "$rc" = 0 ] && [ "$(grep -c . "$CTL/bundled-scan-calls" 2>/dev/null)" = 3 ] && [ "$(wt_log "$base")" = 'T-900: drill ticket (council run codex/gpt-x)' ]; then echo 0; else echo 1; fi)" "rc=$rc out=$out log=$(wt_log "$base")"

v3_scenario del_t187_bundled_dry
run 20 "$MP" run --role executor --agent codex --model gpt-x --task "$TICKET" --dry-run
check "t187: bundled scanner — --dry-run names the scanner a real run would use (the copy)" "$(if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx 'secret scan: .*/sut/secret-scan/repo-hooks/pre-commit' && [ ! -e "$CTL/bundled-scan-calls" ]; then echo 0; else echo 1; fi)" "rc=$rc out=$out"

v3_scenario del_t187_canon; set_mode codex dirty
PF_TOOLS="$FAKE_TOOLS"
run 30 "$MP" run --role executor --agent codex --model gpt-x --task "$TICKET"
PF_TOOLS="$WORKROOT/no-such-tools"
check "t187: bundled scanner — an executable canon scanner under PF_TOOLS goes first; the copy is not run" "$(if [ "$rc" = 0 ] && [ "$(grep -c . "$CTL/canon-scan-calls" 2>/dev/null)" = 3 ] && [ ! -e "$CTL/bundled-scan-calls" ]; then echo 0; else echo 1; fi)" "rc=$rc out=$out"

v3_scenario del_t187_explicit; set_mode codex dirty
PF_SECRET_SCAN="$TESTS_DIR/fixtures/fake-secret-scan"
run 30 "$MP" run --role executor --agent codex --model gpt-x --task "$TICKET"
PF_SECRET_SCAN=""
check "t187: bundled scanner — PF_SECRET_SCAN goes before the copy (and before the canon)" "$(if [ "$rc" = 0 ] && [ "$(grep -c . "$CTL/scan-calls" 2>/dev/null)" = 1 ] && [ ! -e "$CTL/bundled-scan-calls" ] && [ ! -e "$CTL/canon-scan-calls" ]; then echo 0; else echo 1; fi)" "rc=$rc out=$out"

rm -rf "$SUTDIR/secret-scan"
v3_scenario del_t187_none; set_mode codex dirty
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --agent codex --task "$TICKET"
check "t187: bundled scanner — none of the three -> the same FAIL: secret scan unavailable (names canon and copy), no commit" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex secret scan unavailable (.*/no-such-tools/security/repo-hooks/pre-commit or .*/sut/secret-scan/repo-hooks/pre-commit) — nothing committed' && [ -z "$(wt_log "$base")" ]; echo $? )" "rc=$rc out=$out"
export PF_SECRET_SCAN="$TESTS_DIR/fixtures/fake-secret-scan"; unset PF_TOOLS

v3_scenario del_t171_fsmon; set_mode codex fsmon
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --agent codex --task "$TICKET"
fsmon_runs="$(cat "$CTL/fsmon-ran" 2>/dev/null | grep -c . || true)"
check "t171-r2: core.fsmonitor planted -> FAIL before any git: the planted program never ran, no commit, packet says head not read" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex changed git control files (.git/config, hooks, worktree pointers) or the scan.s ledger / .gitignore' && [ "$fsmon_runs" = 0 ] && section_of 'Результат' | grep -q 'head not read (git guard tripped)'; echo $? )" "rc=$rc fsmon_runs=$fsmon_runs out=$out"
( cd "$REPO" && PATH="$FULL_PATH" git config --unset core.fsmonitor )
check "... and no launcher commit on the branch (checked by the harness after unsetting the planted key)" "$(if [ -z "$(wt_log "$base")" ]; then echo 0; else echo 1; fi)"

v3_scenario del_t171_pointer; set_mode codex pointer
run 30 "$MP" run --role executor --agent codex --task "$TICKET"
check "t171-r2: the worktree's .git pointer rewritten -> FAIL (guard), nothing committed" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q "^FAIL: codex changed git control files (.git/config, hooks, worktree pointers) or the scan.s ledger / .gitignore — nothing committed, .*($V3WT/\.git[;)]"; echo $? )" "rc=$rc out=$out"

# --- fix round 3: ignored ledger, commondir --------------------------------
v3_scenario del_t171_ignledger; set_mode codex ignledger
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --agent codex --task "$TICKET"
check "t171-r3: secret + ledger hidden by .gitignore -> FAIL (guard names the ledger), no commit, scanner not asked" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex changed git control files .*\.agents/security/false-positives\.yaml' && [ -z "$(wt_log "$base")" ] && [ ! -e "$CTL/scan-calls" ]; echo $? )" "rc=$rc out=$out log=$(wt_log "$base")"

v3_scenario del_t171_commondir; set_mode codex commondir
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --agent codex --task "$TICKET"
fsmon_runs="$(cat "$CTL/fsmon-ran" 2>/dev/null | grep -c . || true)"
check "t171-r3: .git/worktrees/<id>/commondir pointed at a fake git dir with core.fsmonitor -> FAIL, the planted program never ran" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex changed git control files .*/commondir' && [ "$fsmon_runs" = 0 ]; echo $? )" "rc=$rc fsmon_runs=$fsmon_runs out=$out"

# --- T-191 (QA 11.10): Ж-6 final message scanned, Ж-7 local excludes, Ж-8 PF_COUNCIL_RUN ---
tok_pfx="gh""p_"
v3_scenario del_t191_leak_exec; set_mode codex secret-answer
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --agent codex --model gpt-x --task "$TICKET"
check "t191 Ж-6: executor's FINAL MESSAGE holds a token -> FAIL, nothing committed, the work stays uncommitted, no fallback" "$(if [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex final message failed the secret scan — ответ не записан: секрет-скан нашёл совпадение; nothing committed' && [ -z "$(wt_log "$base")" ] && [ -n "$( cd "$V3WT" && PATH="$FULL_PATH" git status --porcelain )" ] && [ "$(calls)" = codex ] && [ ! -e "$CTL/scan-calls" ] && [ "$(grep -c . "$CTL/msgscan-calls")" = 2 ]; then echo 0; else echo 1; fi)" "rc=$rc out=$out"
check "t191 Ж-6: ... the ticket gets the line «ответ не записан: секрет-скан нашёл совпадение», never the token; the report keeps neither text nor raw output" "$( sec="$(section_of 'Результат')"; printf '%s\n' "$sec" | grep -qx '> ответ не записан: секрет-скан нашёл совпадение' && ! grep -q "$tok_pfx" "$TICKET" && ! grep -rq "$tok_pfx" "$REPO/.agents/runtime/council/"; echo $? )" "$(cat "$TICKET")"

v3_scenario t191_leak_rev; set_mode codex secret-answer-ro
run 30 "$MP" run --role reviewer --agent codex --model gpt-x --task "$TICKET"
check "t191 Ж-6: reviewer's final message holds a token -> FAIL, «Ревью» gets the line, the token is nowhere on disk in the project" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex final message failed the secret scan — ответ не записан: секрет-скан нашёл совпадение; the answer is not written' && section_of 'Ревью' | grep -qx '> ответ не записан: секрет-скан нашёл совпадение' && ! grep -rq "$tok_pfx" "$REPO" --exclude-dir=.git; echo $? )" "rc=$rc out=$out"

for r in executor reviewer; do
  sc="t191_errsec_$r"; [ "$r" = executor ] && sc="del_$sc"   # del_*: workspace-write is expected there
  v3_scenario "$sc"; set_mode codex err-secret
  run 30 "$MP" run --role "$r" --agent codex --model gpt-x --task "$TICKET"
  check "t191 🟡-1 / t193 gate: $r — the CLI's LAST error line holds a token (rc 2) -> FAIL; the state names rc and the raw file, not the CLI text: the token is not on stdout, not in the ticket, nowhere in the project" "$(if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q '^FAIL: codex error (rc=2; подробности: ' && ! printf '%s\n' "$out" | grep -q "$tok_pfx" && grep -q 'codex error (rc=2; подробности: ' "$TICKET" && ! grep -rq "$tok_pfx" "$REPO" --exclude-dir=.git --exclude-dir=council; then echo 0; else echo 1; fi)" "rc=$rc out=$out"
done
# The ticket block is still scanned: a state line that quotes agent-chosen
# PATHS (an executor writing outside its worktree, a file named like a token)
# -> only the neutral line goes in.
tok_full="$(printf '%s%s' "$tok_pfx" "aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bC1dE3fG5")"
v3_scenario del_t193_pktscan; set_mode codex outside
printf '%s' "$REPO/$tok_full.txt" > "$CTL/outside.path"
run 30 "$MP" run --role executor --agent codex --model gpt-x --task "$TICKET"
check "t191 🟡-1: a state line quoting a token-named path -> FAIL: the text for the ticket failed the secret scan, the ticket gets only the neutral line" "$(if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q '^FAIL: the text for the ticket failed the secret scan' && grep -q 'ответ не записан: секрет-скан нашёл совпадение — текст результата' "$TICKET" && ! grep -q "$tok_pfx" "$TICKET"; then echo 0; else echo 1; fi)" "rc=$rc out=$out"

v3_scenario t191_noscan_rev; set_mode codex ok
EXTRA_ENV="PF_SECRET_SCAN=$WORKROOT/no-such-scanner"
run 30 "$MP" run --role reviewer --agent codex --model gpt-x --task "$TICKET"
EXTRA_ENV=""
check "t191 Ж-6: no scanner for the reviewer's message -> FAIL (could not check is not clean), the text is not written, the line names gitleaks" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex final message could not be secret-scanned (scanner unavailable or gitleaks too old) — ответ не записан: секрет-скан не смог проверить ответ .* — нужен gitleaks ≥ 8.19 (команда `gitleaks git`): macOS — brew install gitleaks; Ubuntu/Debian — бинарник с GitHub Releases (apt даёт старую 8.16); the answer is not written' && ! section_of 'Ревью' | grep -q 'pong (codex)'; echo $? )" "rc=$rc out=$out"

v3_scenario t191_clean; set_mode codex dirty
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --agent codex --model gpt-x --task "$TICKET"
check "t191 Ж-7: after a run the main tree shows only the ticket edit — no ?? .claude/, ledger, council/ (local info/exclude)" "$(if [ "$rc" = 0 ] && [ "$( cd "$REPO" && PATH="$FULL_PATH" git status --porcelain )" = ' M .agents/runtime/tasks/T-900-v3.md' ]; then echo 0; else echo 1; fi)" "$( cd "$REPO" && PATH="$FULL_PATH" git status --porcelain )"
check "t191 Ж-7: the three lines are in .git/info/exclude once each, nothing committed to the project for it" "$(if ex="$REPO/.git/info/exclude"; [ "$(grep -cxF /.claude/worktrees/ "$ex")" = 1 ] && [ "$(grep -cxF /.agents/runtime/council-ledger.tsv "$ex")" = 1 ] && [ "$(grep -cxF /.agents/runtime/council/ "$ex")" = 1 ] && [ "$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )" = "$base" ] && [ ! -e "$REPO/.gitignore" ]; then echo 0; else echo 1; fi)" "$(grep -v '^#' "$REPO/.git/info/exclude")"
run 30 "$MP" run --role reviewer --agent codex --model gpt-x --task "$TICKET"
check "t191 Ж-7: a second run adds no duplicate lines" "$(if [ "$(grep -cxF /.claude/worktrees/ "$REPO/.git/info/exclude")" = 1 ]; then echo 0; else echo 1; fi)"

v3_scenario del_t191_exclude; set_mode codex exclude
base="$( cd "$REPO" && PATH="$FULL_PATH" git rev-parse HEAD )"
run 30 "$MP" run --role executor --agent codex --model gpt-x --task "$TICKET"
check "t191 Ж-7: the AGENT appends to .git/info/exclude -> the git guard trips (FAIL names info/exclude), nothing committed" "$(if [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex changed git control files .*info/exclude' && [ -z "$(wt_log "$base")" ]; then echo 0; else echo 1; fi)" "rc=$rc out=$out"

v3_scenario t191_dry; set_mode codex dirty
run 20 "$MP" run --role executor --agent codex --model gpt-x --task "$TICKET" --dry-run
check "t191 Ж-7: --dry-run writes nothing to .git/info/exclude" "$( ! grep -q council "$REPO/.git/info/exclude" 2>/dev/null; echo $? )"

v3_scenario t191_env; set_mode codex dirty
run 30 "$MP" run --role executor --agent codex --model gpt-x --task "$TICKET"
set_mode codex ok
run 30 "$MP" run --role reviewer --agent codex --model gpt-x --task "$TICKET"
run 20 "$MP" ask --agent codex -q "ping"
run 20 "$MP" consult -q "ping" --order grok
check "t191 Ж-8: PF_COUNCIL_RUN=1 reached the child CLI in run executor, run reviewer, ask (codex ×3) and consult (grok)" "$(if [ "$(sort -u "$CTL/codex.pfcr")" = 1 ] && [ "$(grep -c . "$CTL/codex.pfcr")" = 3 ] && [ "$(sort -u "$CTL/grok.pfcr")" = 1 ]; then echo 0; else echo 1; fi)" "codex=$(tr '\n' ' ' < "$CTL/codex.pfcr" 2>&1) grok=$(tr '\n' ' ' < "$CTL/grok.pfcr" 2>&1)"

# --- T-193 (QA 12.10): Н-2 audit journal scanned, Н-3 old gitleaks named, Н-5 exclude file -----
group "T-193 (QA 12.10): audit journal scanned, old gitleaks named, info/exclude kept intact"
del_scenario del_t193_audit_stdout; set_mode agy err-secret
run 30 "$MP" delegate --audit --project "$REPO" --ticket "$TICKET" --order agy
check "t193 gate: the token in the CLI's last error line is not on council.sh's stdout, nor in the journal (delegate --audit)" "$( [ "$rc" = 1 ] && ! printf '%s\n' "$out" | grep -q "$tok_pfx" && printf '%s\n' "$out" | grep -q '^FAIL: agy error (rc=2; подробности: .*/\.agents/runtime/council/.*-delegate-agy-T-900-drill\.md)$' && ! jgrep -q "$tok_pfx"; echo $? )" "rc=$rc out=$out"

tok_full="$(printf '%s%s' "$tok_pfx" "aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bC1dE3fG5")"
del_scenario del_t193_audit_leak; set_mode agy outside
printf '%s' "$REPO/$tok_full.txt" > "$CTL/outside.path"
run 30 "$MP" delegate --audit --project "$REPO" --ticket "$TICKET" --order agy
check "t193 Н-2: delegate --audit, the state quotes a token-named path the helper wrote outside -> FAIL names the journal, rc 1" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q '^FAIL: the journal entry failed the secret scan — only a neutral entry was written to '; echo $? )" "rc=$rc out=$out"
check "t193 Н-2: ... the journal holds only the neutral entry, no token in it" "$(if jgrep -qxF 'Итог: FAIL (текст записи не записан: секрет-скан нашёл совпадение); подробности — в отчёте помощника в .agents/runtime/council/.' && jgrep -q '^## [0-9][0-9]:[0-9][0-9] · council delegate --audit · agy$' && ! jgrep -q "$tok_pfx"; then echo 0; else echo 1; fi)" "$(journal)"

for m in consult run; do
  if [ "$m" = run ]; then v3_scenario "t193_stdout_$m"; set_mode codex err-secret; run 30 "$MP" run --role reviewer --agent codex --model gpt-x --task "$TICKET"
  else scenario "t193_stdout_$m"; set_mode agy err-secret; run 20 "$MP" consult -q ping --order agy; fi
  check "t193 gate: $m — the token in the CLI's last error line is not on stdout; the state names rc and the .raw file" "$( [ "$rc" = 1 ] && ! printf '%s\n' "$out" | grep -q "$tok_pfx" && printf '%s\n' "$out" | grep -q '^FAIL: [a-z]* error (rc=2; подробности: .*\.md\.raw)$'; echo $? )" "rc=$rc out=$out"
done

del_scenario del_t193_audit_clean; set_mode agy commit
run 30 "$MP" delegate --audit --project "$REPO" --ticket "$TICKET" --order agy
check "t193 Н-2: a clean audit still gets the full entry (Что/Итог: OK/Коммит), scanned once, rc 0" "$(if [ "$rc" = 0 ] && jgrep -q '^Итог: OK: agy ' && jgrep -q '^Коммит: delegate/T-900-drill-' && jgrep -q '^Что: аудит по пакету T-900-drill.md' && [ "$(grep -c . "$CTL/msgscan-calls" 2>/dev/null)" = 1 ]; then echo 0; else echo 1; fi)" "rc=$rc $(journal)"

MP_OLDGL="$WORKROOT/minpath-oldgl"; mkdir -p "$MP_OLDGL"
for f in "$MP"/*; do ln -sf "$(readlink "$f")" "$MP_OLDGL/$(basename "$f")"; done
printf '#!/bin/sh\n# gitleaks 8.16 stand-in: no `git` command\n[ "$1" = git ] && { echo "Error: unknown command \\"git\\" for \\"gitleaks\\"" >&2; exit 1; }\nexit 0\n' > "$MP_OLDGL/gitleaks"; chmod +x "$MP_OLDGL/gitleaks"
v3_scenario t193_oldgl; set_mode codex ok
EXTRA_ENV="PF_SECRET_SCAN=$WORKROOT/no-such-scanner"
run 30 "$MP_OLDGL" run --role reviewer --agent codex --model gpt-x --task "$TICKET"
EXTRA_ENV=""
check "t193 Н-3: gitleaks without the git command -> FAIL says the scan could not run and names gitleaks as too old (≥ 8.19, GitHub Releases), not «apt install gitleaks»" "$( [ "$rc" = 1 ] && printf '%s\n' "$out" | sed -n 1p | grep -q '^FAIL: codex final message could not be secret-scanned (scanner unavailable or gitleaks too old) — .*gitleaks на этой машине слишком старый — нет команды `gitleaks git`; нужен gitleaks ≥ 8.19' && ! printf '%s\n' "$out" | grep -q 'apt install gitleaks' && section_of 'Ревью' | grep -q 'слишком старый'; echo $? )" "rc=$rc out=$out"

scenario t193_exclude
ex="$REPO/.git/info/exclude"; printf '# my excludes\n*.log' > "$ex"; echo "secret debug" > "$REPO/debug.log"
ck0="$(cksum < "$ex")"
run 20 "$MP" ask -q hello
run2_rc=$rc
check "t193 Н-5: a refused call (ask without --agent) writes nothing to .git/info/exclude" "$(if [ "$run2_rc" = 1 ] && [ "$(cksum < "$ex")" = "$ck0" ]; then echo 0; else echo 1; fi)" "rc=$run2_rc $(cat -e "$ex")"
run 20 "$MP" ask --agent codex -q ping
check "t193 Н-5: the user's last line without a newline stays intact, our lines start on lines of their own, debug.log stays hidden" "$(if [ "$rc" = 0 ] && [ "$(grep -cxF '*.log' "$ex")" = 1 ] && [ "$(grep -cxF /.claude/worktrees/ "$ex")" = 1 ] && [ "$(grep -cxF /.agents/runtime/council/ "$ex")" = 1 ] && ! ( cd "$REPO" && PATH="$FULL_PATH" git status --porcelain -uall ) | grep -q -e debug.log -e 'runtime/council'; then echo 0; else echo 1; fi)" "rc=$rc $(cat -e "$ex") status=$( cd "$REPO" && PATH="$FULL_PATH" git status --porcelain )"

del_scenario del_t193_badwt
ex="$REPO/.git/info/exclude"; ck0="$(cksum < "$ex" 2>/dev/null)"
run 20 "$MP" delegate --ticket "$TICKET" --worktree "$REPO/inside-wt" --order agy
check "t193 Н-5: delegate with a --worktree inside the repo (refused after the mode checks) writes nothing to .git/info/exclude" "$(if [ "$rc" = 1 ] && printf '%s' "$(first_line)" | grep -q '^FAIL: --worktree must lie outside' && [ "$(cksum < "$ex" 2>/dev/null)" = "$ck0" ]; then echo 0; else echo 1; fi)" "rc=$rc out=$out"

check "codex sandbox is read-only in every non-delegate run and workspace-write in every delegate run" "$( bad=0; for a in "$WORKROOT"/ctl-*/codex.args; do want=read-only; printf '%s' "$a" | grep -q '/ctl-del_' && want=workspace-write; awk -v want="$want" 'p { if ($0 != want) bad = 1; p = 0 } $0 == "--sandbox" { p = 1 } END { exit bad }' "$a" || bad=1; done; echo $bad )"

scenario env
EXTRA_ENV="COUNCIL_TEST_CANARY=canary-value-COUNCIL-TEST"
run 10 "$MP" consult -q "what is 2+2" --order grok
check "env is not read into the prompt (a secret in the environment stays out)" "$( ! grep -q 'canary-value-COUNCIL-TEST' "$CTL/grok.prompt" && ! grep -rq 'canary-value-COUNCIL-TEST' "$REPO/.agents/runtime/council/"; echo $? )"
# The stub itself must have SEEN the variable (else the check above is vacuous).
run 10 "$MP" consult -q "what is 2+2" --order grok
check "negative control: the variable did reach the helper process" "$( grep -q 'canary-value-COUNCIL-TEST' "$CTL/grok.env"; echo $? )" "stub env capture missing — see fake-helper"
EXTRA_ENV=""

finish
