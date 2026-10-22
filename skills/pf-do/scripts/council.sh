#!/usr/bin/env bash
# council.sh — a council of helper CLIs (agy → grok → codex): a READ-ONLY
# second opinion, plus one gated write path (delegate, and run --role executor).
# The helpers never see the transcript: they get one prompt built from files
# and arguments, answer once, and their text is material, not a verdict
# (canon §11) — the calling agent verifies before acting.
#
# Usage:
#   council.sh consult  (-q "<question>" | -f <file>) [--order agy,grok,codex]
#   council.sh review   (--diff <file> | --commit <sha>) [--order ...]
#   council.sh parallel (-q|-f|--diff|--commit) [--order ...]   all at once
#   council.sh delegate --ticket <T-###.md> --worktree <path> [--repo <dir>]
#                       [--order agy,codex,grok]    a helper WRITES code (below)
#   council.sh delegate --audit --ticket <T-###.md> [--project <dir>]
#                       [--worktree <dir>/.claude/worktrees/<name>]   an audit
#                       under the audit contract (canon §12; below)
#   council.sh run --task <T-###.md> [--role reviewer|executor] [--agent
#                  claude|codex|agy|grok] [--model <name>] [--worktree <path>]
#                  [--repo <dir>] [--dry-run]   a fresh-context executor or
#                  reviewer as a separate CLI process (below)
#   council.sh ask (-f <file> | -q "<question>") [--agent <a>] [--model <m>]
#                  [--dry-run]   one read-only question, the answer on stdout
#   council.sh check                          which agent CLIs are usable here
#   council.sh <mode> ... --async            detach, print "PENDING: <marker>"
#   council.sh --wait <marker> [--timeout <seconds>]
#   council.sh --stats [--since YYYY-MM-DD]   helper × outcome table from the ledger
#   common: --timeout <seconds>  per-helper watchdog (default 300, delegate
#           1800; also the --wait poll limit), --order <list>  which helpers,
#           in what order (default: the "backends" array of council.json in
#           its order; delegate: agy,codex,grok)
#
# consult / review: the FIRST helper that answers wins; every helper tried
# before it prints its own state line, and a refusal (quota, not logged in,
# timeout, error, SKIP) falls through to the next name. When two or more
# helpers were tried the run ends with one summary line
#   chain: agy:QUOTA grok:OK        (tokens: OK QUOTA LOGIN TIMEOUT ERROR SKIP CAP)
# parallel: every enabled helper is asked
# at once; one line per helper, in --order order. The answer text lands in
# .agents/runtime/council/<date>-<mode>-<helper>-<n>.md under the header
# "Council answer — material, not a verdict; verify before acting".
#
# States — always a line on stdout, never silence (rc 0 iff at least one OK;
# every other outcome, all-SKIP included, is "no answer" and exits 1):
#   OK: <helper> <answer path>            FAIL: <helper> quota (<CLI text>)
#   SKIP: <helper> not installed          FAIL: <helper> not logged in
#   SKIP: <name> unknown backend (typo in council.json backends?) — not in agy/grok/codex
#   SKIP: <helper> not enabled            FAIL: <helper> timeout
#   SKIP: codex not consented             FAIL: <helper> error (rc=<n>; подробности: <raw file>)
#   FAIL: council disabled for this project   FAIL: daily cap reached (<n>/<cap>)
#   PENDING: <marker>   (--async)
#   delegate only:  FAIL: delegate disabled by project    FAIL: worktree dirty
#                   FAIL: <helper> touched files outside worktree
#   --audit only:   FAIL: --worktree <path> outside <project>/.claude/worktrees
#                   FAIL: audit worktree dirty <path>
#                   NOTE: audit worktree <path> removed; branch delegate/<ticket>-<name> keeps the findings
#   run / ask only: запасная: <agent>/<model> (<why the previous one was passed over>)
#                   FAIL: <agent> unknown model (<CLI text>)    DRY-RUN: cd <dir> && <argv>
#                   FAIL: <agent> wrote files as a read-only reviewer (<paths>; report: <path>)
#                   packet: «Результат»|«Ревью» updated in <ticket>
#
# Consent and spend: .agents/council.json of the project, e.g.
#   {"enabled": true, "backends": ["agy","grok","codex"], "daily_cap": 20,
#    "delegate": false}
# No file, or enabled not the JSON boolean true → FAIL: council disabled.
# Codex has its own, separate consent (canon §12): .agents/codex-review.json
# with "enabled": true — without it the codex helper is SKIP, in every mode. The ledger
# .agents/runtime/council-ledger.tsv gets one row per helper per call, whatever
# the outcome (T-127: the point is to COUNT how often a helper is away).
# Columns: date · helper · mode · input · output · cost (from the CLI's JSON,
# as is; "-" when it reports none) · answer path ("-" when none) · outcome
# (OK | FAIL:quota | FAIL:login | FAIL:timeout | FAIL:other | SKIP | skip-quota
# — the last one is history only: rows written by the removed quota precheck
# (T-137, dropped in v3); --stats still reads them). Rows
# written before T-127 have 7 columns and read as outcome "n/a". The daily
# cap counts only today's rows that could have cost something: 7-column
# rows and OK / FAIL:timeout / FAIL:other — a refusal (quota, login, SKIP)
# never eats a slot, so a day of quota errors cannot lock the council.
# --stats prints the helper × outcome table (WARN on stderr for a row with
# fewer than 7 fields, never a stop).
#
# Read-only in consult / review / parallel: agy runs in plan mode inside its
# sandbox, grok in plan mode with web search and subagents off, codex through
# codex-review.sh (review --commit) or `codex exec --sandbox read-only
# --ephemeral` (consult, review --diff).
#
# delegate is the ONE write path (canon §12; T-113): a helper implements a
# ticket under the pf-do contract inside an isolated git worktree, commits
# there, never merges, and a fresh Claude reviewer gates the diff. It needs
# "delegate": true in council.json on top of enabled. The worktree is created
# if absent (`git worktree add <path> -b delegate/<ticket>` from --repo's HEAD,
# --repo defaulting to the project root), must be clean if present, and must
# lie outside both trees. The prompt = the ticket file + the project's
# AGENTS.md + the contract text; the helper is told to touch nothing outside
# its cwd and to put its «Результат» in its final message (the ticket file is
# outside the worktree). Write modes, cwd = worktree: agy `--mode accept-edits
# --sandbox`, grok `--cwd <wt> --permission-mode acceptEdits` (web off), codex
# `codex exec -C <wt> --sandbox workspace-write` with network off. Protection
# is the worktree plus a before/after `git status --porcelain` of the main
# tree(s): any path that moved there → FAIL: <helper> touched files outside
# worktree — and the report still lands, so the gate sees it. pf-guard hooks
# do not see these helpers (they are not run through Claude Code's Bash).
# The report .agents/runtime/council/<date>-delegate-<helper>-<ticket>.md
# carries `git log --oneline BASE..HEAD`, the worktree's porcelain status,
# the outside-check result and the helper's final message. OK needs rc 0,
# a clean main tree and at least one change in the worktree; work left
# uncommitted is OK plus a NOTE line — the script never commits for the
# helper, and commits with whatever identity git resolves in that worktree
# (the repository's `git config --local user.*` when set, else global) —
# public distributions must carry their own local identity (canon §6).
# Fallback along --order stops once a helper has moved the tree;
# a run that changed nothing falls through. The delegate worktree is the
# deliverable and is never removed — except under --audit, below. (codex
# --ephemeral there means "no session file under ~/.codex", nothing about
# the worktree's commits.)
#
# delegate --audit (T-124, canon §12 — the audit contract): the night audit
# of a project by a helper. Four projects, four kinds of litter on 15.09
# (a 342 MB worktree in the projects root, findings without a journal or a
# commit, closed tickets reported as new), so the launcher enforces the
# contract instead of asking for it. The worktree is `<project>/.claude/
# worktrees/audit-<date>` (default; --worktree may name another DIRECT child
# of `<project>/.claude/worktrees/`, anything else — the projects root, /tmp,
# a `..` or symlink escape — is `FAIL: --worktree <path> outside …` before
# anything runs; paths are compared physically, `pwd -P`, never lexically).
# --project (default: the project root this script runs in) is the audited
# project: its council.json consents, its repository holds the worktree, its
# journal gets the entry; --repo is refused with --audit. The prompt gains
# the contract: read the closed packets (`status: done`) BEFORE reporting so
# old findings do not resurface as new; write the journal entry INSIDE the
# worktree (`<worktree>/.agents/journal/<date>.md`, committed on the branch)
# — the main tree's journal and the claims file belong to the launcher and
# the human, and a helper touching them fails the outside check like any
# other path. After the helper loop the launcher cleans up ONCE (a quota
# fallback to the next helper still needs the tree): clean worktree →
# `git worktree remove` + `NOTE: audit worktree <path> removed; branch
# delegate/<ticket>-<worktree name> keeps the findings` (the branch is the
# deliverable, the human merges; dated per run — the next night's audit is
# cut from the CURRENT head on its own branch, `-2`, `-3` … when taken); uncommitted work → the tree stays, `FAIL: audit worktree
# dirty <path>` and rc 1 whatever the helper's own state, for a human to
# settle (⏳). Then one entry `## HH:MM · council delegate --audit · <helper>`
# in `<project>/.agents/journal/<date>.md` (canon §10) naming the report,
# the branch and the worktree's fate — written after the outside snapshot,
# so it never counts as the helper's doing. No helper ran (all SKIP / cap)
# → the usual take-back of the unused worktree, no journal entry.
#
# run / ask / check (T-170, SPEC-workflow-v3 §5): on platforms without a
# subagent tool the executor and the reviewer are fresh CLI processes. `run
# --role executor` is delegate generalised: the same consent ("delegate":
# true), clean worktree, before/after snapshot of the main tree(s), report
# and no-fallback-once-the-tree-moved rule — plus `claude -p` as an agent and
# an explicit --model. Its worktree may also be a direct child of
# <repo>/.claude/worktrees/ (default <repo>/.claude/worktrees/<id>, branch
# <id> = the ticket's lowercased `id:`). `--role reviewer` (the default — the
# write role is never implied) runs the read-only commands in that worktree
# (or the repo root) and the same snapshot also covers the worktree: a
# reviewer that moved anything is FAIL: <agent> wrote files as a read-only
# reviewer. After the run the LAUNCHER (never the agent, and after the last
# snapshot) appends the outcome and the agent's final message, as a quote,
# to the ticket's «Результат» (executor) or «Ревью» (reviewer) section;
# stdout stays a short summary. `ask` is consult with a plain prompt and
# the answer text printed after the OK line. Agent and model come from
# --agent/--model, else from council.json `roles.<role>.primary {agent,
# model}` (`ask` reads roles.reviewer); `roles.<role>.fallback` is tried when
# the primary is unusable — unknown, `available.<agent>` false, not on PATH,
# codex without its consent, a quota/login refusal or a model the CLI does
# not know (read from the failed run's output) — with the line
# `запасная: <agent>/<model> (<reason>)`. `backends` is the council's list
# and does not gate run/ask: roles name the agents. --dry-run prints the
# exact argv (`DRY-RUN: cd <dir> && …`; the prompt shown by size), starts
# nothing, creates no worktree, writes no ledger row. `check` spends nothing
# (`command -v`, `<cli> --version`, `codex login status`, 15 s each, no
# consent needed): one line per agent `доступен: <a> (…)` / `недоступен: <a>
# (<reason>)`, rc 0 always, and the result lands in council.json as
# `available {claude, codex, agy, grok: bool, checked: "<date>"}` when that
# file exists as a plain file (its mode kept; a symlink is left alone, NOTE).
# Model names must start with a letter or digit ([A-Za-z0-9._:/@-]), so none
# can pass for a flag; --dry-run makes the same choices and refusals as a
# real run and calls nothing when no candidate is usable. CLI command lines: claude -p, prompt on stdin, CLAUDECODE
# unset for the child, no session file (--no-session-persistence, as codex
# runs --ephemeral) — executor `--permission-mode acceptEdits
# --permission-prompts none` plus a tool allowlist, reviewer/ask
# `--permission-mode plan`; agy/grok/codex reuse the delegate and read-only
# lines below with `--model` added.
#
# The bypass flags of these CLIs — --dangerously-skip-permissions (agy,
# claude), --always-approve and --permission-mode bypassPermissions (grok,
# claude), --dangerously-bypass-approvals-and-sandbox and --sandbox
# danger-full-access (codex) — appear in this file only in this comment
# block; `workspace-write` is allowed on exactly one line, the codex write
# command (delegate and run --role executor); tests/council.sh fails if
# either rule breaks.
#
# T-191 (QA 11.10): every child CLI runs with PF_COUNCIL_RUN=1 (session-start
# hooks stay silent in it); a run's final message passes the secret scan
# before it is written into the ticket (a finding = FAIL, nothing committed);
# .claude/worktrees/ and .agents/runtime/council* go to the local
# .git/info/exclude, which the git guard watches.
#
# Prompt material comes from -q / -f / --diff / --commit / --ticket only: this
# script reads no environment variable into a prompt, and nothing it prints
# quotes a secret: an error state names the exit code and the raw-output file
# under .agents/runtime/council/ (outside git), never the CLI's own text — its
# last line is the agent's to write (QA 12.10, gate T-193). Secrets stay where
# canon §5 keeps them.

set -uo pipefail

# Every child CLI this script starts (executor, reviewer, ask, consult, review)
# runs with PF_COUNCIL_RUN=1 (QA 11.10, Ж-8): the session hooks of the user's
# settings (pf-handoff's SessionStart, pf-workflow's session-id line) see it
# and stay silent, so a "fresh-context" agent never gets an instruction to
# continue the orchestrator's HANDOFF. Exported once here, so no launch path
# can miss it.
export PF_COUNCIL_RUN=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "$0")"
CODEX_REVIEW="$SCRIPT_DIR/codex-review.sh"
KNOWN_HELPERS="agy grok codex"

# --- Arguments ---------------------------------------------------------------
MODE=""; QUESTION=""; QFILE=""; DIFF_FILE=""; COMMIT=""
ORDER=""; ASYNC=0; WAIT_FILE=""; TIMEOUT=""; OWN_MARKER=""
TICKET=""; DWT=""; REPO_ARG=""; WAIT_TIMEOUT_SET=""; STATS=0; SINCE=""; AUDIT=0; PROJECT_ARG=""
AGENT_ARG=""; MODEL_ARG=""; ROLE=""; DRY=0
fail() { echo "FAIL: $1"; exit 1; }
need_value() { [ "$2" -ge 2 ] || fail "$1 requires a value"; }
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$PWD/$1" ;; esac; }
while [ $# -gt 0 ]; do
  case "$1" in
    consult|review|parallel|delegate|run|ask|check) [ -z "$MODE" ] || fail "one mode per call, got '$MODE' and '$1'"; MODE="$1"; shift ;;
    --task) need_value "$1" $#; TICKET="$(abs "$2")"; shift 2 ;;
    --agent) need_value "$1" $#; AGENT_ARG="$2"; shift 2 ;;
    --model) need_value "$1" $#; MODEL_ARG="$2"; shift 2 ;;
    --role) need_value "$1" $#; ROLE="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -q|--question) need_value "$1" $#; QUESTION="$2"; shift 2 ;;
    -f|--file) need_value "$1" $#; QFILE="$(abs "$2")"; shift 2 ;;
    --diff) need_value "$1" $#; DIFF_FILE="$(abs "$2")"; shift 2 ;;
    --commit) need_value "$1" $#; COMMIT="$2"; shift 2 ;;
    --ticket) need_value "$1" $#; TICKET="$(abs "$2")"; shift 2 ;;
    --worktree) need_value "$1" $#; DWT="$(abs "$2")"; shift 2 ;;
    --repo) need_value "$1" $#; REPO_ARG="$(abs "$2")"; shift 2 ;;
    --audit) AUDIT=1; shift ;;
    --project) need_value "$1" $#; PROJECT_ARG="$(abs "$2")"; shift 2 ;;
    --order) need_value "$1" $#; ORDER="$2"; shift 2 ;;
    --timeout) need_value "$1" $#; TIMEOUT="$2"; WAIT_TIMEOUT_SET=1; shift 2 ;;
    --async) ASYNC=1; shift ;;
    --wait) need_value "$1" $#; WAIT_FILE="$2"; shift 2 ;;
    --marker) need_value "$1" $#; OWN_MARKER="$2"; shift 2 ;;   # internal: set by the --async launcher
    --stats) STATS=1; shift ;;
    --since) need_value "$1" $#; SINCE="$2"; shift 2 ;;
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0"; exit 0 ;;
    *) fail "unknown argument '$1' — nothing was asked" ;;
  esac
