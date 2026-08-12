# pf-workflow — a spec-driven workflow toolkit for multi-agent CLI development

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE) [![Release](https://img.shields.io/github/v/release/turvodnik/pf-workflow)](https://github.com/turvodnik/pf-workflow/releases) [![tests](https://github.com/turvodnik/pf-workflow/actions/workflows/tests.yml/badge.svg)](https://github.com/turvodnik/pf-workflow/actions/workflows/tests.yml)

Русская версия: [README.ru.md](README.ru.md)

Rules, 6 skills and 3 agents that turn work with CLI agents (Claude Code, Codex, Gemini) from "one endless chat" into a managed process:

```
idea → pf-spec (interview → SPEC.md) → pf-tickets (slice into tickets)
     → pf-do (execute a ticket in a fresh window) → pf-replan (change of course)
     → pf-retro (process review every 2 weeks)
     → pf-auto (autopilot: the same pipeline driven end-to-end by subagents — explicit command only)
     + pf-handoff / pf-resume (session continuity: state cheat-sheet + compaction survival)
```

## Problems it solves

- Big tasks fall apart in a single chat: the context window gets expensive, quality degrades, usage limits burn.
- Decision history ("why we did it this way") is lost between sessions and agents.
- "I changed my mind mid-work" costs a full redo, because nobody knows what depends on what.
- Several agents in one project don't know what the others did.

## Components

| Component | What it does |
|---|---|
| `skills/pf-spec` | Interview until full coverage (one question at a time + a recommended answer) → SPEC.md |
| `skills/pf-tickets` | SPEC → self-contained tickets with dependencies; parallelism gate (≥5 independent → offer a swarm) |
| `skills/pf-do` | Executor contract: fresh window, evidence-based acceptance, commit per ticket, statuses, journal |
| `skills/pf-replan` | Change of course: "spec → tickets → commits" tracing, impact classes A/B/C, surgical rollback |
| `skills/pf-retro` | Retro over all projects' journals; automation trust ladder L1 → L2 → L3 |
| `skills/pf-auto` | Autopilot: subagent waves, a review gate at every milestone, fix loops ≤3 with model escalation, parallelism ≤2, safety stops |
| `agents/` | pf-architect (spec + slicing), pf-executor (one ticket, Sonnet-class), pf-reviewer (acceptance with evidence) |
| `docs/rules-sections.ru.md` | Ready-made rule sections §7–§12 for your global AGENTS.md/CLAUDE.md (generated from the canon) |
| `docs/PROCESS.en.md` | Full process description from idea to retro ([RU](docs/PROCESS.ru.md)) |

Session continuity (live state cheat-sheet, 60/80/90 % window thresholds, compaction survival) is a **separate companion tool, [pf-handoff](https://github.com/turvodnik/pf-handoff)**: the pf-handoff/pf-resume skills, hooks and rules section §13. The two tools work together but are installed and evolve independently.

## Key principles

1. **Files are the only bus between agents.** Tickets, journal, cheat-sheets are plain Markdown in git — works with any CLI agent, readable by humans.
2. **A fresh window per ticket.** The executor sees only the ticket + project rules — cheap on limits, sharper in quality.
3. **A commit per ticket.** Hashes are recorded in the ticket → rolling back an idea = reverting two commits, not "the whole project".
4. **Evidence before "done".** Success may only be claimed with fresh verification-command output.
5. **Automation trust climbs a ladder: L1 (report only) → L2 (apply with confirmation) → L3 (autonomous, with a kill switch).** Promotion after 2 clean runs.

## Install

```bash
git clone https://github.com/turvodnik/pf-workflow.git && cd pf-workflow
bash install.sh          # copies skills into ~/.claude/skills (+ .codex/.gemini if those CLIs exist) and agents into ~/.claude/agents
# bash install.sh --update  # refresh existing copies after git pull
# bash install.sh --link    # symlink mode instead of copies (then don't move the clone)
# then paste docs/rules-sections.ru.md into your global AGENTS.md/CLAUDE.md
# recommended companion: github.com/turvodnik/pf-handoff (session continuity)
```

## Usage cheat-sheet

- `/pf-spec` — "make a spec" before any large task; `/pf-tickets` — slicing after your "ok".
- New chat window → "execute ticket T-003" — runs under the pf-do contract.
- Changed your mind → `/pf-replan`. Every 2 weeks → `/pf-retro`.
- Pausing / window filling up → `/pf-handoff`, continue in a new chat → `/pf-resume` (companion pf-handoff commands).

## Development & releases

The canon lives in the author's working environment (`_tools/skill-library`); changes arrive here as releases: `bash sync-from-tools.sh` → `CHANGELOG.md` → commit → tag `vX.Y.Z` → push. Ongoing work happens on the `dev` branch; `main` holds released states only. Companion standalone distribution of the context subsystem: [pf-handoff](https://github.com/turvodnik/pf-handoff).

Run the test suite locally with `bash tests/run.sh` (bash 3.2+, no dependencies beyond coreutils and git; ShellCheck, python3/PyYAML and actionlint are used when present, skipped with a reason otherwise). The same command runs in CI on every push and pull request ([`.github/workflows/tests.yml`](.github/workflows/tests.yml)). It never invokes the real Codex CLI or touches the network — a fixture stands in for `codex` throughout (see [`tests/known-failures-T017.txt`](tests/known-failures-T017.txt) for the small set of cases this repo's un-synced copies are currently, and knowingly, red on).

Skill and agent instructions are in English. The rules sections and artifact templates (SPEC, task packets, registries) are Russian — the author's working language; the process design itself is language-agnostic, and the skills answer in the user's language. English translation of the rules: [docs/rules-sections.en.md](docs/rules-sections.en.md).

---

**Pifagor Studio** — Vladimir ([@turvodnik](https://github.com/turvodnik)) · [MIT License](LICENSE)
