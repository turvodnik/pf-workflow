# Optional second opinion: Codex review

A cheap independent-ish pass over a diff, run by the local Codex CLI. Entirely
optional: without Codex installed nothing changes and no step fails.

Sources: OpenAI Codex CLI (`codex exec review`), practices adapted from the MIT
`skills-directory/skill-codex` runbook, plus findings from our own runs.

## The one command

```bash
bash ~/.claude/skills/pf-do/scripts/codex-review.sh --scope uncommitted
```

Installed elsewhere (Claude/Codex/Gemini surfaces, a project-local copy)?
Resolve once — the same resolver as pf-do step 5a and pf-auto's Codex
pre-pass, so all three surfaces agree on where to look and what to say when
nothing is found:

```bash
SC=$(ls ~/.claude/skills/pf-do/scripts/codex-review.sh ~/.codex/skills/pf-do/scripts/codex-review.sh ~/.gemini/skills/pf-do/scripts/codex-review.sh 2>/dev/null | head -1); if [ -n "$SC" ]; then bash "$SC" --scope uncommitted; else echo "no script — skip this step"; fi
```

`--scope uncommitted` (default) | `--base <ref>` | `--commit <sha>`.
Other flags: `--deep` (frontier model for milestone passes), `--out <file>`,
`--why "<focus>"`, `--model`/`--effort` (debugging), `--yes` (skip asking when
**no consent file exists yet** — only when the human just asked for the review
in this turn). `--yes` only ever widens that *no file at all* case: a recorded
`false`, a file that fails to parse, and a file this machine cannot read all
skip exactly the same whether `--yes` is given or not (see Gate 3 below).

Read stdout only. It prints `SKIP:` / `OK:` + `REPORT:` + `FINDINGS:` + a verdict
line. Open the report file **only** when findings exist. That is the point of the
script: ~15 lines of context instead of a full review (§13).

## The four gates (all silent, all exit 0)

1. **No `codex` in PATH** → skip. Someone else's machine works exactly as before.
2. **Not a git repo / empty diff** → skip.
3. **Consent, fail-closed** — the only way through this gate is (a) no
   `.agents/codex-review.json` at all, plus `--yes`, or (b) the file exists,
   is readable, parses as JSON, and `.enabled` is the JSON boolean `true`.
   Everything else skips unconditionally, `--yes` or not: `enabled:false`
   (a recorded refusal), a missing/non-boolean `.enabled` (a quoted `"true"`
   does not count), invalid JSON, an unreadable file, or a readable file on a
   machine with neither `jq` nor `python3` to parse it. The reasoning: every
   one of those states is indistinguishable from "someone recorded false and
   this run just can't prove otherwise" — so none of them are treated as
   consent, ever.
4. **Docs-only diff** — prose (`.md`, `.txt`, `.rst`), images, lockfiles,
   README/CHANGELOG/LICENSE → skip; Codex answers "no executable code changed"
   and the quota is wasted. Configs, CI workflows and schemas (`.json`, `.yaml`,
   `.toml`, `.sql`) are NOT docs — pf-auto counts them as executable risk, so
   they stay in scope. A changed path with a literal newline in its name also
   skips here — line-oriented filtering downstream cannot safely tell where
   such a name ends, so the script says so instead of guessing.

## Consent file

```json
{"enabled": true, "model": "gpt-5.6-luna", "effort": "max"}
```