done
# Defaults depend on the mode: delegate asks Gemini first (agy → codex → grok,
# decision 6) and gets a watchdog sized for implementation work, not an answer.
# The read-only modes take their default order from council.json (below,
# once the file is read); delegate keeps its own. run takes no --order (its
# candidates are --agent and roles.<role>) and the delegate watchdog.
case "$MODE" in
  run|ask|check) [ -z "$ORDER" ] || fail "--order belongs to consult / review / parallel / delegate — $MODE takes --agent (and roles in council.json)" ;;
  *) [ -z "$AGENT_ARG$MODEL_ARG$ROLE" ] && [ "$DRY" = 0 ] || fail "--agent, --model, --role and --dry-run belong to run / ask" ;;
esac
if [ "$MODE" = run ]; then
  [ -n "$ROLE" ] || ROLE=reviewer
  case "$ROLE" in executor|reviewer) : ;; *) fail "--role takes executor or reviewer, got '$ROLE'" ;; esac
fi
[ "$MODE" != ask ] || [ -z "$ROLE" ] || fail "--role belongs to run (ask is always read-only)"
[ "$DRY" = 0 ] || [ "$ASYNC" = 0 ] || fail "--dry-run starts nothing — it does not combine with --async"
if [ "$MODE" = delegate ] || [ "$MODE" = run ]; then
  [ -n "$ORDER" ] || [ "$MODE" = run ] || ORDER="agy,codex,grok"; [ -n "$TIMEOUT" ] || TIMEOUT=1800
else
  [ -n "$TIMEOUT" ] || TIMEOUT=300
fi
case "$TIMEOUT" in ''|*[!0-9]*) fail "--timeout takes a whole number of seconds, got '$TIMEOUT'" ;; esac

# --- --wait: poll the marker of a detached run -------------------------------
# The detached child appends its ordinary state lines to the marker and, last
# of all, writes "<marker>.done" holding its exit code — the sign-off. --wait
# polls for that file only: "not finished yet" is FAIL: wait timeout, never a
# verdict.
if [ -n "$WAIT_FILE" ]; then
  [ "$ASYNC" = 0 ] || fail "--async and --wait are separate calls"
  [ -f "$WAIT_FILE" ] || fail "no such marker: $WAIT_FILE"
  # No --timeout given: a delegate marker waits as long as its own watchdog (1800s).
  if [ -z "$WAIT_TIMEOUT_SET" ] && head -1 "$WAIT_FILE" | grep -qE '^# council --async (delegate|run)'; then TIMEOUT=1800; fi
  waited=0
  while [ ! -f "$WAIT_FILE.done" ]; do
    [ "$waited" -lt "$TIMEOUT" ] || { echo "FAIL: wait timeout — no sign-off after ${TIMEOUT}s, the run may still be going. Re-run: council.sh --wait $WAIT_FILE"; exit 1; }
    sleep 2; waited=$((waited + 2))
  done
  # An ask marker carries the answer text after its state lines: print the
  # whole marker body for it; every other mode prints the state lines only.
  if head -1 "$WAIT_FILE" | grep -q '^# council --async ask'; then grep -v '^# ' "$WAIT_FILE"
  else grep -E '^((OK|SKIP|FAIL|PENDING|NOTE|chain|запасная|packet|commit):|нет изменений)' "$WAIT_FILE"; fi
  rc="$(cat "$WAIT_FILE.done" 2>/dev/null)"
  case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
  exit "$rc"
fi

[ -n "$MODE" ] || [ "$STATS" = 1 ] || fail "mode required: consult | review | parallel | delegate | run | ask | check (or --wait <marker>, --stats)"
[ "$STATS" = 1 ] || [ -z "$SINCE" ] || fail "--since belongs to --stats"

# --- Project root, consent, ledger -------------------------------------------
# --audit --project <dir>: the audited project IS the project — its consent,
# its ledger, its answers, its journal — whatever directory this runs from.
if [ -n "$PROJECT_ARG" ]; then
  ROOT="$(git -C "$PROJECT_ARG" rev-parse --show-toplevel 2>/dev/null)" || fail "--project is not a git repository: $PROJECT_ARG"
elif git rev-parse --show-toplevel >/dev/null 2>&1; then
  ROOT="$(git rev-parse --show-toplevel)"
else
  ROOT="$PWD"
fi
CFG="$ROOT/.agents/council.json"
LEDGER="$ROOT/.agents/runtime/council-ledger.tsv"
ANSWER_DIR="$ROOT/.agents/runtime/council"
TODAY="$(date +%Y-%m-%d)"

# ensure_excludes <repo> — the launcher's own artefacts (.claude/worktrees/,
# the ledger, the answers directory) must not show up in the user's
# `git status` (QA 11.10, Ж-7: pf-auto step 8 wants a clean tree, and
# `git add .claude` would add a worktree as a gitlink). They go to the
# repository's LOCAL .git/info/exclude — never a commit to the project —
# once, when a line is missing. The launcher writes it before any agent
# starts; the git guard (git_guard) and snapshot() hash the file, so an
# agent that edits it afterwards is seen. A symlinked or unwritable exclude
# file is left alone with a NOTE (nothing here is worth a FAIL).
ensure_excludes() {
  local cdir ex pat
  cdir="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  [ -n "$cdir" ] && [ -d "$cdir" ] || return 0
  ex="$cdir/info/exclude"
  if [ -L "$ex" ]; then echo "NOTE: $ex is a symlink — council artefacts not excluded; add .claude/worktrees/ and .agents/runtime/council* to .gitignore"; return 0; fi
  for pat in /.claude/worktrees/ /.agents/runtime/council-ledger.tsv /.agents/runtime/council/; do
    grep -qxF -- "$pat" "$ex" 2>/dev/null && continue
    # A user's last line without a newline (QA 12.10, Н-5) would get our
    # pattern glued to it ("*.log/.claude/worktrees/") — both break.
    if [ -s "$ex" ] && [ -n "$(tail -c1 "$ex" 2>/dev/null)" ]; then printf '\n' >> "$ex" 2>/dev/null; fi
    { mkdir -p "$cdir/info" && printf '%s\n' "$pat" >> "$ex"; } 2>/dev/null \
      || { echo "NOTE: cannot write $ex — council artefacts not excluded; add .claude/worktrees/ and .agents/runtime/council* to .gitignore"; return 0; }
  done
}
# Called only once every argument is checked — after the delegate / run
# worktree checks below, and before --async creates its marker — so a refused
# call writes nothing to the user's exclude file (QA 12.10, Н-5).

# --- --stats: helper × outcome from the ledger (read-only; needs no consent) ---
# One row per helper (the three known ones always, others as they appear),
# outcomes as columns; 7-column rows (before T-127) count as "n/a". A row
# with fewer than 7 fields is a WARN on stderr and is skipped — a damaged
# line must not hide the rest of the table, and must not pass in silence.
if [ "$STATS" = 1 ]; then
  [ -z "$MODE" ] || fail "--stats is a call of its own, not a mode option"
  if [ -n "$SINCE" ]; then
    printf '%s' "$SINCE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || fail "--since takes YYYY-MM-DD, got '$SINCE'"
  fi
  echo "council --stats${SINCE:+ --since $SINCE} — ledger: $LEDGER"
  if [ ! -f "$LEDGER" ]; then echo "(no ledger yet — no helper call recorded)"; fi
  { [ -f "$LEDGER" ] && cat "$LEDGER"; } | awk -F'\t' -v since="$SINCE" -v known="$KNOWN_HELPERS" '
    BEGIN { nc = split("OK FAIL:quota FAIL:login FAIL:timeout FAIL:other SKIP skip-quota n/a", col, " ");
            nk = split(known, kh, " "); for (i = 1; i <= nk; i++) { order[++no] = kh[i]; seen[kh[i]] = 1 } }
    /^#/ || /^[[:space:]]*$/ { next }
    NF < 7 { printf "WARN: ledger line %d has %d field(s), skipped\n", NR, NF > "/dev/stderr"; next }
    since != "" && substr($1, 1, 10) < since { next }
    { h = $2; if (!(h in seen)) { seen[h] = 1; order[++no] = h }
      o = (NF >= 8) ? $8 : "n/a"; ok = 0
      for (i = 1; i <= nc; i++) if (o == col[i]) ok = 1
      if (!ok) { printf "WARN: ledger line %d has unknown outcome %s, counted as n/a\n", NR, o > "/dev/stderr"; o = "n/a" }
      n[h, o]++; tot[h]++ }
    END { printf "%-8s", "helper"; for (i = 1; i <= nc; i++) printf " %12s", col[i]; printf " %6s\n", "total"
          for (j = 1; j <= no; j++) { h = order[j]; printf "%-8s", h
            for (i = 1; i <= nc; i++) printf " %12d", n[h, col[i]] + 0
            printf " %6d\n", tot[h] + 0 } }'
  exit 0
fi

# json_field <file> <dot.path> — one scalar from a JSON file, "" when absent.
# json_is_true <file> <dot.path> — true only for the JSON boolean true (a
# quoted "true" is not consent: only a human-written file with a real boolean is).
if command -v jq >/dev/null 2>&1; then
  json_field() { jq -r --arg p "$2" 'getpath($p | split(".")) // empty | if type=="array" then join(",") else tostring end' "$1" 2>/dev/null; }
  json_is_true() { [ "$(jq -r --arg p "$2" 'getpath($p | split(".")) == true' "$1" 2>/dev/null)" = true ]; }
  json_is_false() { [ "$(jq -r --arg p "$2" 'getpath($p | split(".")) == false' "$1" 2>/dev/null)" = true ]; }
  # json_set_available <file> <object> — `available` replaced, the rest kept.
  json_with_available() { jq --argjson a "$2" '.available = $a' "$1" 2>/dev/null; }
elif command -v python3 >/dev/null 2>&1; then
  json_field() { python3 - "$1" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
    for k in sys.argv[2].split("."):
        d = d[k]
    if isinstance(d, list): d = ",".join(str(x) for x in d)
    if isinstance(d, bool): d = str(d).lower()
    print(d)
except Exception:
    pass
PY
  }
  json_is_true() { python3 - "$1" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
    for k in sys.argv[2].split("."):
        d = d[k]
    sys.exit(0 if d is True else 1)
except Exception:
    sys.exit(1)
PY
  }
  json_is_false() { python3 - "$1" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
    for k in sys.argv[2].split("."):
        d = d[k]
    sys.exit(0 if d is False else 1)
except Exception:
    sys.exit(1)
PY
  }
  json_with_available() { python3 - "$1" "$2" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
if not isinstance(d, dict): sys.exit(1)
d["available"] = json.loads(sys.argv[2])
sys.stdout.write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
PY
  }
else
  fail "council needs jq or python3 to read JSON"
fi
# json_set_available <file> <object> — `available` replaced, the rest kept.
# Plain files only: a symlink is never written, neither through nor over
# (the caller says so) — a committed relative link in a cloned project
# would otherwise let `check` rewrite any JSON file the user owns. The new
# text goes to a copy beside the file (`cp -p`: the mode is kept) and
# replaces it with one mv.
json_set_available() {
  local t="$1" tmp
  [ ! -L "$t" ] && [ -f "$t" ] || return 1
  tmp="$t.council.$$"
  cp -p "$t" "$tmp" 2>/dev/null && json_with_available "$t" "$2" > "$tmp" && mv -f "$tmp" "$t" || { rm -f "$tmp"; return 1; }
}

# --- check: which agent CLIs are usable here (spends nothing, needs no consent)
# One line per known agent, rc 0 whatever the outcome — a wave asks this
# first and simply does not offer what is missing. Probes are free:
# command -v, `<cli> --version`, `codex login status`, 15 s each. A CLI
# missing from PATH (Claude Desktop started from the Dock takes PATH from
# the login shell) is reported as such, never a crash.
KNOWN_AGENTS="claude codex agy grok"
if [ "$MODE" = check ]; then
  CKDIR="$(mktemp -d "${TMPDIR:-/tmp}/council-check.XXXXXXXX")" || fail "cannot create temp dir"
  trap 'rm -rf "$CKDIR"' EXIT
  # probe <secs> <cmd...> — rc of the command, 124 when it outlived <secs>.
  probe() {
    local lim=$(( $1 * 10 )) n=0 pid; shift
    "$@" > "$CKDIR/out" 2>&1 </dev/null & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      [ "$n" -lt "$lim" ] || { kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; }
      sleep 0.1; n=$((n + 1))
    done
    wait "$pid"
  }
  firstline() { grep -v '^[[:space:]]*$' "$CKDIR/out" 2>/dev/null | head -1 | tr -d '\r' | cut -c1-80; }
  obj=""
  for a in $KNOWN_AGENTS; do
    ok=false
    if ! command -v "$a" >/dev/null 2>&1; then
      echo "недоступен: $a (нет в PATH)"
    elif [ "$a" = codex ] && ! { [ -r "$ROOT/.agents/codex-review.json" ] && json_is_true "$ROOT/.agents/codex-review.json" enabled; }; then
      echo "недоступен: codex (нет согласия: .agents/codex-review.json с \"enabled\": true, канон §12)"
    else
      probe 15 "$a" --version; rc=$?
      if [ "$rc" != 0 ]; then
        echo "недоступен: $a (--version: rc $rc — $(firstline))"
      else
        ver="$(firstline)"
        if [ "$a" = codex ]; then
          probe 15 codex login status; rc=$?
          if [ "$rc" != 0 ]; then echo "недоступен: codex (не залогинен: rc $rc — $(firstline))"; else ok=true; fi
        else
          ok=true
        fi
        [ "$ok" = false ] || echo "доступен: $a ($ver)"
      fi
    fi
    obj="$obj\"$a\": $ok, "
  done
  obj="{${obj}\"checked\": \"$(date '+%Y-%m-%d %H:%M')\"}"
  if [ -L "$CFG" ]; then
    echo "NOTE: .agents/council.json is a symlink — availability not saved (check never writes through or over a link; save it by hand or make the file a plain one)" >&2
  elif [ ! -f "$CFG" ]; then
    echo "NOTE: no .agents/council.json in $ROOT — availability not saved"
  elif ! json_set_available "$CFG" "$obj"; then
    echo "NOTE: availability NOT saved to $CFG (not valid JSON, or not writable)"
  fi
  exit 0
fi

