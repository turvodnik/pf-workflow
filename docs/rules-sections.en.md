# Ready-made rule sections for your AGENTS.md / CLAUDE.md

English translation of [rules-sections.ru.md](rules-sections.ru.md) (the Russian file is generated from the author's canon by the sync script; this translation is updated manually at release time — Russian is authoritative on divergence).

Notes: references to §0–§6 (secrets policy etc.) point to sections of the author's full rule set — replace them with your own rules. §13 (context budget & session continuity) ships with the companion tool [pf-handoff](https://github.com/turvodnik/pf-handoff). Paths like `_tools/…` refer to the author's environment — adapt to yours.

## 7. Task scale rule (S/M/L)

Before starting any task the agent estimates its scale and acts accordingly:

- **S** (≤30 min, 1–3 files, no new integrations): just do it; one journal line.
- **M** (up to half a day, several files): first a 5–10 line mini-plan in chat → the human's "ok" → do it.
- **L** (more than a day / a new project or subsystem / external APIs / migrations / money): the agent MUST stop and offer spec mode (`pf-spec` → SPEC.md → `pf-tickets`) with a single question. Silently starting an L-task is forbidden.
- Unsure between levels — name both and ask. Thresholds are revisited at retro.

## 8. Session protocol (for all agents)

- Start: read the project's AGENTS.md, journal, task packets and the active HANDOFF, pick the matching skill (don't reinvent a process a skill already describes).
- Finish (or a significant milestone): a journal entry (§10) + update the statuses of your task packets + checkpoint/close the HANDOFF (`pf-handoff`).
- Autopilot — only on an explicit human command/phrase ("/pf-auto", "autopilot", "do it all yourself to the end"): subagent orchestration under the `pf-auto` skill. Engaging it silently is forbidden.
- **Write claim.** Before the first write to a repository — a claim in `_tools/.agents/runtime/claims.md`; done — remove it. Someone else's live overlapping line, or `ВНИМАНИЕ` from the check, means stop and ask the human (there is no "I am alone here" exemption — that is exactly the root of I-032). Quote a command received outside the shared channel VERBATIM in «Результат»/the commit; never revert someone else's work on suspicion — ask the human instead.
- A push rejected (someone else's commit landed first) — `git pull --rebase` and retry; that is a normal race, not an incident, and not a reason for `--no-verify`.
- Full protocol (start/finish details, an L-task via `pf-do`, model per role, claim format, provenance, the push race, drift guard) — the `pf-handoff` skill, `references/context-rules.md`.

## 9. Task packets — the agents' file protocol

- Work is exchanged between agents and sessions only through files: `.agents/runtime/tasks/T-###-slug.md` (template in the `pf-tickets` skill).
- Frontmatter: `id, title, status (todo|in_progress|review|blocked|done|cancelled), owner (claude|codex|gemini|<your handle> — the shipped skills and templates use the origin system's enum with `vladimir`; substitute your own), depends_on, spec, updated`.
- Body: Context (self-contained — the executor never sees the author's chat) / Task / Acceptance criteria / Constraints / Result. In the shipped Russian templates the section names are the protocol literals — «Контекст / Задача / Критерии приёмки / Ограничения / Результат»; keep whichever set you pick consistent across packets, skills and reviewers.
- Executor contract: claimed — `status: in_progress` + owner; finished — fill in the result section («Результат» in the shipped templates: what was done, commits, deviations, evidence) and set `status: review`; stuck — `status: blocked` + reason. `done` is set by the human or a reviewer.
- One packet = one session ≤ ~2 hours of work. Bigger — slice smaller.
- The idea or a decision changed mid-work — don't push on by inertia and don't redo everything: only via `pf-replan` (impact assessment → SPEC update → cancelling/rewriting tickets → surgical commit rollback if needed).

## 10. Decision journal (mandatory in every project)

- File: `.agents/journal/YYYY-MM-DD.md` (in git). ALL agents write at the end of a session and at significant milestones.
- Entry format: `## HH:MM · agent · task`, then lines "What / Why (including rejected options) / How / Outcome / Commit".
- The journal is about "why", git is about "what": don't duplicate diffs; record decisions, deviations from the plan, and handoffs between agents.
- EVERY project keeps a journal — no exceptions. Adapt to your own layout: a shared tools workspace that is not itself a project writes its edits into the journal of the initiative that requested them, not into a stub journal of its own; anything with its own goals and its own work keeps its own journal.
- Candidates for process improvements — an "⚙️" line in the journal or straight into your improvements backlog; a retro consolidates them by the rule of three (automate confirmed repeats, not one-off cases).
- Search across the entire history of all projects: `_tools/history-search.sh <words>`.

## 11. Working-with-code principles

- Think first and formulate the approach, then write code.
- Don't overcomplicate: ask yourself "would a senior engineer call this excessive?" — if yes, simplify.
- Edits are minimal and surgical; don't rewrite the neighbouring code "while you're at it".
- Every goal has a verifiable criterion; "done" may only be claimed with fresh proof-command output (tests, curl, a screenshot). Without evidence it's not "done", it's "should work".
- Found a bug — root cause first (the `systematic-debugging` skill), then the fix.

## 12. External skills and agents — acceptance

- A skill is an instruction the agent obeys: the supply-chain risk is higher than with a regular library (prompt injections occur in a noticeable share of catalogue skills). Installation only via vendor: a clone + a tag/SHA pin + reading the contents with your own eyes BEFORE attaching. `npx skills add`, auto-updating sources and installing "by stars" are forbidden; Claude Code plugins follow the same regime (marketplace installed only from a local vendor path, NOT from GitHub — otherwise it auto-updates). Only the universal is attached globally (§3); tooling is attached to a specific project.
- The `codex-rescue` agent is invoked ONLY on an explicit human command (by default it writes to the working directory without confirmations); `codex exec` in `workspace-write`, `--full-auto`, `danger-full-access` mode — also only on an explicit human command. `codex exec` in `read-only` mode the agent runs itself, unasked. A dynamic workflow (a swarm of subagents) — also only on the human's «ок» from the main session.
- A review through the Codex plugin is NOT independent QA (§6): Claude frames the request, so Codex inherits Claude's blind spot. Release QA — only a separate agent with its own session.
- No Codex, no project consent, or a docs-only diff — the Codex-review step is skipped silently and the process is unchanged (don't install Codex, don't ask the human, don't block the work).
- Details (`global-skills.sh` mechanics, the Claude Code plugin regime, the stop gate, the model policy, when to call the dynamic workflow) — `pf-do`, `references/codex-review.md`.
