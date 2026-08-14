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

- Start: read the project's AGENTS.md → the `.agents/journal/` for the last 3 days → task packets with status ≠ done → the active HANDOFF (§13), if any → check the list of available skills and use the matching one (don't reinvent a process a skill already describes).
- Finish (or a significant milestone): a journal entry (§10) + update the statuses of your task packets + checkpoint/close the HANDOFF (`pf-handoff`).
- Executing a part of an L-task happens in a fresh session under `pf-do`: the context is only the packet + AGENTS.md, not the tail of someone else's chat (cheaper on limits, sharper in quality).
- Autopilot — only on an explicit human command/phrase ("/pf-auto", "autopilot", "do it all yourself to the end"): subagent orchestration under the `pf-auto` skill. Engaging it silently is forbidden.
- Model per role: thinking/designing/reviewing — a top-tier model; executing a ready plan — Sonnet-class.
- **Write claim (only with parallel sessions).** Before your first write to a repository, read `_tools/.agents/runtime/claims.md` and add a line «repo-or-path · ticket · who · taken · expires» (default expiry 2h); done — remove it. Someone else's live overlapping line — stop and ask the human; an expired one is free, delete it. Format and the one-line check — `pf-handoff`, `references/context-rules.md`.
- **Command provenance.** Acting on a command received outside the shared channel (another window, a direct message) — quote it VERBATIM in «Результат» and in the commit message. A retelling ("at Vladimir's request") does not count: another session must see the basis, not take your word for it.
- **Never revert someone else's work on suspicion.** "I see no basis in my own chat" is not proof: sessions do not see each other's commands. Ask the human; reverting someone's work is as irreversible as making it. Price of the mistake — the 13.08 incident (I-032): an agreed canon edit reverted plus a false accusation written twice into the permanent journal.
- A push rejected (someone else's commit landed first) — `git pull --rebase` and retry; that is a normal race, not an incident, and not a reason for `--no-verify`.

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
- Search across the entire history of all projects: `_tools/history-search.sh <words>`.

## 11. Working-with-code principles

- Think first and formulate the approach, then write code.
- Don't overcomplicate: ask yourself "would a senior engineer call this excessive?" — if yes, simplify.
- Edits are minimal and surgical; don't rewrite the neighbouring code "while you're at it".
- Every goal has a verifiable criterion; "done" may only be claimed with fresh proof-command output (tests, curl, a screenshot). Without evidence it's not "done", it's "should work".
- Found a bug — root cause first (the `systematic-debugging` skill), then the fix.

## 12. External skills and agents — acceptance

- A skill is an instruction the agent obeys: the supply-chain risk is higher than with a regular library (prompt injections occur in a noticeable share of catalogue skills).
- Installation only via vendor: a clone in `~/.codex/vendor/<name>` + a tag/SHA pin + reading the contents with your own eyes BEFORE attaching. `npx skills add`, auto-updating sources and installing "by stars" are forbidden.
- Only the universal is attached globally (§3); tooling is attached to a specific project.
- Global-level mechanics: canon `~/.agents/skills/` → symlink surfaces in `~/.claude/skills`, `~/.codex/skills`, `~/.gemini/skills`; managed by `_tools/global-skills.sh` (attach/detach/list/doctor), pins — `~/.codex/vendor/global-skills.lock.yaml`.
- Claude Code plugins follow the same regime: a vendor clone plus a read-only version snapshot in `~/.codex/vendor/versions/<name>/vX.Y.Z/`, with the marketplace installed from that local path (not from GitHub — otherwise it auto-updates); pins live in `~/.codex/vendor/plugins.lock.yaml`.
- The `codex` plugin (Codex inside Claude Code): the review commands (`/codex:review`, `/codex:adversarial-review`) run in a read-only sandbox and are safe. The `codex-rescue` agent is invoked ONLY on an explicit human command — by default it starts Codex with `--write` (writes to the working directory without confirmations); when writes are needed, work in a separate worktree. Keep the stop gate (`/codex:setup --enable-review-gate`) off: it holds up the end of every turn for a review of up to 15 minutes.
- A review through the plugin is NOT independent QA (§6): Claude frames the request, so Codex inherits Claude's blind spot. Release QA — only a separate agent with its own session.
- A dynamic workflow (subagent orchestration driven by a script) is not for every task: call it when the cost of a mistake is high (a public release, an irreversible action, a wide audit), only from the main session, and only on the human's «ок». Measured on this system: on release QA it found a blocker two independent passes had missed; on a quick internal check it burned tokens and found nothing.
- `codex exec` in `read-only` mode is the agent's to run unasked; `workspace-write`, `--full-auto` and `danger-full-access` — only on an explicit human command. The standard path is `pf-do/scripts/codex-review.sh` (project consent in `.agents/codex-review.json`, full report to a file, a digest into the context). No Codex, no consent, or a docs-only diff — the step is skipped silently and the process is unchanged. Traps and the model policy (luna/max as the fast lane, sol/xhigh as the deep one) — `pf-do/references/codex-review.md`.