[ -r "$CFG" ] || fail "council disabled for this project (no readable .agents/council.json)"
json_is_true "$CFG" enabled || fail "council disabled for this project (.agents/council.json: enabled is not the JSON boolean true)"
# A helper writing code is a second, separate consent (canon §12): delegate
# must be the JSON boolean true as well — absent or false means read-only only.
# run --role executor is that same write path under another name.
WRITE=0; { [ "$MODE" = delegate ] || { [ "$MODE" = run ] && [ "$ROLE" = executor ]; }; } && WRITE=1
[ "$WRITE" = 0 ] || json_is_true "$CFG" delegate || fail "delegate disabled by project (.agents/council.json: delegate is not the JSON boolean true)"
# backends absent or [] = every known helper (an explicit "nobody" is enabled: false).
ENABLED_HELPERS="$(json_field "$CFG" backends | tr ',' ' ')"
[ -n "$ENABLED_HELPERS" ] || ENABLED_HELPERS="$KNOWN_HELPERS"
# Read-only modes: no --order → the backends array IS the order (T-127: the
# human ranks the helpers by writing the file); no array → agy,grok,codex.
if [ "$MODE" != delegate ] && [ "$MODE" != run ] && [ "$MODE" != ask ] && [ -z "$ORDER" ]; then
  ORDER="$(json_field "$CFG" backends)"; [ -n "$ORDER" ] || ORDER="agy,grok,codex"
fi
# run / ask: the candidates — the primary (--agent/--model, else roles.<role>
# .primary) and roles.<role>.fallback when it differs. Parallel arrays (bash
# 3.2 has no associative ones); ORDER = the agent names, for the checks below.
CAND_A=(); CAND_M=(); MODEL_ARGS=()
MODE_LABEL="$MODE"; [ "$MODE" != run ] || MODE_LABEL="run-$ROLE"
if [ "$MODE" = run ] || [ "$MODE" = ask ]; then
  rk="$ROLE"; [ "$MODE" = run ] || rk=reviewer
  pa="$AGENT_ARG"; pm="$MODEL_ARG"
  if [ -z "$pa" ]; then
    pa="$(json_field "$CFG" "roles.$rk.primary.agent")"; [ -n "$pm" ] || pm="$(json_field "$CFG" "roles.$rk.primary.model")"
  elif [ -z "$pm" ] && [ "$(json_field "$CFG" "roles.$rk.primary.agent")" = "$pa" ]; then
    pm="$(json_field "$CFG" "roles.$rk.primary.model")"
  fi
  [ -n "$pa" ] || fail "$MODE needs --agent <claude|codex|agy|grok> (or roles.$rk.primary in .agents/council.json)"
  if [ -n "$AGENT_ARG" ]; then
    case " $KNOWN_AGENTS " in *" $AGENT_ARG "*) : ;; *) fail "--agent takes claude, codex, agy or grok, got '$AGENT_ARG'" ;; esac
  fi
  CAND_A=("$pa"); CAND_M=("$pm")
  fa="$(json_field "$CFG" "roles.$rk.fallback.agent")"; fm="$(json_field "$CFG" "roles.$rk.fallback.model")"
  if [ -n "$fa" ] && { [ "$fa" != "$pa" ] || [ "$fm" != "$pm" ]; }; then CAND_A=("$pa" "$fa"); CAND_M=("$pm" "$fm"); fi
  # Every model name — --model, roles.*.primary, roles.*.fallback — goes on
  # a CLI's argv after --model: an allowlist, and the first character must
  # be a letter or digit, so a name can never be read as a flag
  # (`--model --dangerously-skip-permissions`, `-c`). Empty = the CLI default.
  for m in "${CAND_M[@]}"; do
    [ -z "$m" ] && continue
    case "$m" in [!A-Za-z0-9]*|*[!A-Za-z0-9._:/@-]*) fail "model names are [A-Za-z0-9._:/@-] starting with a letter or digit, got '$m'" ;; esac
  done
  ORDER="$(printf '%s,' "${CAND_A[@]}" | sed 's/,$//')"
fi
# daily_cap: absent = 20; present but not a whole number = a spend limit we
# cannot read, and that is a loud stop, not a silent default (§11).
CAP="$(json_field "$CFG" daily_cap)"
[ -n "$CAP" ] || CAP=20
case "$CAP" in *[!0-9]*) fail "daily_cap in .agents/council.json must be a whole number, got '$CAP'" ;; esac

# Rows today = first column starting with today's date. The path column also
# carries the date, so this is a column count, never a grep over whole lines.
# Only rows that could have cost count (see header): 7-column rows and
# outcome OK / FAIL:timeout / FAIL:other; refusals and SKIPs take no slot.
ledger_today() {
  if [ -f "$LEDGER" ]; then
    awk -F'\t' -v d="$TODAY" 'index($1, d) == 1 && (NF < 8 || $8 == "OK" || $8 == "FAIL:timeout" || $8 == "FAIL:other") { n++ } END { print n + 0 }' "$LEDGER"
  else echo 0; fi
}
# ledger_row <helper> <in> <out> <cost> <answer> <outcome> — one 8-column row.
ledger_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M')" "$1" "$MODE_LABEL" "$2" "$3" "$4" "$5" "$6" >> "$LEDGER" 2>/dev/null
}
# Detached runs still going (marker without .done, today's) reserve a slot
# each: several --async launches would otherwise all read the same count.
pending_today() {
  local m c=0
  for m in "$ANSWER_DIR/$TODAY"-*.pending; do
    [ -f "$m" ] && [ ! -f "$m.done" ] && [ "$m" != "$OWN_MARKER" ] && c=$((c + 1))
  done
  echo "$c"
}
# cap_check [launched] — rows today, plus detached runs still pending, plus
# helpers this run has launched but whose rows are not written yet (parallel)
# must stay under the cap.
cap_check() {
  local n; n=$(( $(ledger_today) + $(pending_today) + ${1:-0} ))
  [ "$n" -lt "$CAP" ] || { echo "FAIL: daily cap reached ($n/$CAP)"; return 1; }
}
cap_check || exit 1

# --- Input validation --------------------------------------------------------
have=0
[ -n "$QUESTION" ] && have=$((have + 1)); [ -n "$QFILE" ] && have=$((have + 1))
[ -n "$DIFF_FILE" ] && have=$((have + 1)); [ -n "$COMMIT" ] && have=$((have + 1))
if [ "$MODE" = delegate ]; then
  [ "$have" -eq 0 ] || fail "delegate takes --ticket and --worktree, not -q/-f/--diff/--commit"
  [ -n "$TICKET" ] || fail "delegate requires --ticket <T-###.md>"
  if [ "$AUDIT" = 1 ]; then
    [ -z "$REPO_ARG" ] || fail "--audit takes --project <dir>, not --repo (the audited project's repository holds the worktree)"
  else
    [ -z "$PROJECT_ARG" ] || fail "--project belongs to delegate --audit"
    [ -n "$DWT" ] || fail "delegate requires --worktree <path>"
  fi
  { [ -f "$TICKET" ] && [ -r "$TICKET" ] && [ -s "$TICKET" ]; } || fail "--ticket needs a readable, non-empty regular file: $TICKET"
elif [ "$MODE" = run ]; then
  [ "$have" -eq 0 ] || fail "run takes --task (and --worktree), not -q/-f/--diff/--commit"
  [ "$AUDIT" = 0 ] && [ -z "$PROJECT_ARG" ] || fail "--audit and --project belong to delegate"
  [ -n "$TICKET" ] || fail "run requires --task <T-###.md>"
  # The launcher writes the outcome into this file afterwards: it must be a
  # regular, writable file, not a symlink that would carry the write elsewhere.
  { [ -f "$TICKET" ] && [ ! -L "$TICKET" ] && [ -r "$TICKET" ] && [ -w "$TICKET" ] && [ -s "$TICKET" ]; } || fail "--task needs a readable, writable, non-empty regular file (not a symlink): $TICKET"
else
  [ -z "$TICKET$DWT$REPO_ARG" ] || fail "--ticket, --worktree and --repo belong to delegate (and --task, --worktree, --repo to run)"
  [ "$AUDIT" = 0 ] && [ -z "$PROJECT_ARG" ] || fail "--audit and --project belong to delegate"
  [ "$have" -eq 1 ] || fail "give exactly one of -q, -f, --diff, --commit (got $have)"
fi
case "$MODE" in
  consult|ask) [ -z "$DIFF_FILE$COMMIT" ] || fail "$MODE takes -q or -f; use review for a diff" ;;
  review)  [ -n "$DIFF_FILE$COMMIT" ] || fail "review takes --diff <file> or --commit <sha>" ;;
esac
# A directory or an empty file would send ~25k tokens of helper prompt for nothing.
[ -z "$QFILE" ] || { [ -f "$QFILE" ] && [ -r "$QFILE" ] && [ -s "$QFILE" ]; } || fail "-f needs a readable, non-empty regular file: $QFILE"
[ -z "$DIFF_FILE" ] || { [ -f "$DIFF_FILE" ] && [ -r "$DIFF_FILE" ] && [ -s "$DIFF_FILE" ]; } || fail "--diff needs a readable, non-empty regular file: $DIFF_FILE"
HELPERS="$(printf '%s' "$ORDER" | tr ',' ' ')"
[ -n "${HELPERS//[[:space:]]/}" ] || fail "--order is empty"
case "$HELPERS" in *[!a-z0-9_\ -]*) fail "--order takes helper names ([a-z0-9_-]), got '$ORDER'" ;; esac

# --- --async: detach and hand back a marker ----------------------------------
# Detaches BEFORE any worktree or temp file exists: the child owns all of
# that. It re-runs this script synchronously with the same arguments minus
# --async; its state lines are appended to the marker, its exit code is the
# sign-off.
if [ "$ASYNC" = 1 ]; then
  ensure_excludes "$ROOT"   # the marker below is the first artefact
  mkdir -p "$ANSWER_DIR" || fail "cannot create $ANSWER_DIR"
  MARKER="$ANSWER_DIR/$(date +%Y-%m-%d-%H%M%S)-$MODE-$$.pending"
  { echo "# council --async $MODE — started $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# read with: council.sh --wait $MARKER"; } > "$MARKER" || fail "cannot write $MARKER"
  set -- "$MODE" --timeout "$TIMEOUT" --marker "$MARKER"
  # run / ask re-resolve their candidates in the child from the same inputs.
  case "$MODE" in run|ask) : ;; *) set -- "$@" --order "$ORDER" ;; esac
  [ -n "$AGENT_ARG" ] && set -- "$@" --agent "$AGENT_ARG"
  [ -n "$MODEL_ARG" ] && set -- "$@" --model "$MODEL_ARG"
  [ -n "$ROLE" ] && set -- "$@" --role "$ROLE"
  [ -n "$QUESTION" ] && set -- "$@" -q "$QUESTION"
  [ -n "$QFILE" ] && set -- "$@" -f "$QFILE"
  [ -n "$COMMIT" ] && set -- "$@" --commit "$COMMIT"
  [ -n "$DIFF_FILE" ] && set -- "$@" --diff "$DIFF_FILE"
  [ -n "$TICKET" ] && set -- "$@" --ticket "$TICKET"
  [ -n "$DWT" ] && set -- "$@" --worktree "$DWT"
  [ -n "$REPO_ARG" ] && set -- "$@" --repo "$REPO_ARG"
  [ "$AUDIT" = 0 ] || set -- "$@" --audit
  [ -n "$PROJECT_ARG" ] && set -- "$@" --project "$PROJECT_ARG"
  ( cd "$ROOT" && nohup bash "$SELF" "$@" >> "$MARKER" 2>/dev/null; echo "$?" > "$MARKER.done" ) </dev/null >/dev/null 2>&1 &
  echo "PENDING: $MARKER"
  exit 0
fi

# --- Material: worktree for a commit, then the prompt ------------------------
# A commit is reviewed from a DETACHED worktree pinned to that sha, so the
# helper sees the tree the diff belongs to and nothing that moved since. The
# worktree lives under $TMPDIR and is removed on every exit path.
WORKDIR="$ROOT"; WT=""; TMPS=""; DELEGATE_CREATED=0; DELEGATE_RAN=0; DELEGATE_TREE_MOVED=0
AUDIT_HELPER=""; AUDIT_STATE=""; AUDIT_DIRTY=0   # --audit: the last helper that worked, for the journal
cleanup() {
  [ -n "$WT" ] && [ -d "$WT" ] && git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1
  # A delegate worktree this run created but no helper ever entered (all SKIP
  # / cap / quota) is taken back with its branch; one a helper touched stays.
  if [ "$DELEGATE_CREATED" = 1 ] && [ "$DELEGATE_RAN" = 0 ] && [ -d "$DWT" ]; then
    git -C "$REPO" worktree remove --force "$DWT" >/dev/null 2>&1 && git -C "$REPO" branch -D "$DBRANCH_NEW" >/dev/null 2>&1
  fi
  [ -n "$TMPS" ] && rm -rf "$TMPS"
}
trap cleanup EXIT
TMPS="$(mktemp -d "${TMPDIR:-/tmp}/council.XXXXXXXX")" || fail "cannot create temp dir"

# --diff has no tree: the helpers run from an empty directory, so an agentic
# CLI cannot wander into the live checkout, and the prompt says so.
if [ -n "$DIFF_FILE" ] && [ -z "$COMMIT" ]; then
  WORKDIR="$TMPS/empty"; mkdir -p "$WORKDIR"
fi
if [ -n "$COMMIT" ]; then
  COMMIT="$(git -C "$ROOT" rev-parse --verify --quiet "${COMMIT}^{commit}")" || fail "unknown commit '$COMMIT'"
  WT="$TMPS/wt"
  git -C "$ROOT" worktree add --detach "$WT" "$COMMIT" >/dev/null 2>&1 || fail "cannot create a detached worktree for $COMMIT"
  WORKDIR="$WT"
  DIFF_FILE="$TMPS/commit.diff"
  git -C "$ROOT" show "$COMMIT" > "$DIFF_FILE" 2>/dev/null || fail "git show $COMMIT failed"
fi

