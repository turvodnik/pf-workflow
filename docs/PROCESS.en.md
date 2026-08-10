# The pf-workflow process: from idea to retro

Русская версия: [PROCESS.ru.md](PROCESS.ru.md)

## 0. Scale rule — when the pipeline is needed at all

Before any task the agent estimates its scale:

- **S** (≤ ~30 min, 1–3 files) — just do it, one journal line. No pipeline.
- **M** (up to half a day) — a 5–10 line mini-plan in chat → human "ok" → do it.
- **L** (more than a day / new project / external integrations / money) — the agent **must** offer spec mode with a single question. Silently starting an L-task is forbidden.

Why: without a threshold agents either bureaucratize trivia or dive into big work unplanned — both burn usage limits.

## 1. pf-spec — interview to specification

The human answers questions **once, up front**; afterwards agents work autonomously.

- One question at a time; each comes with the agent's recommended answer and its consequences ("I'd pick X, the cost is …").
- Facts derivable from files/code/web the agent finds itself; the human is asked only for decisions (goals, boundaries, priorities).
- Output — `SPEC.md`: problem, what we do, what we do NOT do, assumptions, acceptance criteria, risks, change history.
- A spec without a human "ok" is a draft; nobody works from a draft.

## 2. pf-tickets — slicing into tickets

- Every ticket is **self-contained**: its executor sees only the ticket + project rules, never the author's chat. No placeholders.
- Size: one ticket ≤ ~2 hours of one session. Dependencies via `depends_on`; statuses: `todo | in_progress | review | blocked | done | cancelled`.
- Each ticket gets a recommendation: which agent executes it and which model class (thinking — top-tier; mechanical work — Sonnet-class).
- **Parallelism gate**: with ≥5 mutually independent tickets the agent offers a choice — a queue (cheaper) or parallel windows/subagents (faster, more tokens). The human decides.
- Files: `.agents/runtime/tasks/T-###-slug.md` (template in skills/pf-tickets/references/).

## 3. pf-do — executing a ticket in a fresh window

The core economy idea: **a new chat window per ticket**. The executor reads only the ticket + rules — small context, higher quality, limits preserved.

Executor contract: claim → `in_progress` + owner; blocker → `blocked` + reason, never silently worked around; before "done" — fresh verification-command output for **every** acceptance criterion; fill in "Result" (what was done, commits, deviations, evidence) → `review`. **Commits per ticket are mandatory**, hashes go into "Result"; `done` is set by the human or the reviewer.

Launch: new window → "execute ticket T-003".

## 4. pf-replan — changing course without losing work

When the idea changes mid-work: don't push on by inertia and don't redo everything.

- Impact tracing along "spec → tickets → commits": which SPEC sections are affected → which tickets reference them → their dependents.
- Impact class: **A** — additive (append to spec + new tickets); **B** — changes unfinished work (rewrite/cancel todo tickets); **C** — invalidates finished work (surgical `git revert` of the affected tickets' commits OR rework on top — both options priced, the cheaper one recommended).
- Everything only after a human "ok"; recorded in the spec's change history and the journal.

## 5. pf-retro — process review

Every 2 weeks (monthly once the process settles): a digest of all projects' journals and tickets → what stalled, what was done by hand ≥3 times (automation candidate), what went unused (removal candidate).

Automation trust ladder: **L1** — report only → **L2** — applies with confirmation → **L3** — autonomous (only with a denylist, a budget and a kill switch). Promotion after 2 clean runs; an incident demotes immediately.

## 6. The shared bus: files and journal

- Tickets, specs, journal are plain Markdown in git. Any CLI agent reads them; so do humans.
- Decision journal `.agents/journal/YYYY-MM-DD.md` (in git): `## HH:MM · agent · task` + What/Why/How/Outcome/Commit. The journal is about "why"; git is about "what".
- Session-start protocol: project rules → journal for the last 3 days → tickets with status ≠ done. That's how any agent knows what the others did.

## 7. Agent roles

- **pf-architect** — runs the interview and the slicing; writes no product code.
- **pf-executor** — executes exactly one ticket (Sonnet-class: cheap, works from a ready plan).
- **pf-reviewer** — re-verifies every criterion itself, never trusts "Result" on faith; verdict `done` or a return with a 🔴/🟡/💭 list.

## 8. pf-auto — autopilot ("do everything yourself, to the end")

Engages **only** on an explicit command `/pf-auto` or phrase ("autopilot", "do it all yourself to the end"); engaging silently is forbidden. Requires an approved SPEC and tickets — the interview is not automatable, a human answers it. From there the orchestrator drives the task to completion on its own:

- Groups tickets into **batches of 1–3** (size capped by the executor's context window) and runs waves ordered by dependencies; ≤2 batches in parallel, and only with disjoint files.
- Each batch is executed by a **fresh subagent** under the pf-do contract: the full result goes into the tickets, the orchestrator receives a ≤15-line summary (its window is reserved for coordination).
- After each batch — a **mandatory gate**: an independent reviewer subagent re-verifies every criterion with evidence against the diff; the executor's "Result" is never taken on faith.
- Findings → a **fix loop of ≤3 rounds**: rounds 1–2 — the same executor, round 3 — a fresh executor on a stronger model; past the limit — `blocked` and a report to the human. No infinite loops.
- **Stops**: a question only the human can answer; a ticket contradicting the spec (a mini pf-replan report); irreversible external actions (publishing to a live site, deploys, mailings, DNS, money) — prepare everything and ask; the orchestrator's context-window thresholds.
- **Finale**: a whole-task review against the SPEC on the strongest available model → a single fix pass → done and a report to the human (what was done / evidence / parked notes / wave-and-round statistics).
- The wave registry lives in the HANDOFF (if the pf-handoff companion is installed) or in `.agents/runtime/autopilot-run.md`. Dispatch prompt templates: `skills/pf-auto/references/dispatch-templates.md`.

## 9. Session continuity — the pf-handoff companion

Long sessions hit the context window. That problem is solved by a separate tool, [pf-handoff](https://github.com/turvodnik/pf-handoff): a live task-state cheat-sheet, a window-usage gauge with 60/80/90 % thresholds, surviving history compaction, and pickup in a new chat (`/pf-resume`). pf-do and pf-replan are designed to pair with it, but pf-workflow works without it too.
