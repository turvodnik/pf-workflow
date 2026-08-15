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

## One review mode, and why the native reviewer is gone (I-033)

Every run is plain `codex exec` with the diff command and the report format
written into the prompt, `--sandbox read-only`. `--why "<focus>"` only adds one
line of focus to that same prompt.

Until T-024 the default pass used the **native** reviewer
(`codex exec review --uncommitted|--base|--commit`), where Codex framed the
review itself and our blind spot never entered the prompt. That is a real
property and we gave it up on purpose, for one reason: the verdict now rests on
**proof that a review happened** (the completion marker below), proof can only
be *requested*, and `codex exec review` has no prompt slot at all — the CLI
refuses a positional prompt together with any scope flag
(`error: the argument '--uncommitted' cannot be used with '[PROMPT]'`). Keeping
it would have left the path everybody uses with no proof at all.

Price, plainly: the framing is ours now (deliberately neutral — no hypothesis,
no focus, unless you pass `--why`). Gain: the output format is contractual on
every path, which it never was for the native reviewer whose `[P1]/[P2]/[P3]`
lines this script counted on faith.

## Reading the result — four traps

- **Exit code is always 0 when a review actually completed**, findings or not.
  The verdict is in the text: `[P1]`/`[P2]`/`[P3]` markers. Never infer "clean"
  from the exit code alone.