Written once, after the human is asked (pf-spec asks it while the spec is being
written; outside a spec, ask before the first run or don't run). `model` and
`effort` are optional — defaults below. `enabled` must be a real JSON boolean
(`true`/`false`, unquoted) — a quoted `"true"` string parses fine as JSON but
is not accepted as consent, on purpose (see Gate 3 above).

## `--out` never overwrites what was already there

A file, a symlink (even a dangling one), a FIFO, or a directory already at
the `--out` path all make the run stop before anything is touched — codex is
not even invoked. Only the script's own default path
(`workspace/runs/codex-review/…`) auto-picks a fresh `-N` suffix on a
collision; a path you name is either free to use or the run refuses it.

## Model policy

| Lane | Model | Effort | Typical time | When |
|---|---|---|---|---|
| fast (default) | `gpt-5.6-luna` | `max` | 2–5 min | per-ticket review, handoff checks |
| deep (`--deep`) | `gpt-5.6-sol` | `xhigh` | 5–20 min | autopilot wave milestones, pre-release passes |

Effort ladder: `low → medium → high → xhigh → max` on every GPT-5.6 model, with
`ultra` on top for `sol`/`terra` only (luna has no `ultra`; its ceiling is `max`).
Legacy models cap at `xhigh`.

**`ultra` is banned here** — it means maximum reasoning *plus automatic delegation
to sub-agents*: the slowest and least predictable spend, for a review we already
get from `max`. The script downgrades `ultra` to `max` and says so, no matter
whether the value came from the config, a flag or `--deep`.

## Two review modes (the script picks for you)

- **Without `--why`** — the native reviewer (`codex exec review --uncommitted|--base|--commit`), pinned to `sandbox_mode="read-only"`. Codex frames the review itself, so our blind spot never enters the prompt. Prefer this.
- **With `--why "<focus>"`** — plain `codex exec` with the diff command written into the prompt. Needed because the CLI refuses a positional prompt together with any scope flag: `error: the argument '--uncommitted' cannot be used with '[PROMPT]'`. Same read-only sandbox, but the framing is now ours — use it only when you genuinely need a specific angle.

## Reading the result — four traps

- **Exit code is always 0 when a review actually completed**, findings or not.
  The verdict is in the text: `[P1]`/`[P2]`/`[P3]` markers. Never infer "clean"
  from the exit code alone.
- **Zero findings is not automatically "clean".** If Codex exits 0 with no
  `[P1]`/`[P2]`/`[P3]` lines AND the text matches a known provider/CLI failure
  signature (auth errors, rate limits, timeouts, a stack trace, …), the script
  reports `FAIL: not reviewed` instead of `OK: … 0 findings` — a wrapper-level
  error should never be indistinguishable from "nothing to report". This is a
  disclosed heuristic (a denylist of known failure phrasing), not a formal
  contract with the provider: it catches the failure shapes seen in practice,
  not everything that could ever go wrong. When a "0 findings" result looks
  surprising, read the report file before trusting it either way.
- **An empty report means the run died**, not that the code is clean. Codex emits
  nothing until it finishes, so a killed process leaves a silently empty file.
  The watchdog sends SIGTERM at the effort's budget and SIGKILL `PF_CODEX_GRACE`
  seconds later (default 15, same override pattern as `PF_CODEX_TIMEOUT`), to
  the whole process group — no `pkill` involved, and the main script now always
  waits for that full escalation to finish before returning, so a
  SIGTERM-resistant descendant is dead by the time you get a result, not left
  running. If runs still misbehave after a timeout, look for stray `codex`
  processes first. The script turns a dead/empty run into `FAIL:` + exit 1 and
  prints the last stderr lines — treat it as "not reviewed". (Do not drop
  stderr entirely when calling Codex by hand: it carries the reasoning stream,
  but also the only explanation of a crash. Send it to a file, not to
  `/dev/null`.)
- **Codex is a colleague, not an authority.** It has its own knowledge cutoff and
  gets model names, recent APIs and current best practices wrong. Verify a finding
  against the code before acting on it; state disagreement with evidence rather
  than deferring. Findings are input to your judgement, never an auto-fix queue.

## What a review is NOT

It does not satisfy §6 (independent QA before a public release): same machine,
same repository, no hostile scenarios. It sits between "Claude reviews itself"
and "a fresh agent audits us" — use it to catch the cheap half early.

## Raw invocation (when the script is unavailable)

```bash
codex exec --skip-git-repo-check review --uncommitted \
  -m gpt-5.6-luna --config model_reasoning_effort="max" \
  </dev/null > report.md 2>report.stderr
```

`</dev/null` is not optional: `codex exec` always reads stdin and hangs forever
when stdin is neither a TTY nor closed (hooks, background tasks, scripts). The
symptom is zero bytes of output, zero CPU, forever. Send stderr to a file
(`2>report.stderr`), not `/dev/null` — it carries the reasoning stream, and on
a crash it is the only explanation you get (see the empty-report trap above).
Timeouts by effort: low 150s, medium 300s, high 600s, xhigh 1200s, max/ultra
1800s. Continue a session with
`echo "prompt" | codex exec --skip-git-repo-check resume --last 2>resume.stderr`
(no flags allowed on resume — model, effort and sandbox are inherited).

Everything above runs in `--sandbox read-only`: Codex cannot modify the repo.
Write-capable Codex runs (`--sandbox workspace-write`, `--full-auto`, the
`codex-rescue` agent) stay behind an explicit human command — §12 of the global
rules.
