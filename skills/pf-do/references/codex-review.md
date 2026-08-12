# Optional second opinion: Codex review

A cheap independent-ish pass over a diff, run by the local Codex CLI. Entirely
optional: without Codex installed nothing changes and no step fails.

Sources: OpenAI Codex CLI (`codex exec review`), practices adapted from the MIT
`skills-directory/skill-codex` runbook, plus findings from our own runs.

## The one command

```bash
bash ~/.claude/skills/pf-do/scripts/codex-review.sh --scope uncommitted
```

Installed elsewhere (Codex/Gemini surfaces, a project-local copy)? Resolve once:

```bash
SC=$(ls ~/.claude/skills/pf-do/scripts/codex-review.sh \
        ~/.codex/skills/pf-do/scripts/codex-review.sh 2>/dev/null | head -1)
[ -n "$SC" ] && bash "$SC" --scope uncommitted || echo "no script — skip the step"
```

`--scope uncommitted` (default) | `--base <ref>` | `--commit <sha>`.
Other flags: `--deep` (frontier model for milestone passes), `--out <file>`,
`--why "<focus>"`, `--model`/`--effort` (debugging), `--yes` (bypass the consent
file — only when the human just asked for the review in this turn).

Read stdout only. It prints `SKIP:` / `OK:` + `REPORT:` + `FINDINGS:` + a verdict
line. Open the report file **only** when findings exist. That is the point of the
script: ~15 lines of context instead of a full review (§13).

## The four gates (all silent, all exit 0)

1. **No `codex` in PATH** → skip. Someone else's machine works exactly as before.
2. **Not a git repo / empty diff** → skip.
3. **No consent** — `.agents/codex-review.json` missing or `enabled:false` → skip.
4. **Docs-only diff** — prose (`.md`, `.txt`, `.rst`), images, lockfiles,
   README/CHANGELOG/LICENSE → skip; Codex answers "no executable code changed"
   and the quota is wasted. Configs, CI workflows and schemas (`.json`, `.yaml`,
   `.toml`, `.sql`) are NOT docs — pf-auto counts them as executable risk, so
   they stay in scope.

## Consent file

```json
{"enabled": true, "model": "gpt-5.6-luna", "effort": "max"}
```

Written once, after the human is asked (pf-spec asks it while the spec is being
written; outside a spec, ask before the first run or don't run). `model` and
`effort` are optional — defaults below.

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

## Reading the result — three traps

- **Exit code is always 0**, findings or not. The verdict is in the text:
  `[P1]`/`[P2]`/`[P3]` markers. Never infer "clean" from the exit code.
- **An empty report means the run died**, not that the code is clean. Codex emits
  nothing until it finishes, so a killed process leaves a silently empty file.
  The watchdog sends SIGTERM at the effort's budget and SIGKILL 15s later, but it
  kills the `codex` process itself — a shared app-server child can survive. If runs
  start misbehaving after a timeout, look for stray `codex` processes first.
  The script turns this into `FAIL:` + exit 1 and prints the last stderr lines —
  treat it as "not reviewed". (Do not drop stderr entirely when calling Codex by
  hand: it carries the reasoning stream, but also the only explanation of a
  crash. Send it to a file, not to `/dev/null`.)
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
  </dev/null 2>/dev/null > report.md
```

`</dev/null` is not optional: `codex exec` always reads stdin and hangs forever
when stdin is neither a TTY nor closed (hooks, background tasks, scripts). The
symptom is zero bytes of output, zero CPU, forever. `2>/dev/null` drops the
reasoning stream. Timeouts by effort: low 150s, medium 300s, high 600s,
xhigh 1200s, max/ultra 1800s. Continue a session with
`echo "prompt" | codex exec --skip-git-repo-check resume --last 2>/dev/null`
(no flags allowed on resume — model, effort and sandbox are inherited).

Everything above runs in `--sandbox read-only`: Codex cannot modify the repo.
Write-capable Codex runs (`--sandbox workspace-write`, `--full-auto`, the
`codex-rescue` agent) stay behind an explicit human command — §12 of the global
rules.