# --- delegate: the repository, the isolated worktree, the base --------------
# The worktree belongs to --repo (default: the project root) and is NOT the
# detached $WT above: it is the deliverable, so cleanup never touches it.
REPO=""; BASE=""; DBRANCH=""; DBRANCH_NEW=""; TICKET_ID=""; TICKET_TITLE=""; GUARD_TRIPPED=0; GUARD_CDIR=""; GUARD_GDIR=""
# snapshot <tree> — porcelain status (-uall: every untracked FILE, so a new
# file inside an already-untracked directory is seen, not folded into
# "?? dir/") plus a checksum of the tracked modifications, so a further
# edit to an already-dirty path is seen too. Every "?? path" line carries
# the file's content hash (" @<sha>"): an overwrite of a file that was
# ALREADY untracked before the run — the main tree's unsaved journal, say —
# changes nothing in the status and would otherwise pass unseen (T-124
# review). Paths unquoted (core.quotePath=false) so the hash reads the file
# itself; a directory entry (a nested repo) hashes to "" on both sides.
snapshot() {
  git -C "$1" -c core.quotePath=false status --porcelain -uall 2>/dev/null | LC_ALL=C sort | while IFS= read -r line; do
    case "$line" in
      "?? "*) printf '%s @%s\n' "$line" "$(git -C "$1" hash-object -- "${line#\?\? }" 2>/dev/null)" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
  printf 'tracked-diff %s\n' "$(git -C "$1" diff HEAD 2>/dev/null | git hash-object --stdin 2>/dev/null)"
  # What info/exclude hides from the status above (ensure_excludes, Ж-7) is
  # watched here instead: the exclude file itself, the ledger, and the
  # entries of .claude/worktrees/ — an agent that edits any of them is seen.
  local cdir; cdir="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  printf 'info-exclude %s\n' "$( [ -n "$cdir" ] && [ -f "$cdir/info/exclude" ] && cksum < "$cdir/info/exclude")"
  printf 'ledger %s\n' "$( [ -f "$1/.agents/runtime/council-ledger.tsv" ] && cksum < "$1/.agents/runtime/council-ledger.tsv")"
  printf 'worktrees %s\n' "$(ls -A "$1/.claude/worktrees" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
}
if [ "$MODE" = delegate ]; then
  REPO="$(git -C "${REPO_ARG:-$ROOT}" rev-parse --show-toplevel 2>/dev/null)" || fail "--repo is not a git repository: ${REPO_ARG:-$ROOT}"
  # Physical paths throughout: git prints them that way (/private/var on
  # macOS), and the outside-the-tree check and worktree lookup compare strings.
  if [ "$AUDIT" = 1 ]; then
    # The audit worktree lives INSIDE the project, as a direct child of
    # <project>/.claude/worktrees/ (created here when absent) — never in the
    # projects root or /tmp. Physical paths on both sides: a `..`, a symlink
    # or a macOS /tmp → /private/tmp alias must not slip past a string compare.
    # The expected root is built from the project's physical path, never
    # resolved through .claude/worktrees itself: a symlink there (or at
    # .claude) pointing outside the project would make both sides agree on
    # the outside path (T-124 review, H1). The directory is created only
    # once the requested parent reads, lexically, as that root — a refused
    # path leaves nothing behind.
    AUDIT_WTROOT="$(cd "$ROOT" && pwd -P)/.claude/worktrees"
    [ -n "$DWT" ] || DWT="$AUDIT_WTROOT/audit-$TODAY"
    # Create it for the default path, or for a --worktree whose parent is
    # literally ".../worktrees" under the project's physical .claude/ (a
    # logical spelling of the project path is fine; a symlink named
    # worktrees is not created through and fails the physical check below).
    AUDIT_PARENT="$(dirname "$DWT")"
    if [ "$AUDIT_PARENT" = "$AUDIT_WTROOT" ] || { [ "$(basename "$AUDIT_PARENT")" = worktrees ] && [ ! -L "$AUDIT_PARENT" ] && [ -d "$(dirname "$AUDIT_PARENT")" ] && [ "$(cd "$(dirname "$AUDIT_PARENT")" && pwd -P)" = "$(dirname "$AUDIT_WTROOT")" ]; }; then
      mkdir -p "$AUDIT_WTROOT" 2>/dev/null || fail "cannot create $AUDIT_WTROOT"
    fi
    AUDIT_PARENT=""; [ -d "$(dirname "$DWT")" ] && AUDIT_PARENT="$(cd "$(dirname "$DWT")" && pwd -P)"
    [ "$AUDIT_PARENT" = "$AUDIT_WTROOT" ] || fail "--worktree $DWT outside $AUDIT_WTROOT — an audit worktree is a direct child of <project>/.claude/worktrees (a real directory, not a symlink), never the projects root"
    case "$(basename "$DWT")" in .|..) fail "--worktree $DWT outside $AUDIT_WTROOT — name a child directory" ;; esac
    DWT="$AUDIT_WTROOT/$(basename "$DWT")"
  else
    [ -d "$(dirname "$DWT")" ] || fail "--worktree parent directory does not exist: $(dirname "$DWT")"
    DWT="$(cd "$(dirname "$DWT")" && pwd -P)/$(basename "$DWT")"
    case "$DWT/" in "$REPO"/*|"$ROOT"/*) fail "--worktree must lie outside the repository and the project tree, got $DWT" ;; esac
  fi
  TICKET_ID="$(basename "$TICKET" .md)"
  case "$TICKET_ID" in *[!A-Za-z0-9._-]*) fail "--ticket file name must be [A-Za-z0-9._-] (it names the branch), got '$TICKET_ID'" ;; esac
  # Branch: delegate/<ticket> — one ticket, one branch, the worktree reused.
  # --audit: the worktree is removed after every run and the branch stays as
  # the deliverable, so a repeat (the next night, the same ticket) needs a
  # branch of its own, cut from the repo's CURRENT HEAD — never the previous
  # night's tip: delegate/<ticket>-<worktree name>, then -2, -3 … when taken.
  DBRANCH_NEW="delegate/$TICKET_ID"
  if [ "$AUDIT" = 1 ]; then
    DBRANCH_NEW="delegate/$TICKET_ID-$(basename "$DWT")"; n=1
    while git -C "$REPO" rev-parse --verify --quiet "refs/heads/$DBRANCH_NEW" >/dev/null; do n=$((n + 1)); DBRANCH_NEW="delegate/$TICKET_ID-$(basename "$DWT")-$n"; done
  fi
  if [ -e "$DWT" ]; then
    git -C "$REPO" worktree list --porcelain 2>/dev/null | grep -qx "worktree $DWT" || fail "--worktree exists but is not a worktree of $REPO: $DWT"
    [ -z "$(git -C "$DWT" status --porcelain 2>/dev/null)" ] || fail "worktree dirty ($DWT) — commit or clean it before delegating"
    # An existing audit worktree (a removal that failed earlier) is on one of
    # ITS ticket's dated branches; any other branch is another ticket's.
    if [ "$AUDIT" = 1 ]; then
      case "$(git -C "$DWT" rev-parse --abbrev-ref HEAD 2>/dev/null)" in "delegate/$TICKET_ID-"*) : ;; *) fail "--worktree is on branch '$(git -C "$DWT" rev-parse --abbrev-ref HEAD 2>/dev/null)', not delegate/$TICKET_ID-* — the helper's commits would land on another ticket's branch" ;; esac
    else
      [ "$(git -C "$DWT" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "delegate/$TICKET_ID" ] || fail "--worktree is on branch '$(git -C "$DWT" rev-parse --abbrev-ref HEAD 2>/dev/null)', not delegate/$TICKET_ID — the helper's commits would land on another ticket's branch"
    fi
  else
    git -C "$REPO" worktree add "$DWT" -b "$DBRANCH_NEW" >"$TMPS/wt.log" 2>&1 \
      || fail "cannot create worktree $DWT on branch $DBRANCH_NEW ($(tail -1 "$TMPS/wt.log" | cut -c1-160))"
    DELEGATE_CREATED=1
  fi
  BASE="$(git -C "$DWT" rev-parse HEAD)"; DBRANCH="$(git -C "$DWT" rev-parse --abbrev-ref HEAD)"
  WORKDIR="$DWT"
fi

# --- run: the repository, the worktree, the base -----------------------------
# phys_path <path> — the physical spelling of a path that may not exist yet:
# the deepest existing ancestor through `pwd -P`, the rest appended. A `.` or
# `..` segment is refused (rc 1) — no lexical escape past the checks below.
phys_path() {
  local p="$1" rest=""
  case "/$p/" in */./*|*/../*) return 1 ;; esac
  while [ ! -d "$p" ]; do rest="/$(basename "$p")$rest"; p="$(dirname "$p")"; done
  printf '%s%s' "$(cd "$p" && pwd -P)" "$rest"
}
# The worktree is a direct child of <repo>/.claude/worktrees/ (this canon's own
# convention, the default) or lies outside both trees, as for delegate. The
# executor's worktree is created here on branch <id> (the ticket's `id:`,
# lowercased), or reused when it exists, is clean and is on that branch. The
# reviewer never creates one: it reads the existing worktree, else the repo.
# --dry-run validates the paths and creates nothing.
if [ "$MODE" = run ]; then
  REPO="$(git -C "${REPO_ARG:-$ROOT}" rev-parse --show-toplevel 2>/dev/null)" || fail "--repo is not a git repository: ${REPO_ARG:-$ROOT}"
  REPO_P="$(cd "$REPO" && pwd -P)"; ROOT_P="$(cd "$ROOT" && pwd -P)"
  TICKET_ID="$(awk 'NR <= 30 && /^id:/ { sub(/^id:[[:space:]]*/, ""); gsub(/["\047\r ]/, ""); print; exit }' "$TICKET")"
  [ -n "$TICKET_ID" ] || TICKET_ID="$(basename "$TICKET" .md)"
  # The launcher's commit subject (run --role executor): the ticket's title:
  # line, quotes and control characters dropped, one line, 120 characters.
  TICKET_TITLE="$(awk 'NR <= 30 && /^title:/ { sub(/^title:[[:space:]]*/, ""); gsub(/["\047]/, ""); gsub(/[[:cntrl:]]/, ""); print; exit }' "$TICKET" | cut -c1-120)"
  case "$TICKET_ID" in *[!A-Za-z0-9._-]*) fail "the ticket id must be [A-Za-z0-9._-] (it names the branch), got '$TICKET_ID'" ;; esac
  DBRANCH_NEW="$(printf '%s' "$TICKET_ID" | tr '[:upper:]' '[:lower:]')"
  RUN_WTROOT="$REPO_P/.claude/worktrees"; DWT_GIVEN="$DWT"
  [ -n "$DWT" ] || DWT="$RUN_WTROOT/$DBRANCH_NEW"
  DWT_P="$(phys_path "$DWT")" || fail "--worktree must be a plain path (no . or .. segments), got $DWT"
  if [ "$(dirname "$DWT_P")" != "$RUN_WTROOT" ]; then
    case "$DWT_P/" in "$REPO_P"/*|"$ROOT_P"/*) fail "--worktree must be a direct child of $RUN_WTROOT or lie outside the repository and the project tree, got $DWT" ;; esac
  fi
  DWT="$DWT_P"; WORKDIR="$DWT"; DBRANCH="$DBRANCH_NEW"; BASE="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"
  # --dry-run walks the same choice and the same refusals; it only skips
  # creating the executor's worktree (it prints where it would be).
  if [ "$ROLE" = executor ]; then
    if [ -e "$DWT" ]; then
      git -C "$REPO" worktree list --porcelain 2>/dev/null | grep -qx "worktree $DWT" || fail "--worktree exists but is not a worktree of $REPO: $DWT"
      [ -z "$(git -C "$DWT" status --porcelain 2>/dev/null)" ] || fail "worktree dirty ($DWT) — commit or clean it before running an executor"
      [ "$(git -C "$DWT" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$DBRANCH_NEW" ] || fail "--worktree is on branch '$(git -C "$DWT" rev-parse --abbrev-ref HEAD 2>/dev/null)', not $DBRANCH_NEW — the executor's commits would land on another ticket's branch"
    elif [ "$DRY" = 1 ]; then
      [ "$(dirname "$DWT")" = "$RUN_WTROOT" ] || [ -d "$(dirname "$DWT")" ] || fail "--worktree parent directory does not exist: $(dirname "$DWT")"
    else
      [ "$(dirname "$DWT")" != "$RUN_WTROOT" ] || mkdir -p "$RUN_WTROOT" || fail "cannot create $RUN_WTROOT"
      [ -d "$(dirname "$DWT")" ] || fail "--worktree parent directory does not exist: $(dirname "$DWT")"
      git -C "$REPO" worktree add "$DWT" -b "$DBRANCH_NEW" >"$TMPS/wt.log" 2>&1 \
        || fail "cannot create worktree $DWT on branch $DBRANCH_NEW ($(tail -1 "$TMPS/wt.log" | cut -c1-160))"
      DELEGATE_CREATED=1
    fi
    if [ -e "$DWT" ]; then BASE="$(git -C "$DWT" rev-parse HEAD)"; DBRANCH="$(git -C "$DWT" rev-parse --abbrev-ref HEAD)"; fi
  elif [ -e "$DWT" ]; then
    git -C "$REPO" worktree list --porcelain 2>/dev/null | grep -qx "worktree $DWT" || fail "--worktree exists but is not a worktree of $REPO: $DWT"
    BASE="$(git -C "$DWT" rev-parse HEAD)"; DBRANCH="$(git -C "$DWT" rev-parse --abbrev-ref HEAD)"
  elif [ -n "$DWT_GIVEN" ]; then
    fail "--worktree does not exist: $DWT — a reviewer reads an existing worktree and never creates one"
  else
    DWT=""; WORKDIR="$REPO"; DBRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  fi
fi

# Every argument has passed its check by now (Н-5); before any snapshot.
if [ "$DRY" = 0 ]; then
  ensure_excludes "$ROOT"
  [ -z "$REPO" ] || [ "$REPO" = "$ROOT" ] || ensure_excludes "$REPO"
fi

PROMPT_FILE="$TMPS/prompt.txt"
if [ "$MODE" = run ]; then
  COMMIT_RULE="- Do NOT commit: the orchestrator commits your changes after the run
  (\`git commit\`, \`git add\` and any write under .git are refused — a
  commit of yours FAILS the run). A commit step written in the ticket is
  done by the launcher — not a deviation of yours. Never merge, rebase,
  push, create a pull request or switch branches."
else
  COMMIT_RULE="- Commit here: \`git add <paths> && git commit -m \"$TICKET_ID: <what>\"\` —
  small commits, named paths, never \`git add -A\`. Never merge, rebase, push,
  create a pull request or switch branches."
fi
if [ "$WRITE" = 1 ]; then
  KIND="delegate"
  { cat <<EOF
You are a delegated implementer working under the pf-do contract. Your
working directory is an isolated git worktree — $DWT, branch $DBRANCH,
base $BASE — and it is the only place you may write. Rules:

- Do exactly the ticket's «Задача», within its «Ограничения»; nothing beyond.
- Edit only files under the working directory. Never touch the ticket file or
  anything outside the worktree: the launcher compares the main tree before
  and after your run and FAILS the run if any path there moved.
- Verify every item of «Критерии приёмки» with a fresh command and keep its
  output for the report.
$COMMIT_RULE
- No network, no installs, no secrets: do not read or print credentials.
- Pre-approved commands: your file tools, \`git add\`, \`git commit\`,
  \`git status/log/diff/show/rev-parse\`, \`bash <script>\`, \`sh\`, \`cd\`.
  Anything else is refused and ENDS the run — use your file tools to read.
- Finish with a section headed «Результат» in your final message: what was
  done, commit hashes, deviations from the ticket, and the verification
  output per criterion. The launcher stores that message in the report; a
  Claude reviewer judges the diff — you do not decide "done".
EOF
    if [ "$AUDIT" = 1 ]; then cat <<EOF

This run is an AUDIT under the project's audit contract (rules §12):
- The claim (§8) is held by the launcher and the human — do not write to any
  claims file, and do not touch the main checkout's journal.
- BEFORE reporting, read the closed task packets (.agents/runtime/tasks/,
  status done / cancelled) and the recent journal (.agents/journal/): a
  finding already closed there is NOT a new finding — cite the packet instead.
- Write your findings as files under this worktree and your journal entry
  (§10: «## HH:MM · audit · ${TICKET_ID}», Что / Почему / Как / Итог) to
  .agents/journal/$TODAY.md INSIDE this worktree; commit both with named paths.
- Leave the worktree CLEAN (everything committed): the launcher removes it
  after your report and keeps the branch $DBRANCH as the deliverable; an
  uncommitted file blocks the removal and is escalated to the human.
EOF
    fi
    cat <<EOF

--- PROJECT RULES (AGENTS.md) ---
EOF
    if [ -r "$ROOT/AGENTS.md" ]; then cat "$ROOT/AGENTS.md"; else echo "(no AGENTS.md at $ROOT)"; fi
    echo; echo "--- TICKET ($TICKET) ---"
    cat "$TICKET"
  } > "$PROMPT_FILE"
elif [ "$MODE" = run ]; then
  KIND="run-reviewer"
  { cat <<EOF
You are an independent reviewer of a task packet, and you are READ-ONLY.
Your working directory is $WORKDIR (branch $DBRANCH, head $BASE). Rules:

- Do not create, edit, move or delete any file, do not commit and do not
  switch branches: the launcher compares the trees before and after your run
  and FAILS it if anything moved. Read files and run read-only commands
  (git log / diff / show; the ticket's check commands where your sandbox
  lets them run) — say which checks you could not run.
- The work under review: the commits the ticket's «Результат» names, else
  this branch's commits that its base branch does not have.
- Check every item of «Критерии приёмки» against fresh evidence. Claims in
  «Результат» are material, not proof.
- No network, no installs, no secrets: do not read or print credentials.
- The launcher stores your final message in the ticket's «Ревью» section.
  Answer in EXACTLY this form:

## Verdict
One line: APPROVE (the packet may become done) or RETURN (it goes back) — and why.

## Criteria
One line per acceptance criterion: met / not met / not checked — the evidence.

## Findings
"- [P1|P2|P3] title — file:lines" and an indented explanation; "- none" when none.

--- PROJECT RULES (AGENTS.md) ---
EOF
    if [ -r "$ROOT/AGENTS.md" ]; then cat "$ROOT/AGENTS.md"; else echo "(no AGENTS.md at $ROOT)"; fi
    echo; echo "--- TICKET ($TICKET) ---"
    cat "$TICKET"
  } > "$PROMPT_FILE"
elif [ "$MODE" = ask ]; then
  KIND="ask"
  { cat <<'EOF'
Another agent asks you one question. You see only this message and the
working directory; you may read files there, but do not create, edit or
delete anything and do not run commands that change state. Answer directly
and briefly, and say which parts are evidence and which are assumptions.

--- QUESTION AND MATERIAL ---
EOF
    if [ -n "$QFILE" ]; then cat "$QFILE"; else printf '%s\n' "$QUESTION"; fi
  } > "$PROMPT_FILE"
elif [ -n "$DIFF_FILE" ]; then
  KIND="review"
  if [ -n "$COMMIT" ]; then TREE_LINE="the working directory is the tree it belongs to"; else TREE_LINE="no tree is provided — judge the diff text alone"; fi
  { cat <<EOF
You are an independent code reviewer. The change under review is the diff at
the end of this message; $TREE_LINE. Do
not run commands or edit anything — read, then answer in EXACTLY this form:

## Verdict
One line: APPROVE, APPROVE WITH NOTES, or REQUEST CHANGES — and why in one sentence.

## Findings
One bullet per problem: "- [P1|P2|P3] title — file:lines" followed by an
indented explanation. P1 = breaks or endangers something, P2 = real defect,
P3 = worth fixing. Anchor every finding to a place in the diff; when the
problem is what the diff does NOT contain, name where it should have been.
Write "- none" when you found nothing.

## Checked and not found
What you looked for and did not find (so the reader knows what was covered).

--- DIFF ---
EOF
    cat "$DIFF_FILE"
  } > "$PROMPT_FILE"
else
  KIND="consult"
  { cat <<'EOF'
You are a consulting second opinion for an engineer who is mid-task. You see
only this message. Do not run commands or edit anything. Answer in EXACTLY
this form, briefly:

## Question
Restate the single decision in one line.

## Options
Two or three named options (A, B, C): one line each — what it is, its main
risk or cost.

## Proven vs assumed
Which parts of the material below are evidence (quoted output, file
contents) and which are the asker's assumptions.

## Recommendation
One option and the one reason that decides it.

--- MATERIAL ---
EOF
    if [ -n "$QFILE" ]; then cat "$QFILE"; else printf '%s\n' "$QUESTION"; fi
  } > "$PROMPT_FILE"
fi
PROMPT_BYTES="$(wc -c < "$PROMPT_FILE" | tr -d ' ')"
# agy takes the prompt on argv; stay well under ARG_MAX (macOS: 1 MiB).
[ "$PROMPT_BYTES" -le 400000 ] || fail "prompt is ${PROMPT_BYTES} bytes — too large for one helper call; split the material"

# --- Helpers -----------------------------------------------------------------
# Portable watchdog (macOS has no timeout(1)): the command gets its own process
# group so a stuck grandchild dies with it. Returns 124 on timeout.
with_timeout() {
  local secs="$1"; shift
  local cmd_pid killer_pid rc
  set -m 2>/dev/null || true
  # Under set -m a non-interactive bash may lose the setpgid race with its own
  # child and print «child setpgid (N to N): Operation not permitted» (macOS
  # bash 3.2, QA 2.1.0 W1). The fork happens with stderr on /dev/null (the
  # brace-group redirection), the command gets the real stderr back via fd 8.
  # A caller that closed stderr (2>&-) would make 8>&2 fail and skip the whole
  # group, so the helper never ran: put /dev/null on fd 2 first.
  : >&2 2>/dev/null || exec 2>/dev/null
  { "$@" 2>&8 8>&- & cmd_pid=$!; } 8>&2 2>/dev/null
  { ( sleep "$secs"; kill -0 "$cmd_pid" 2>/dev/null || exit 0
    echo timeout > "$TMPS/timeout.$cmd_pid"
    # Kill the group only when the child really leads its own (set -m took);
    # otherwise -$cmd_pid would be THIS script's group, i.e. the whole council.
    t="$cmd_pid"; [ "$(ps -o pgid= -p "$cmd_pid" 2>/dev/null | tr -d ' ')" = "$cmd_pid" ] && t="-$cmd_pid"
    kill -TERM -- "$t" 2>/dev/null; sleep 3; kill -KILL -- "$t" 2>/dev/null ) & killer_pid=$!; } 2>/dev/null
  set +m 2>/dev/null || true
  { wait "$cmd_pid"; } 2>/dev/null; rc=$?
  { kill -KILL -- "-$killer_pid"; wait "$killer_pid"; } 2>/dev/null
  [ -f "$TMPS/timeout.$cmd_pid" ] && return 124
  return "$rc"
}

# shq <arg> — one argv word for a DRY-RUN line: plain when safe, else quoted;
# a prompt (long or multi-line) is shown by its size, never printed.
shq() {
  local a="$1" pre=""
  case "$a" in --print=*) pre="--print="; a="${a#--print=}" ;; esac
  case "$a" in *"
"*) printf '%s<prompt: %s bytes>' "$pre" "$(printf '%s' "$a" | wc -c | tr -d ' ')"; return ;; esac
  if [ "${#a}" -gt 200 ]; then printf '%s<prompt: %s bytes>' "$pre" "$(printf '%s' "$a" | wc -c | tr -d ' ')"; return; fi
  case "$a" in ''|*[!A-Za-z0-9_./:=@,+%-]*) printf "%s'%s'" "$pre" "$(printf '%s' "$a" | sed "s/'/'\\\\''/g")" ;; *) printf '%s%s' "$pre" "$a" ;; esac
}
cd_wd() { [ "$DRY" = 1 ] || cd "$WORKDIR" || return 1; }
xc() {
  if [ "$DRY" = 1 ]; then
    local w o; o="DRY-RUN: cd $(shq "$WORKDIR") &&"
    for w in "$@"; do o="$o $(shq "$w")"; done
    printf '%s\n' "$o"
  else
    "$@"
  fi
}

# One helper's command line each; the read-only flags are spelled here, once.
# agy has no prompt-file flag and swallows a flag placed after --print, so it
# gets the prompt on argv (--print=…): bounded by the 400 kB check above and
# visible in `ps` for the seconds it runs — a known limitation. grok reads a
# file; codex reads stdin (`-`).
# xc / cd_wd: every line below runs through them, so --dry-run prints the very
# argv a real run would start (DRY-RUN: cd <dir> && <argv>) instead of a
# hand-written copy that could drift. MODEL_ARGS (--model <name>) is empty
# outside run / ask, so the council and delegate lines are what they were.
# claude (run / ask only) reads the prompt on stdin; CLAUDECODE is unset for
# the child so a launch from inside a Claude Code session is not refused as
# nested — that is not a permission flag.
run_agy()   { ( cd_wd && xc agy --print="$(cat "$PROMPT_FILE")" --mode plan --sandbox "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" --output-format json ) </dev/null >"$RAW" 2>"$ERR"; }
run_grok()  { xc grok --prompt-file "$PROMPT_FILE" --cwd "$WORKDIR" --permission-mode plan --disable-web-search --no-subagents --max-turns 3 "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" --output-format json </dev/null >"$RAW" 2>"$ERR"; }
run_codex() { ( cd_wd && xc codex exec --skip-git-repo-check --sandbox read-only --ephemeral --json -o "$LAST" "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" - ) <"$PROMPT_FILE" >"$RAW" 2>"$ERR"; }
run_claude() { ( cd_wd && unset CLAUDECODE && xc claude -p --no-session-persistence --permission-mode plan "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" --output-format json ) <"$PROMPT_FILE" >"$RAW" 2>"$ERR"; }
# delegate: the same CLIs in their edit modes, cwd = the delegate worktree.
# agy has no cwd flag (process cwd) and no network flag; its --sandbox stays
# on. grok gets --cwd; --disable-web-search covers its web tools only. codex
# is told -C <worktree> and workspace-write with network off explicitly.
# None of the bypass flags (header) — a helper that cannot do the work inside
# its sandbox reports so, and the gate sees it in the report.
run_agy_delegate()   { ( cd_wd && xc agy --print="$(cat "$PROMPT_FILE")" --mode accept-edits --sandbox --print-timeout "${TIMEOUT}s" "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" --output-format json ) </dev/null >"$RAW" 2>"$ERR"; }
# grok headless: acceptEdits alone still prompts for edits in an untrusted
# directory (and a prompt nobody answers is "cancelled" — the run is lost),
# so the allowlist names what an implementer needs: its file tools, git
# add/commit and the read-only git it cites as evidence (status, log, diff,
# show, rev-parse), running scripts (tests) and cd (rules match the command's
# first word; a `cd x && bash t.sh` is otherwise refused). Anything else
# prompts, is cancelled, and the report shows it (drill T-113a: three runs
# lost that way). An allowlist is not a bypass flag; the protection stays
# the worktree plus the outside check, not this list.
run_grok_delegate()  { xc grok --prompt-file "$PROMPT_FILE" --cwd "$WORKDIR" --permission-mode acceptEdits --disable-web-search --no-subagents --allow Edit --allow Write --allow MultiEdit --allow 'Bash(git add:*)' --allow 'Bash(git commit:*)' --allow 'Bash(git status:*)' --allow 'Bash(git log:*)' --allow 'Bash(git diff:*)' --allow 'Bash(git show:*)' --allow 'Bash(git rev-parse:*)' --allow 'Bash(bash:*)' --allow 'Bash(sh:*)' --allow 'Bash(cd:*)' "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" --output-format json </dev/null >"$RAW" 2>"$ERR"; }
run_codex_delegate() { ( cd_wd && xc codex exec --skip-git-repo-check -C "$WORKDIR" --sandbox workspace-write -c sandbox_workspace_write.network_access=false --ephemeral --json -o "$LAST" "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" - ) <"$PROMPT_FILE" >"$RAW" 2>"$ERR"; }
# claude executor (run only): edits are accepted inside its cwd (the
# worktree), anything that would prompt is denied (--permission-prompts none
# denies, it does not approve), and the allowlist is the implementer's
# commands, as for grok above. Protection stays the worktree plus the
# outside check — `Bash(bash:*)` lets a script reach the network, exactly as
# for grok; only codex's sandbox turns the network off (known limitation).
run_claude_delegate() { ( cd_wd && unset CLAUDECODE && xc claude -p --no-session-persistence --permission-mode acceptEdits --permission-prompts none --allowedTools Read Grep Glob Edit Write MultiEdit 'Bash(git add:*)' 'Bash(git commit:*)' 'Bash(git status:*)' 'Bash(git log:*)' 'Bash(git diff:*)' 'Bash(git show:*)' 'Bash(git rev-parse:*)' 'Bash(bash:*)' 'Bash(sh:*)' 'Bash(cd:*)' "${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}" --output-format json ) <"$PROMPT_FILE" >"$RAW" 2>"$ERR"; }
# review --commit goes through codex-review.sh (the sandboxed Codex reviewer
# with its own 540s watchdog, so it is not wrapped in ours). Never --yes:
# consent to spend Codex is per project and separate (canon §12) — it lives
# in .agents/codex-review.json, and council.json listing codex does not stand
# in for it. Gate below (codex_consented) applies to every codex mode.
run_codex_review() {
  ( cd "$ROOT" && bash "$CODEX_REVIEW" --commit "$COMMIT" ) </dev/null >"$RAW" 2>"$ERR"
}
codex_consented() {
  [ -r "$ROOT/.agents/codex-review.json" ] && json_is_true "$ROOT/.agents/codex-review.json" enabled
}

# Refusal texts, matched case-insensitively over the CLI's stdout+stderr —
# and only after a run that produced no parsable answer (see ask). Codex:
# "You've hit your usage limit"; agy/grok: their help texts name no wording,
# so these are the usual API phrasings, not live-verified (ticket T-112).
# TWINS of codex-review.sh's QUOTA_RE= / LOGIN_RE= lines (T-127): tests/council.sh
# and drift-check level 3 (twin-pairs.txt) go red when they differ — edit both.
QUOTA_RE='usage limit|rate limit|quota|resource_exhausted|too many requests|(^|[^0-9])429([^0-9]|$)|limit reached|exceeded your|out of credits|insufficient (credits|balance|funds)'
LOGIN_RE='not logged in|not authenticated|unauthenticated|unauthorized|(^|[^0-9])401([^0-9]|$)|login required|please (log ?in|sign in|authenticate)|run [^ ]*login|invalid (api key|token)|no credentials|credentials? (missing|expired)|token expired'
# run / ask only: a model the CLI does not know (or this account cannot use)
# is a refusal like quota — nothing ran, the fallback may try. Read only on a
# failed run, after the quota and login patterns.
MODEL_RE='unknown model|invalid model|unsupported model|no such model|model_not_found|model[^.]{0,60}(not found|not supported|is not available|does not exist|may not exist|unavailable)'
# (codex --json wraps the refusal as {"type":"error","message":"..."} — unwrapped here.)
first_match() { cat "$RAW" "$ERR" 2>/dev/null | grep -iE -m1 "$1" | tr -d '\r' | sed -E 's/^[[:space:]]*//; s/^\{"type":"error","message":"(.*)"\}$/\1/' | cut -c1-200; }