- **Zero findings is not automatically "clean" — and now it has to be proven.**
  Three tickets in a row (F-09 → T-020 → T-023) tried to list what a provider
  failure *looks like*; each time the next gate found a shape that walked past
  the list (a traceback starting on line 2, a CLI banner before the HTML, ANSI
  colouring, a line of spaces). A list of failure signs cannot be closed, so
  the question is inverted (I-033): not "does this look broken" but **"is there
  proof this is a review"**.

  The proof is a **completion marker**: the prompt requires the output to end
  with exactly `CODEX-REVIEW-COMPLETE: <N>`, where `<N>` is the number of
  `[P1]/[P2]/[P3]` finding lines (`0` when clean). The verdict ladder:

  | Output | Verdict |
  |---|---|
  | marker present, `<N>` = counted findings | `OK` — proven review |
  | marker present, `<N>` ≠ counted findings | `FAIL: not reviewed` (out of sync with its own sign-off — typically truncated) |
  | marker cut anywhere inside the token (`CODEX-R`, `CODEX-REVIEW-COMPL`, even a single `C` as the last line) | `FAIL: not reviewed` (truncation outweighs any findings above it) |
  | no marker, but ≥1 well-formed `- [P1\|P2\|P3] … — file:lines` line | `FAIL: not reviewed` + a `HINT:` block naming the way out (**T-029**; this row used to be `OK` + `NOTE`) |
  | no marker, ≥1 finding line, and the output also matches a known failure shape | `FAIL: not reviewed` — same verdict, message names the failure shape too |
  | the token appears only in the wrong case | `FAIL: not reviewed`, with a message that says so (the token is case-sensitive) |
  | anything else | `FAIL: not reviewed`, whatever the text looks like |

  Markdown around the marker does not break it, and the **same tolerance
  applies to finding lines** — an obedient review must never be refused for its
  formatting, and the two halves have to agree or a correct marker reads as a
  count desync. For the marker: emphasis characters (`*`, `_`, backticks) are
  deleted anywhere on the line and a leading block marker (`>` quote, `#`
  heading, `-`/`+`/`*` bullet) is dropped, so `**CODEX-REVIEW-COMPLETE: 1**`,
  `**CODEX-REVIEW-COMPLETE:** 1`, `- CODEX-REVIEW-COMPLETE: 0`, `> …` and
  `## …` are all obedient sign-offs; `: 01`, `: 000` and a trailing space are
  formatting, not a different number. For findings, the counted shape is
  `[indent] -|*|+ [emphasis][P1|P2|P3][emphasis] … — file:lines`, so
  `- **[P1]** …` and an indented `  - [P2] …` count. A count that cannot be
  read at all (`: +1`, `: 1.0`, `: one`) is still `FAIL`, with a message that
  blames the count rather than claiming a cut-off tail. The stripped view is
  used for the marker only — the finding counter still requires a bullet and a
  bracketed severity, which is what makes a line a finding rather than prose.

  **The backup row and what happened to it (T-029, decided on data).** Until
  T-029 finding lines without a marker were *accepted* — `OK` plus a loud
  `NOTE` — as "positive evidence that this is a report". That acceptance is
  gone. Finding lines are still evidence of report *structure*; they are simply
  no longer treated as proof that a review *ran*. What is left of the row is a
  detailed `FAIL` message that names the recovery path (re-run; if it repeats,
  the valve below).

  The reason is a measurement, not a preference. The backup acceptance was
  insurance against an **unmeasured** risk — "the model will forget the marker".
  On **14.08.2026** that risk was measured on the live wire: a full Codex run
  over the whole wave (29 commits, 31 files, `luna`/`max`, 1236 s, report
  `optimize/reports/2026-08-14-codex-review-final-wave.md`) ended with
  `CODEX-REVIEW-COMPLETE: 9` as the **last line**, matching its nine findings.
  The real model obeys the contract. Meanwhile the price of the insurance was a
  hole *in* the contract — Codex itself rated it **P1** in that same run: any
  output carrying one well-formed finding line was accepted with no marker, so
  an **unknown** failure shape with such a line inside read as a review. Paying
  a real hole for protection against something never observed is a bad trade,
  and now there is data to say so.

  One live observation is not a law, so the row was **not** simply deleted. The
  failure is recoverable by design: the `FAIL` message spells out the order —
  read the report, re-run (the prompt requires the marker), and if the provider
  really has started eating tails, open `PF_CODEX_SENTINEL_OPTIONAL=1` for that
  run. Work continues; it just continues by a human decision instead of
  silently. The old claim this paragraph used to defend — "no provider dump
  contains such a line" — was false anyway: a denylist claim wearing the
  whitelist's clothes, and the T-024 gate built two counter-examples in minutes
  (a 502 page and a JSON error envelope, each with a well-formed finding line
  inside). The shape detectors keep their **veto** on this row, now only to make
  the message more specific.

  Known blind spot at the boundary, stated rather than hidden: truncation that
  eats the marker line *whole* leaves zero characters of it, which nothing can
  tell apart from a model that never wrote one. Since T-029 both cases land in
  the same place — `FAIL`, with findings present or not — which removes the odd
  asymmetry where a truncated report with findings was safer to lose than a
  truncated clean one. Truncation from one character of the token onwards is
  caught by the cut detector and named as such.

  The old detectors (word signature + error-envelope shape) are still there,
  demoted to a second echelon: they no longer decide anything, they add a
  `HINT:` line explaining *why* a failure probably happened ("looks like a
  provider error"), which "no marker" alone would not say.

- **`PF_CODEX_SENTINEL_OPTIONAL=1` — the emergency valve, and its price.** Since
  T-029 this is the **only** way any marker-less output can be accepted, which
  raises its importance: it is the thing that keeps the pipeline movable if the
  model ever does go silent. If
  the provider ever starts cutting output tails, the marker would fail every
  honest run. Setting this variable (`1`, `true`, `yes`, `on`, any case) waives
  the **marker requirement** — and nothing else. It does **not** disarm the
  second echelon: a known failure shape is still vetoed with the valve open,
  whether or not the output carries finding lines. (An earlier version of this
  line promised the verdict was "handed back to the second echelon", while the
  code consulted the echelon only when there were zero findings — so a known
  502 shape with a finding line inside was refused without the valve and
  accepted with it. Fixed; the pair of tests now covers both counts.) The run
  prints a loud `NOTE` and repeats
  it in the report. **The price is the entire T-024 guarantee**, and it is wider
  than "the silent failure comes back": the valve also silences the *positive*
  evidence of truncation. A count that disagrees with its own sign-off, and a
  marker cut mid-token, both stop being verdicts — so a **truncated report reads
  as a whole one**, and a silent provider failure again reads as a clean review.
  That is exactly the hole three tickets failed to close by other means, plus
  one more. Use it as a temporary bridge
  while the prompt is fixed, never as a default; if the marker is genuinely
  unobtainable, that is a blocker worth raising, not a setting worth keeping.
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

## Vendor mechanics and dynamic workflow policy (moved from canon §12, T-037)

- **Global-level mechanics.** Canon lives at `~/.agents/skills/` → symlink
  surfaces at `~/.claude/skills`, `~/.codex/skills`, `~/.gemini/skills`;
  managed via `_tools/global-skills.sh` (attach/detach/list/doctor), pins in
  `~/.codex/vendor/global-skills.lock.yaml`.
- **Claude Code plugins** follow the same mode: a vendor clone plus a
  read-only version snapshot at `~/.codex/vendor/versions/<name>/vX.Y.Z/`,
  marketplace install from that local path (not from GitHub — that would
  auto-update), pins in `~/.codex/vendor/plugins.lock.yaml`.
- **The `codex` plugin** (Codex inside Claude Code): review commands
  (`/codex:review`, `/codex:adversarial-review`) run sandboxed read-only and
  are safe. The `codex-rescue` agent is invoked ONLY on an explicit human
  command — by default it runs Codex with `--write` (writes to the working
  folder without confirmation); if a write is needed, work in a separate
  worktree. The stop-gate (`/codex:setup --enable-review-gate`) stays
  disabled: it blocks the end of every turn on review for up to 15 minutes.
- **Dynamic workflow** (scripted subagent orchestration) is not for every
  task: call it when the price of a mistake is high (a public release, an
  irreversible action, a wide audit), and only from the main session, with
  the human's go-ahead. Verified 2026-08-13: on release QA it found a 🔴
  beyond two independent passes; on a quick internal check it just burned
  tokens with no findings.
- **`codex exec` modes.** The agent runs `codex exec` in `read-only` mode on
  its own, without asking; `workspace-write`, `--full-auto`,
  `danger-full-access` are only on an explicit human command. The standard
  path is `pf-do/scripts/codex-review.sh` (project consent in
  `.agents/codex-review.json`, full report to a file, a digest into
  context). No Codex, no consent, or a docs-only diff — the step is silently
  skipped, the process doesn't change. Gotchas and model policy (luna/max —
  fast lane, sol/xhigh — heavy) — this file.

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

That raw form is the **native** reviewer, which the script itself no longer
uses (see "One review mode" above): run by hand it produces no completion
marker, so nothing verifies that what you got is a review rather than an error
page — read the output yourself before calling anything clean.

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