# delegate_classify / delegate_report — called from ask (they read and set
# its locals: rc, text, outside, commits, porcelain, kind, state, answer).
# OK needs: the CLI exited 0, the main tree(s) did not move, and the worktree
# holds at least one commit or uncommitted change. A clean run that changed
# nothing is an empty response.
# delegate only: the script never commits for the helper — uncommitted
# work is OK with a NOTE, so the gate sees the non-compliance.
# run --role executor: the launcher commits (run_commit)
# after the git guard, the ledger check and the secret scan.
# Every outcome but "not started" gets the report; FAIL lines name it.
# git_guard_paths <worktree> — BEFORE the agent runs (git is still trusted):
# the common and the per-worktree git directories, into GUARD_CDIR/GUARD_GDIR.
# git_guard — one line per file through which git runs code or changes how it
# runs: the repository's config, the worktree's config.worktree, its
# commondir and gitdir files (which config and objects git reads), the
# worktree's `.git` pointer file, every entry of the common hooks directory
# (path, symlink target, cksum) — plus the secret scan's own inputs in the
# worktree: the false-positive ledger and .gitignore (the scanner reads the
# ledger from disk, so an ignored ledger created by the agent would silence
# its own finding; T-171 gate 3) — and the common info/exclude, which hides
# files from `git add -A` just like .gitignore (the launcher writes its own
# lines there BEFORE the "before" snapshot, Ж-7). A file absent before and after compares equal. It calls NO git: it runs right after the
# agent exits and before any git command, because a planted core.fsmonitor /
# diff.external / pointer would run on the first `git status` or `git diff`.
# Not covered: a filter/diff driver defined in the GLOBAL git config and
# switched on by a .gitattributes in the worktree (none is defined today).
git_guard_paths() {
  GUARD_CDIR="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  GUARD_GDIR="$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
}
git_guard() {
  local f
  printf 'dirs\t%s %s\n' "$GUARD_CDIR" "$GUARD_GDIR"
  for f in "$GUARD_CDIR/config" "$GUARD_CDIR/info/exclude" "$GUARD_GDIR/config.worktree" "$GUARD_GDIR/commondir" "$GUARD_GDIR/gitdir" "$1/.git" \
           "$1/.agents/security/false-positives.yaml" "$1/.gitignore" "$GUARD_CDIR"/hooks/* "$GUARD_CDIR"/hooks/.[!.]*; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    if [ -f "$f" ]; then printf '%s\t%s\t%s\n' "$f" "$(readlink "$f" 2>/dev/null)" "$(cksum < "$f" 2>/dev/null)"
    else printf '%s\t%s\tdir\n' "$f" "$(readlink "$f" 2>/dev/null)"; fi
  done
}
# secret_scanner — the path of the secret scanner run_commit runs (T-187),
# first match wins: PF_SECRET_SCAN when set (final: a set but missing one is
# the FAIL, no fallback); the canon's ${PF_TOOLS:-$HOME/ai/_tools}/security/
# repo-hooks/pre-commit when executable; the copy the pf-workflow distribution
# ships next to this script (secret-scan/repo-hooks/pre-commit — sync-from-
# tools.sh puts it there, the canon keeps no second copy). None of them →
# the canon path is printed and run_commit reports it unavailable.
secret_scanner() {
  local canon="${PF_TOOLS:-$HOME/ai/_tools}/security/repo-hooks/pre-commit"
  local bundled="$SCRIPT_DIR/secret-scan/repo-hooks/pre-commit"
  if [ -n "${PF_SECRET_SCAN:-}" ]; then printf '%s\n' "$PF_SECRET_SCAN"
  elif [ -x "$canon" ]; then printf '%s\n' "$canon"
  elif [ -x "$bundled" ]; then printf '%s\n' "$bundled"
  else printf '%s or %s\n' "$canon" "$bundled"; fi
}
# msg_scan <helper> — run only (QA 11.10, Ж-6): the agent's final message is
# written into the tracked ticket (write_packet), so it passes the same
# secret scanner as the launcher's commit FIRST. The text is staged in a
# throwaway repository under $TMPS (never the project's) and the scanner runs
# on that index. 0 — clean; 1 — a finding (the scanner names
# final-message.md); 2 — no scanner, or it could not check. 1 and 2 both
# keep the text out of the ticket and the report, and the run is a FAIL —
# "could not check" is never "clean" (canon §11).
# text_scan <name> <file> — the same check for any text this script is about
# to write into the tracked ticket (write_packet scans its whole block: the
# state lines quote the CLI's last output line, which the agent controls —
# fix round 1, 🟡-1). msg_scan is text_scan on the final message.
text_scan() {
  local scan d="$TMPS/msgscan-$1"
  scan="$(secret_scanner)"
  [ -x "$scan" ] || return 2
  rm -rf "$d" && mkdir -p "$d" || return 2
  git -C "$d" init -q >/dev/null 2>&1 || return 2
  cp "$2" "$d/final-message.md" 2>/dev/null || return 2
  git -C "$d" -c core.hooksPath=/dev/null add final-message.md >/dev/null 2>&1 || return 2
  ( cd "$d" && "$scan" ) > "$d.out" 2>&1 && return 0
  grep -q 'final-message\.md:' "$d.out" 2>/dev/null && return 1
  return 2
}
msg_scan() { printf '%s\n' "$text" > "$TMPS/msgtext-$1" && text_scan "$1" "$TMPS/msgtext-$1"; }
# gitleaks_hint — what to install when the scanner could not check (QA 12.10,
# Н-3): the scanner runs `gitleaks git`, a command gitleaks has since 8.19;
# Ubuntu 24.04's apt ships 8.16, which lacks it. A gitleaks without that
# command is named as too old — the "install gitleaks" advice would send the
# user back to the same package.
GL_HINT="нужен gitleaks ≥ 8.19 (команда \`gitleaks git\`): macOS — brew install gitleaks; Ubuntu/Debian — бинарник с GitHub Releases (apt даёт старую 8.16)"
gitleaks_old() { command -v gitleaks >/dev/null 2>&1 && ! gitleaks git --help </dev/null >/dev/null 2>&1; }
gitleaks_hint() {
  if gitleaks_old; then echo "gitleaks на этой машине слишком старый — нет команды \`gitleaks git\`; $GL_HINT"
  else echo "$GL_HINT"; fi
}
# scan_head <1|2> — the FAIL wording: a finding, or a scan that could not run.
scan_head() { if [ "$1" = 1 ]; then echo "failed the secret scan"; else echo "could not be secret-scanned (scanner unavailable or gitleaks too old)"; fi; }
msg_leak_line() {  # the ticket's line for MSG_LEAK 1 / 2
  if [ "$1" = 1 ]; then echo "ответ не записан: секрет-скан нашёл совпадение"
  else echo "ответ не записан: секрет-скан не смог проверить ответ ($(secret_scanner)) — $(gitleaks_hint)"; fi
}
# run_commit — run --role executor, the agent exited 0 and the worktree
# moved: the LAUNCHER commits, never the agent (T-171: codex's sandbox cannot
# write <repo>/.git, and an agent that may write .git may plant a hook). A
# commit of the agent's own (HEAD moved) fails the run; the commit runs with
# core.hooksPath=/dev/null, so no hook of the repository runs either.
run_commit() {
  local msg sha scan
  if [ -n "$commits" ]; then
    kind=error; state="FAIL: $h committed by itself ($(printf '%s\n' "$commits" | grep -c .) commit(s) on $DBRANCH) — commits are the launcher's; nothing committed; report: $answer"
    return
  fi
  msg="$TICKET_ID: ${TICKET_TITLE:-council run} (council run $h/${MODEL:-default})"
  # Any refusal below leaves the agent's files in the worktree: no fallback
  # agent may start on that tree (a leaked secret would ride along).
  DELEGATE_TREE_MOVED=1
  if ! git -C "$DWT" -c core.hooksPath=/dev/null add -A >/dev/null 2>"$TMPS/commit.err"; then
    git -C "$DWT" reset -q 2>/dev/null
    kind=error; state="FAIL: $h launcher commit failed (git add: $(grep -v '^[[:space:]]*$' "$TMPS/commit.err" | tail -1 | cut -c1-160)); report: $answer"; return
  fi
  # The false-positive ledger of the secret scan is the human's (canon §5):
  # an agent that edits it could silence its own finding.
  if git -C "$DWT" diff --cached --name-only 2>/dev/null | grep -qx '\.agents/security/false-positives\.yaml'; then
    git -C "$DWT" reset -q 2>/dev/null
    kind=error; state="FAIL: $h edited .agents/security/false-positives.yaml (the scan's ledger is the human's) — nothing committed; report: $answer"; return
  fi
  # The repository's hooks are off for this commit (core.hooksPath=/dev/null),
  # and a merge commit runs no pre-commit either — so the canon's secret
  # scanner runs here, explicitly, on the worktree's index. Missing, crashed
  # or red → FAIL, nothing committed (canon §5, §11: never a quiet skip).
  # Which scanner: secret_scanner (above — the same choice --dry-run prints).
  scan="$(secret_scanner)"
  if [ ! -x "$scan" ]; then
    git -C "$DWT" reset -q 2>/dev/null
    kind=error; state="FAIL: $h secret scan unavailable ($scan) — nothing committed; report: $answer"; return
  fi
  # Ж-6: the final message failed its scan (msg_scan, in ask) — it would land
  # in the tracked ticket; nothing is committed, the work stays in $DWT.
  if [ "$MSG_LEAK" != 0 ]; then
    git -C "$DWT" reset -q 2>/dev/null
    kind=error; state="FAIL: $h final message $(scan_head "$MSG_LEAK") — $(msg_leak_line "$MSG_LEAK"); nothing committed, the work stays uncommitted in $DWT; report: $answer"; return
  fi
  if ! ( cd "$DWT" && "$scan" ) >"$TMPS/scan.out" 2>&1; then
    git -C "$DWT" reset -q 2>/dev/null
    if gitleaks_old; then kind=error; state="FAIL: $h secret scan could not run — $(gitleaks_hint); nothing committed; report: $answer"; return; fi
    kind=error; state="FAIL: $h secret scan failed — nothing committed ($( { grep -m1 'НЕ пройден' "$TMPS/scan.out" || grep -v '^[[:space:]]*$' "$TMPS/scan.out" | tail -1; } | sed 's/\. обход.*//' | cut -c1-160)); report: $answer"; return
  fi
  if git -C "$DWT" -c core.hooksPath=/dev/null commit -q -m "$msg" >/dev/null 2>>"$TMPS/commit.err"; then
    sha="$(git -C "$DWT" rev-parse --short HEAD 2>/dev/null)"
    commits="$(git -C "$DWT" log --oneline "$BASE..HEAD" 2>/dev/null)"; porcelain="$(git -C "$DWT" status --porcelain 2>/dev/null)"
    kind=ok; state="OK: $h $answer
commit: $sha $msg"
  else
    git -C "$DWT" reset -q 2>/dev/null
    kind=error; state="FAIL: $h launcher commit failed ($(grep -v '^[[:space:]]*$' "$TMPS/commit.err" | tail -1 | cut -c1-160)); the work stays uncommitted in $DWT; report: $answer"
  fi
}
delegate_classify() {
  local nout npor denied
  nout="$(printf '%s\n' "$outside" | grep -c . )"; npor="$(printf '%s\n' "$porcelain" | grep -c .)"
  if [ "$rc" = 124 ]; then
    kind=timeout; state="FAIL: $h timeout (${TIMEOUT}s; whatever it did stays in $DWT; report: $answer)"
  elif [ "$GUARD_TRIPPED" = 1 ]; then
    # .git/config or .git/hooks moved: whatever git runs next may be the
    # agent's code. Nothing is committed, and no fallback runs on this tree.
    kind=error; state="FAIL: $h changed git control files (.git/config, hooks, worktree pointers) or the scan's ledger / .gitignore — nothing committed, no git run after the agent; do not run git in this repository until a human has checked them ($(diff "$TMPS/$h.guard.before" "$TMPS/$h.guard.after" 2>/dev/null | grep -E '^[<>]' | sed 's/^[<>] //' | cut -f1 | LC_ALL=C sort -u | head -3 | tr '\n' ';' | sed 's/;$//' | cut -c1-160); report: $answer)"
    DELEGATE_TREE_MOVED=1
  elif [ -n "$outside" ]; then
    kind=error; state="FAIL: $h touched files outside worktree ($nout path(s): $(printf '%s\n' "$outside" | head -3 | tr '\n' ';' | sed 's/;$//' | cut -c1-160); report: $answer)"
  elif [ -n "$commits" ] || [ -n "$porcelain" ]; then
    # The tree moved: this helper's work, whatever its exit — a quota or
    # login text on a non-zero exit AFTER edits is still work to keep and
    # to gate, never a refusal to fall through from.
    if [ "$rc" = 0 ] && [ "$MODE" = run ]; then
      run_commit
    elif [ "$rc" = 0 ]; then
      kind=ok; state="OK: $h $answer"
      [ -z "$porcelain" ] || state="$state
NOTE: $npor path(s) left uncommitted in $DWT — the helper did not commit them; see the report"
    else
      kind=error; state="FAIL: $h error (rc=$rc after changing the worktree — its work is kept there; подробности: $answer)"
    fi
  elif [ -n "$(first_match "$QUOTA_RE")" ]; then
    kind=quota; state="FAIL: $h quota ($(first_match "$QUOTA_RE"))"
  elif [ -n "$(first_match "$LOGIN_RE")" ]; then
    kind=login; state="FAIL: $h not logged in ($(first_match "$LOGIN_RE"))"
  elif [ "$MODE" = run ] && [ -n "$(first_match "$MODEL_RE")" ]; then
    kind=model; state="FAIL: $h unknown model ($(first_match "$MODEL_RE"))"
  elif [ "$rc" = 0 ]; then
    # agy reports tools its permission mode refused as "denied_actions" —
    # the usual reason a headless run changes nothing; name it, do not bypass it.
    denied="$(grep -o '"denied_actions":\[[^]]*\]' "$RAW" 2>/dev/null | head -1 | cut -c1-120)"
    kind=error; state="FAIL: $h error (rc=0 but no changes in worktree — nothing to review${denied:+; $denied}; report: $answer)"
    [ "$MODE" != run ] || state="$state
нет изменений — коммита нет"
  else
    kind=error; state="FAIL: $h error (rc=$rc; подробности: $answer)"
  fi
  case "$kind" in ok|timeout|error) DELEGATE_RAN=1 ;; esac   # the CLI worked here: keep the worktree
  # Fallback stops only when the tree moved (or a timeout may have moved it
  # unseen): a helper that changed nothing — agy denying its own shell, a
  # crash before the first edit — leaves the base intact for the next name.
  if [ -n "$commits" ] || [ -n "$porcelain" ] || [ -n "$outside" ] || [ "$kind" = timeout ]; then DELEGATE_TREE_MOVED=1; DELEGATE_RAN=1; fi
}
delegate_report() {
  { echo "Council answer — material, not a verdict; verify before acting"
    echo
    echo "- helper: $h · mode: $MODE_LABEL · date: $(date '+%Y-%m-%d %H:%M') · tokens in/out: $in/$out · cost: $cost"
    echo "- ticket: $TICKET"
    echo "- worktree: $DWT · branch: $DBRANCH · base: $BASE · head: $( [ "$GUARD_TRIPPED" = 1 ] && echo 'not read (git guard tripped)' || git -C "$DWT" rev-parse HEAD 2>/dev/null)"
    echo "- helper exit: rc=$rc · class: $kind"
    if [ -n "$outside" ]; then echo "- main tree check: CHANGED — paths moved outside the worktree (below)"; else echo "- main tree check: clean ($REPO$([ "$ROOT" = "$REPO" ] || echo ", $ROOT"))"; fi
    echo
    echo "## Commits (git log --oneline $BASE..HEAD)"
    echo; if [ -n "$commits" ]; then printf '%s\n' "$commits"; else echo "(none)"; fi; echo
    echo "## Worktree status (git status --porcelain)"
    echo; if [ -n "$porcelain" ]; then printf '%s\n' "$porcelain"; else echo "(clean)"; fi; echo
    echo "## Files changed outside the worktree (main tree before vs after)"
    echo; if [ -n "$outside" ]; then printf '%s\n' "$outside"; else echo "(none)"; fi; echo
    echo "## Helper's final message"
    if [ "${MSG_LEAK:-0}" != 0 ]; then echo; msg_leak_line "$MSG_LEAK"; echo
      echo "## Raw CLI output (stdout, then stderr)"; echo; echo "(not kept: it carries the same final message)"; echo
    else
    echo; if [ -n "$text" ]; then printf '%s\n' "$text"; else echo "(no final message)"; fi; echo
    # Always — the gate reads denied actions and stop reasons here, OK or not.
    echo "## Raw CLI output (stdout, then stderr)"; echo; cat "$RAW" "$ERR" 2>/dev/null; echo
    fi
  } > "$answer" 2>/dev/null || { echo "FAIL: $h error (cannot write $answer)"; return 1; }
}

# ask <helper> — runs one helper on $PROMPT_FILE, prints its state line,
# appends the ledger row when the call could have cost (OK, timeout, error —
# the CLI ran; not quota / not-logged-in — the provider refused). Returns 0
# only on OK.
# available <helper> — known, enabled in council.json, on PATH; else prints
# the SKIP line and returns 1.
# A SKIP is an outcome too: it gets its ledger row (outcome SKIP, no cap
# slot) and its token in the chain, so --stats can say how often a helper
# was simply not there.
CHAIN=""
skip_helper() { echo "SKIP: $1 $2"; ledger_row "$1" - - - - SKIP; CHAIN="$CHAIN $1:SKIP"; LAST_KIND=skip; LAST_REASON="$2"; return 1; }
# agent_unready <agent> — run / ask: why this agent cannot be asked here
# (nothing printed = it can). Used by available() and by --dry-run, which
# must not write the SKIP ledger row.
agent_unready() {
  case " $KNOWN_AGENTS " in *" $1 "*) : ;; *) echo "unknown agent (council.json roles?) — not one of $KNOWN_AGENTS"; return ;; esac
  if json_is_false "$CFG" "available.$1"; then echo "unavailable per council.json available (checked $(json_field "$CFG" available.checked)) — re-run council.sh check"; return; fi
  command -v "$1" >/dev/null 2>&1 || { echo "not installed"; return; }
  [ "$1" != codex ] || codex_consented || echo "not consented (.agents/codex-review.json with \"enabled\": true is Codex's own consent, canon §12 — ask the human once)"
}
available() {
  if [ "$MODE" = run ] || [ "$MODE" = ask ]; then
    local why; why="$(agent_unready "$1")"
    [ -z "$why" ] || { skip_helper "$1" "$why"; return 1; }
    return 0
  fi
  case " $KNOWN_HELPERS " in *" $1 "*) : ;; *) skip_helper "$1" "unknown backend (typo in council.json backends?)"; return 1 ;; esac
  case " $ENABLED_HELPERS " in *" $1 "*) : ;; *) skip_helper "$1" "not enabled (.agents/council.json backends)"; return 1 ;; esac
  command -v "$1" >/dev/null 2>&1 || { skip_helper "$1" "not installed"; return 1; }
  [ "$1" != codex ] || codex_consented || { skip_helper codex "not consented (.agents/codex-review.json with \"enabled\": true is Codex's own consent, canon §12 — ask the human once)"; return 1; }
  :
}
ask() {
  local h="$1" rc via_cr=0 text="" in="-" out="-" cost="-" n answer state material kind outcome token
  local outside="" commits="" porcelain="" stem head_before head_after root_head_before root_head_after fn wt_moved="" wt_head_before wt_head_after
  RAW="$TMPS/$h.raw"; ERR="$TMPS/$h.err"; LAST="$TMPS/$h.last"; : > "$RAW"; : > "$ERR"
  available "$h" || return 1
  [ "$MODE" = parallel ] || cap_check || { CHAIN="$CHAIN $h:CAP"; return 1; }   # parallel: checked by the launcher
  if [ "$h" = codex ] && [ "$KIND" = review ] && [ -n "$COMMIT" ]; then
    via_cr=1
    [ -f "$CODEX_REVIEW" ] || { echo "FAIL: codex error (codex-review.sh not found next to council.sh)"; return 1; }
    run_codex_review; rc=$?
    if grep -q '^OK:' "$RAW"; then
      text="$(grep -m1 '^REPORT: ' "$RAW" | sed 's/^REPORT: //; s/ (raw output.*//')"
      if [ -n "$text" ] && [ -r "$text" ]; then text="$(cat "$text")"; else text="$(cat "$RAW")"; fi
      rc=0
    elif grep -q '^SKIP:' "$RAW"; then
      skip_helper codex "$(grep -m1 '^SKIP:' "$RAW" | cut -c7-200)"; return 1
    fi
  else
    if [ "$WRITE" = 1 ] || [ "$MODE" = run ]; then
      # Snapshot the main tree(s) right before the helper starts and right
      # after it stops — before this script writes its own ledger row or
      # report, which would otherwise show up as "the helper moved a file".
      # run --role reviewer is watched the same way, plus the worktree it
      # reads (a nested checkout is one opaque entry in the main status).
      fn="run_${h}_delegate"; [ "$WRITE" = 1 ] || fn="run_$h"
      snapshot "$REPO" > "$TMPS/$h.before.repo"; [ "$ROOT" = "$REPO" ] || snapshot "$ROOT" > "$TMPS/$h.before.root"
      head_before="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"; root_head_before="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
      if [ "$WRITE" = 0 ] && [ -n "$DWT" ]; then snapshot "$DWT" > "$TMPS/$h.before.wt"; wt_head_before="$(git -C "$DWT" rev-parse HEAD 2>/dev/null)"; fi
      if [ "$MODE" = run ] && [ "$WRITE" = 1 ]; then git_guard_paths "$DWT"; git_guard "$DWT" > "$TMPS/$h.guard.before"; fi
      with_timeout "$TIMEOUT" "$fn"; rc=$?
      # FIRST thing after the agent, before any git: the guard. Tripped → no
      # git command runs in this repository again (GUARD_TRIPPED gates them).
      if [ "$MODE" = run ] && [ "$WRITE" = 1 ]; then
        git_guard "$DWT" > "$TMPS/$h.guard.after"
        diff -q "$TMPS/$h.guard.before" "$TMPS/$h.guard.after" >/dev/null 2>&1 || GUARD_TRIPPED=1
      fi
      if [ "$GUARD_TRIPPED" = 1 ]; then :
      else
      if [ "$WRITE" = 0 ] && [ -n "$DWT" ]; then
        snapshot "$DWT" > "$TMPS/$h.after.wt"; wt_head_after="$(git -C "$DWT" rev-parse HEAD 2>/dev/null)"
        wt_moved="$(diff "$TMPS/$h.before.wt" "$TMPS/$h.after.wt" 2>/dev/null | grep -E '^[<>]' | sed 's/^[<>] /worktree: /; s/ @[0-9a-f]*$//' | LC_ALL=C sort -u)"
        [ "$wt_head_before" = "$wt_head_after" ] || wt_moved="$(printf '%s\n%s' "HEAD of $DWT moved: $wt_head_before -> $wt_head_after" "$wt_moved")"
      fi
      snapshot "$REPO" > "$TMPS/$h.after.repo"; [ "$ROOT" = "$REPO" ] || snapshot "$ROOT" > "$TMPS/$h.after.root"
      # One line per path: the " @<hash>" suffix is dropped and duplicates
      # folded, so an overwritten untracked file counts once, as "?? path".
      outside="$( { diff "$TMPS/$h.before.repo" "$TMPS/$h.after.repo"; [ "$ROOT" = "$REPO" ] || diff "$TMPS/$h.before.root" "$TMPS/$h.after.root"; } 2>/dev/null | grep -E '^[<>]' | sed 's/^[<>] //; s/ @[0-9a-f]*$//' | LC_ALL=C sort -u )"
      # A commit made in the main checkout leaves its status clean — so HEAD is compared too.
      head_after="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"; root_head_after="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
      [ "$head_before" = "$head_after" ] || outside="$(printf '%s\n%s' "HEAD of $REPO moved: $head_before -> $head_after" "$outside")"
      [ "$ROOT" = "$REPO" ] || [ "$root_head_before" = "$root_head_after" ] || outside="$(printf '%s\n%s' "HEAD of $ROOT moved: $root_head_before -> $root_head_after" "$outside")"
      [ -z "$wt_moved" ] || outside="$(printf '%s\n%s' "$wt_moved" "$outside" | grep .)"
      if [ "$WRITE" = 1 ]; then
        commits="$(git -C "$DWT" log --oneline "$BASE..HEAD" 2>/dev/null)"
        porcelain="$(git -C "$DWT" status --porcelain 2>/dev/null)"
      fi
      fi   # GUARD_TRIPPED
    else
      with_timeout "$TIMEOUT" "run_$h"; rc=$?
    fi
    case "$h" in
      agy)  [ "$(json_field "$RAW" status)" = SUCCESS ] && text="$(json_field "$RAW" response)"
            in="$(json_field "$RAW" usage.input_tokens)"; out="$(json_field "$RAW" usage.output_tokens)" ;;
      grok) text="$(json_field "$RAW" text)"
            in="$(json_field "$RAW" usage.input_tokens)"; out="$(json_field "$RAW" usage.output_tokens)"
            cost="$(json_field "$RAW" total_cost_usd)" ;;
      codex) [ -s "$LAST" ] && text="$(cat "$LAST")"
            grep '"turn.completed"' "$RAW" 2>/dev/null | tail -1 > "$TMPS/$h.turn"
            in="$(json_field "$TMPS/$h.turn" usage.input_tokens)"; out="$(json_field "$TMPS/$h.turn" usage.output_tokens)" ;;
      claude) [ "$(json_field "$RAW" is_error)" = true ] || text="$(json_field "$RAW" result)"
            in="$(json_field "$RAW" usage.input_tokens)"; out="$(json_field "$RAW" usage.output_tokens)"
            cost="$(json_field "$RAW" total_cost_usd)" ;;
    esac
  fi
  [ -n "$in" ] || in="-"; [ -n "$out" ] || out="-"; [ -n "$cost" ] || cost="-"
  # Ж-6: before anything is classified, committed or written — the final
  # message of a run goes into the tracked ticket, so it is scanned first.
  MSG_LEAK=0
  if [ "$MODE" = run ] && [ -n "$text" ]; then msg_scan "$h"; MSG_LEAK=$?; fi
  mkdir -p "$ANSWER_DIR" || { echo "FAIL: $h error (cannot create $ANSWER_DIR)"; return 1; }
  [ -f "$ANSWER_DIR/.gitignore" ] || printf '*\n!.gitignore\n' > "$ANSWER_DIR/.gitignore"
  # delegate reports are named by ticket; a repeat run of the same ticket the
  # same day gets -2, -3 … rather than overwriting the first report.
  stem="$ANSWER_DIR/$TODAY-$MODE_LABEL-$h"; case "$MODE" in delegate|run) stem="$stem-$TICKET_ID" ;; esac
  if { [ "$MODE" = delegate ] || [ "$MODE" = run ]; } && [ ! -e "$stem.md" ]; then answer="$stem.md"; else
    n=1; case "$MODE" in delegate|run) n=2 ;; esac
    while [ -e "$stem-$n.md" ] || [ -e "$stem-$n.md.raw" ]; do n=$((n + 1)); done
    answer="$stem-$n.md"
  fi
  if [ "$WRITE" = 1 ]; then material="ticket $TICKET → worktree $DWT (branch $DBRANCH, base $BASE)"
  elif [ "$MODE" = run ]; then material="ticket $TICKET, read-only in $WORKDIR (branch $DBRANCH, head $BASE)"
  elif [ -n "$COMMIT" ]; then material="commit $COMMIT (via codex-review.sh: $via_cr)"
  elif [ -n "$DIFF_FILE" ]; then material="diff $DIFF_FILE"
  elif [ -n "$QFILE" ]; then material="file $QFILE"
  else material="question via -q"; fi
  # Classify. A run that exited 0 with a parsable, non-empty answer is OK
  # whatever words the answer contains; the quota / login patterns are read
  # only on a failed run, so an answer ABOUT quotas is never taken for one.
  # The event class is decided HERE, once, and every later decision (raw file,
  # ledger row, cap slot) reads $kind — never the state text, which quotes the
  # CLI and may itself contain "error" (Gemini's 429 body does).
  if [ "$WRITE" = 1 ]; then
    delegate_classify; delegate_report || return 1
    # --audit: remember the helper that actually worked here (kind ok / error /
    # timeout — a refusal leaves the base intact and gets no journal entry).
    case "$kind" in ok|timeout|error) AUDIT_HELPER="$h"; AUDIT_STATE="$(printf '%s\n' "$state" | head -1)" ;; esac
  elif [ "$rc" = 124 ]; then
    kind=timeout; state="FAIL: $h timeout (${TIMEOUT}s; prompt ${PROMPT_BYTES} bytes — raise --timeout or split the material)"
  elif [ -n "$outside" ]; then
    # run --role reviewer only (outside stays empty elsewhere): any move is a FAIL.
    kind=error; state="FAIL: $h wrote files as a read-only reviewer ($(printf '%s\n' "$outside" | grep -c .) path(s): $(printf '%s\n' "$outside" | head -3 | tr '\n' ';' | sed 's/;$//' | cut -c1-160); raw output kept)"
  elif [ "$MODE" = run ] && [ "$MSG_LEAK" != 0 ]; then
    kind=error; state="FAIL: $h final message $(scan_head "$MSG_LEAK") — $(msg_leak_line "$MSG_LEAK"); the answer is not written"
  elif [ "$rc" = 0 ] && [ -n "$text" ]; then
    kind=ok
    { echo "Council answer — material, not a verdict; verify before acting"
      echo
      echo "- helper: $h · mode: $MODE ($KIND) · date: $(date '+%Y-%m-%d %H:%M') · tokens in/out: $in/$out · cost: $cost"
      echo "- material: $material"
      echo
      echo "---"
      echo
      printf '%s\n' "$text"
    } > "$answer" || { echo "FAIL: $h error (cannot write $answer)"; return 1; }
    state="OK: $h $answer"
  elif [ -n "$(first_match "$QUOTA_RE")" ]; then
    kind=quota; state="FAIL: $h quota ($(first_match "$QUOTA_RE"))"
  elif [ -n "$(first_match "$LOGIN_RE")" ]; then
    kind=login; state="FAIL: $h not logged in ($(first_match "$LOGIN_RE"))"
  elif { [ "$MODE" = run ] || [ "$MODE" = ask ]; } && [ -n "$(first_match "$MODEL_RE")" ]; then
    kind=model; state="FAIL: $h unknown model ($(first_match "$MODEL_RE"))"
  elif [ "$rc" = 0 ]; then
    kind=error; state="FAIL: $h error (rc=0 but empty response — the CLI answered nothing; raw output kept)"
  else
    kind=error; state="FAIL: $h error (rc=$rc; подробности: $answer.raw)"
  fi
  # A run that started but gave no answer keeps its raw output next to where
  # the answer would have been, and that path goes into the ledger. (delegate
  # always has a report at $answer; its raw output is a section inside it.)
  if [ "$WRITE" = 0 ] && [ "$MSG_LEAK" != 0 ]; then answer="$answer.raw"; msg_leak_line "$MSG_LEAK" > "$answer" 2>/dev/null   # Ж-6: raw output not kept
  else [ "$WRITE" = 1 ] || case "$kind" in timeout|error|model) answer="$answer.raw"; cat "$RAW" "$ERR" > "$answer" 2>/dev/null ;; esac; fi
  # Every outcome is a row (outcome column = the class decided above); the
  # cap reads the column and skips quota / login (ledger_today).
  case "$kind" in
    ok) outcome="OK"; token="OK" ;;
    quota) outcome="FAIL:quota"; token="QUOTA"; answer="-" ;;
    login) outcome="FAIL:login"; token="LOGIN"; answer="-" ;;
    timeout) outcome="FAIL:timeout"; token="TIMEOUT" ;;
    model) outcome="FAIL:other"; token="MODEL" ;;
    *) outcome="FAIL:other"; token="ERROR" ;;
  esac
  CHAIN="$CHAIN $h:$token"
  ledger_row "$h" "$in" "$out" "$cost" "$answer" "$outcome" \
    || state="$state
NOTE: ledger row NOT written ($LEDGER) — the daily cap is undercounting; fix the file's permissions"
  echo "$state"
  # run / ask: what the fallback and the packet writer read.
  LAST_KIND="$kind"; LAST_REASON="$(printf '%s\n' "$state" | head -1 | sed 's/^FAIL: [^ ]* //' | cut -c1-160)"
  case "$kind" in ok|error|timeout) RUN_AGENT="$h"; RUN_MODEL="$MODEL"; RUN_STATE="$state"; RUN_TEXT="$text"; RUN_ANSWER="$answer"; RUN_LEAK="$MSG_LEAK"
    [ "$MSG_LEAK" = 0 ] || RUN_TEXT="" ;; esac
  [ "$kind" = ok ]
}

# write_packet — run only, after the loop (so after every snapshot): the
# outcome and the agent's final message, quoted (a "## …" line inside it must
# not open a section of the ticket), go to the end of the ticket's «Результат»
# (executor) or «Ревью» (reviewer) section, which is appended when absent.
# The agent itself never writes the ticket; status stays for the orchestrator.
# The new text goes to a copy beside the ticket (mode kept) and replaces it
# with one mv: an interrupted write never leaves a truncated ticket, and a
# symlink planted at the ticket's path is replaced, not followed.
write_packet() {
  local sec blk="$TMPS/packet.block" new="$TICKET.council.$$"
  if [ "$ROLE" = executor ]; then sec="Результат"; else sec="Ревью"; fi
  { echo "### council run · $ROLE · $RUN_AGENT/${RUN_MODEL:-default} · $(date '+%Y-%m-%d %H:%M')"
    echo
    printf '%s\n' "$RUN_STATE" | sed 's/^/- /'
    echo "- report: $RUN_ANSWER"
    [ -z "$DWT" ] || echo "- worktree: $DWT · branch $DBRANCH · base $BASE · head $( [ "$GUARD_TRIPPED" = 1 ] && echo 'not read (git guard tripped)' || git -C "$DWT" rev-parse HEAD 2>/dev/null)"
    echo "- written by council.sh after the run; the agent's final message, quoted:"
    echo
    if [ "$RUN_LEAK" != 0 ]; then echo "> $(msg_leak_line "$RUN_LEAK")"
    elif [ -n "$RUN_TEXT" ]; then printf '%s\n' "$RUN_TEXT" | sed 's/^/> /; s/^> $/>/'; else echo "> (no final message)"; fi
  } > "$blk"
  # The whole block is scanned before it reaches the tracked ticket: besides
  # the (already scanned) final message, the state lines quote the CLI's last
  # output line on a failure. A finding (or no way to check) — only a neutral
  # block goes in, no quote; the run's exit is a FAIL (fix round 1, 🟡-1).
  text_scan packet "$blk"; local pk=$?
  if [ "$pk" != 0 ]; then
    { echo "### council run · $ROLE · $RUN_AGENT/${RUN_MODEL:-default} · $(date '+%Y-%m-%d %H:%M')"
      echo
      echo "- $(msg_leak_line "$pk") — текст результата (строки состояния и ответ) в тикет не записан; вывод CLI — в отчёте $RUN_ANSWER"
    } > "$blk"
    PACKET_LEAK=1
    echo "FAIL: the text for the ticket $(scan_head "$pk") — only a neutral line was written to «${sec}»"
  fi
  awk -v sec="## $sec" -v blk="$blk" '
    function dump(  l) { while ((getline l < blk) > 0) print l; close(blk) }
    function is_sec(s) { return index(s, sec) == 1 && (length(s) == length(sec) || substr(s, length(sec) + 1, 1) ~ /[ (]/) }
    insec && /^## / { dump(); print ""; insec = 0; done = 1 }
    !done && !insec && is_sec($0) { insec = 1 }
    { print }
    END { if (insec) { print ""; dump(); done = 1 }
          if (!done) { print ""; print sec; print ""; dump() } }' "$TICKET" > "$TMPS/packet.new" 2>/dev/null \
    && cp -p "$TICKET" "$new" 2>/dev/null && cat "$TMPS/packet.new" > "$new" && mv -f "$new" "$TICKET" \
    && echo "packet: «${sec}» updated in $TICKET" \
    || { rm -f "$new"; echo "NOTE: packet NOT updated ($TICKET) — the outcome is in $RUN_ANSWER"; }
}

# --- run / ask --dry-run: the command line, nothing started ------------------
# The first usable candidate (as a real run would pick it; SKIP lines for the
# ones passed over, no ledger row), its argv through the same run_* line.
LAST_KIND=""; LAST_REASON=""; RUN_AGENT=""; RUN_MODEL=""; RUN_STATE=""; RUN_TEXT=""; RUN_ANSWER=""; RUN_LEAK=0; MSG_LEAK=0; PACKET_LEAK=0; MODEL=""
if [ "$DRY" = 1 ]; then
  i=0; pick=""; why=""
  while [ "$i" -lt "${#CAND_A[@]}" ]; do
    r="$(agent_unready "${CAND_A[$i]}")"
    if [ -z "$r" ]; then pick="$i"; break; fi
    echo "SKIP: ${CAND_A[$i]} $r"; why="${CAND_A[$i]}/${CAND_M[$i]:-default}: $r"; i=$((i + 1))
  done
  # No usable candidate: nothing is called at all — not even a run_* line,
  # whose name would otherwise be built from an unchecked roles string.
  if [ -z "$pick" ]; then echo "NOTE: no candidate is usable here — nothing to show; a real run would SKIP them all"; exit 1
  elif [ "$pick" != 0 ]; then echo "запасная: ${CAND_A[$pick]}/${CAND_M[$pick]:-default} ($why)"; fi
  h="${CAND_A[$pick]}"; MODEL="${CAND_M[$pick]}"; MODEL_ARGS=(); [ -z "$MODEL" ] || MODEL_ARGS=(--model "$MODEL")
  RAW="$TMPS/dry.raw"; ERR="$TMPS/dry.err"; LAST="$TMPS/$h.last"
  if [ "$WRITE" = 1 ]; then "run_${h}_delegate"; else "run_$h"; fi
  cat "$RAW"
  # run --role executor: the launcher's commit runs a secret scanner — name it.
  if [ "$MODE" = run ] && [ "$ROLE" = executor ]; then
    scan="$(secret_scanner)"
    if [ -x "$scan" ]; then echo "secret scan: $scan"
    else echo "secret scan: unavailable ($scan) — a real run would FAIL before its commit"; fi
  fi
  exit 0
fi

# --- Run ---------------------------------------------------------------------
# The ledger header is written here, once, by the parent: in parallel two
# helpers would otherwise race on "no file yet" and one would truncate the other.
LEDGER_HEADER="$(printf '# date\thelper\tmode\tinput\toutput\tcost\tanswer\toutcome')"
LEDGER_HEADER_V1="$(printf '# date\thelper\tmode\tinput\toutput\tcost\tanswer')"
if [ ! -f "$LEDGER" ]; then
  mkdir -p "$(dirname "$LEDGER")" && printf '%s\n' "$LEDGER_HEADER" > "$LEDGER" || fail "cannot write $LEDGER"
elif [ "$(head -1 "$LEDGER")" = "$LEDGER_HEADER_V1" ]; then
  # A pre-T-127 ledger: the header gains the outcome column on the first run
  # that writes (rows keep their 7 columns and read as "n/a"). tmp + mv, by
  # the parent only — no in-place edit racing with parallel children.
  { printf '%s\n' "$LEDGER_HEADER"; tail -n +2 "$LEDGER"; } > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER" || fail "cannot update the ledger header of $LEDGER"
fi
ANY_OK=0
if [ "$MODE" = parallel ]; then
  # Every helper at once, each in its own temp namespace; the cap is checked
  # in the parent before each launch (launched rows are not written yet);
  # lines are printed in --order order once all have finished.
  i=0; launched=0
  for h in $HELPERS; do
    i=$((i + 1)); mkdir -p "$TMPS/p$i"
    available "$h" > "$TMPS/p$i/state" || continue          # SKIP takes no cap slot
    cap_check "$launched" > "$TMPS/p$i/state" || continue
    launched=$((launched + 1))
    ( TMPS="$TMPS/p$i"; ask "$h" > "$TMPS/state" ) &
  done
  wait
  i=0
  for h in $HELPERS; do
    i=$((i + 1))
    cat "$TMPS/p$i/state" 2>/dev/null || echo "FAIL: $h error (no state recorded)"
    grep -q '^OK:' "$TMPS/p$i/state" 2>/dev/null && ANY_OK=1
  done
elif [ "$MODE" = run ] || [ "$MODE" = ask ]; then
  # The primary, then the fallback — only after a refusal that left nothing
  # behind (SKIP, quota, login, unknown model); never after a timeout or an
  # error, and never once an executor has moved the worktree.
  i=0; why=""
  while [ "$i" -lt "${#CAND_A[@]}" ]; do
    h="${CAND_A[$i]}"; MODEL="${CAND_M[$i]}"; MODEL_ARGS=(); [ -z "$MODEL" ] || MODEL_ARGS=(--model "$MODEL")
    [ "$i" = 0 ] || echo "запасная: $h/${MODEL:-default} ($why)"
    LAST_KIND=""; LAST_REASON=""
    if ask "$h"; then ANY_OK=1; break; fi
    [ "$WRITE" = 0 ] || [ "$DELEGATE_TREE_MOVED" = 0 ] || break
    case "$LAST_KIND" in skip|quota|login|model) why="$h/${MODEL:-default}: $LAST_REASON" ;; *) break ;; esac
    i=$((i + 1))
  done
  if [ "$(printf '%s' "$CHAIN" | wc -w | tr -d ' ')" -ge 2 ]; then echo "chain:$CHAIN"; fi
  [ "$MODE" != ask ] || [ "$ANY_OK" = 0 ] || printf '\n%s\n' "$RUN_TEXT"
  [ "$MODE" != run ] || [ -z "$RUN_AGENT" ] || write_packet
else
  for h in $HELPERS; do
    if ask "$h"; then ANY_OK=1; break; fi
    # delegate: once a helper has moved the worktree (commit, edit, or a
    # timeout that may have) the tree is no longer the base — the next helper
    # would be credited with its commits. Refusals and runs that changed
    # nothing fall through to the next name in --order.
    if [ "$MODE" = delegate ] && [ "$DELEGATE_TREE_MOVED" = 1 ]; then break; fi
  done
  # Two or more helpers tried = a fallback happened: one summary line names
  # every outcome in order (a single OK stays exactly one line).
  if [ "$MODE" != delegate ] && [ "$(printf '%s' "$CHAIN" | wc -w | tr -d ' ')" -ge 2 ]; then echo "chain:$CHAIN"; fi
fi

# --- delegate --audit: the contract's tail — clean up ONCE, then the journal --
# Runs after the helper loop (a fallback needed the tree) and after the last
# outside snapshot (so nothing here counts as the helper's doing). A worktree
# no helper worked in is taken back by cleanup() with its branch, no entry.
if [ "$MODE" = delegate ] && [ "$AUDIT" = 1 ] && [ "$DELEGATE_RAN" = 1 ] && [ -n "$AUDIT_HELPER" ]; then
  audit_fate="already gone"
  if [ -d "$DWT" ]; then
    if [ -n "$(git -C "$DWT" status --porcelain 2>/dev/null)" ]; then
      # Uncommitted work is never deleted and never committed by the launcher:
      # the tree stays for a human (⏳), and the run is red whatever the
      # helper's own state line said.
      AUDIT_DIRTY=1; audit_fate="KEPT — dirty (uncommitted work); ⏳ человек: commit or clean, then git -C $REPO worktree remove $DWT"
      echo "FAIL: audit worktree dirty $DWT — uncommitted work kept for a human; branch $DBRANCH"
    elif git -C "$REPO" worktree remove "$DWT" >"$TMPS/wt-rm.log" 2>&1; then
      audit_fate="removed; branch $DBRANCH keeps the findings"
      echo "NOTE: audit worktree $DWT removed; branch $DBRANCH keeps the findings"
    else
      AUDIT_DIRTY=1; audit_fate="KEPT — git worktree remove failed ($(tail -1 "$TMPS/wt-rm.log" | cut -c1-120))"
      echo "FAIL: audit worktree $DWT could not be removed ($(tail -1 "$TMPS/wt-rm.log" | cut -c1-120)) — remove it by hand; branch $DBRANCH"
    fi
  fi
  AUDIT_JOURNAL="$ROOT/.agents/journal/$TODAY.md"
  mkdir -p "$(dirname "$AUDIT_JOURNAL")" 2>/dev/null
  # The entry goes into the project's tracked journal, and its "Итог" quotes
  # the helper's state line — on a CLI failure that is the CLI's last output
  # line, which the agent controls. So the whole entry passes the same secret
  # scan as the ticket text of `run` first (QA 12.10, Н-2); a finding, or no
  # way to check, writes a neutral entry with no quote and the run is a FAIL.
  ablk="$TMPS/audit.block"
  { echo "## $(date +%H:%M) · council delegate --audit · $AUDIT_HELPER"
    echo
    echo "Что: аудит по пакету $(basename "$TICKET") помощником $AUDIT_HELPER в worktree $DWT (ветка $DBRANCH, база $BASE)."
    echo "Итог: $AUDIT_STATE; worktree — $audit_fate; цепочка помощников:$CHAIN."
    echo "Коммит: $DBRANCH @ $(git -C "$REPO" rev-parse --short "$DBRANCH" 2>/dev/null || echo '?') (база $(git -C "$REPO" rev-parse --short "$BASE" 2>/dev/null))."
  } > "$ablk"
  text_scan audit "$ablk"; ak=$?
  if [ "$ak" != 0 ]; then
    if [ "$ak" = 1 ]; then aline="секрет-скан нашёл совпадение"; else aline="секрет-скан не смог проверить текст ($(secret_scanner)) — $(gitleaks_hint)"; fi
    { echo "## $(date +%H:%M) · council delegate --audit · $AUDIT_HELPER"
      echo
      echo "Итог: FAIL (текст записи не записан: $aline); подробности — в отчёте помощника в .agents/runtime/council/."
    } > "$ablk"
    PACKET_LEAK=1
    echo "FAIL: the journal entry $(scan_head "$ak") — only a neutral entry was written to $AUDIT_JOURNAL"
  fi
  { [ ! -s "$AUDIT_JOURNAL" ] || echo; cat "$ablk"; } >> "$AUDIT_JOURNAL" 2>/dev/null || echo "NOTE: journal entry NOT written ($AUDIT_JOURNAL) — add it by hand (canon §10)"
fi
[ "$ANY_OK" = 1 ] && [ "$AUDIT_DIRTY" = 0 ] && [ "$PACKET_LEAK" = 0 ] && exit 0
exit 1
