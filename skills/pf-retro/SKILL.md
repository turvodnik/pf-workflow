---
name: pf-retro
description: "Ретро процессов — что улучшить в том, как мы работаем, с ценой и риском каждой правки. Workflow retrospective — a digest of journals and task packets across all projects for the period, automation maturity levels L1→L3, improvement proposals with price and risk. Use when user runs «/pf-retro», «давай ретро», «пересмотрим процессы», «как улучшить нашу работу», «что мешает работать быстрее», или просит пересмотреть/улучшить процессы (cadence: 2 weeks → a month)."
---

# pf-retro — reviewing the workflows

Always communicate with the user in the user's language (Russian in the origin system); the retro report follows the template.

Goal: regularly look at the facts (journals, packets, git) and propose improvements. The retro itself is level L1: report and proposals only, change nothing without the human's «ок».

## Data collection (period — since the previous retro)

The paths below are the author's environment (`~/ai` — projects root, `_tools/` — the utility folder, `_tools/reports/` — retro reports); in your environment substitute your own projects root, reports folder and search method.

1. All projects' journals: `~/ai/*/.agents/journal/*.md` for the period (quick slice — `_tools/history-search.sh`).
2. Task packets: `blocked`, plus those hanging in `review`/`in_progress` longer than a week.
3. Git: activity per project (`git log --since=...`), projects with no commits at all.
4. Usage: which skills/plugins/agents were actually applied (per journals), which — not once in 2 periods.

## Analysis

- What stalled: blocked packets, redone work, repeated questions to the human about the same thing.
- Discipline: where the journal was not kept, where packets closed without «Результат» — holes in the history.
- Automation candidates: anything repeated by hand ≥3 times over the period.
- Automation maturity levels — per `references/maturity-scale.md`; promotion only after 2 clean runs, an incident = demotion.
- Dead weight: skills/plugins/agents unused for 2 periods — detach candidates (less context — lower limit spend).
- Context (if the pf-handoff companion is installed): review `~/.claude/context-state/compacts.log` and the period's HANDOFF quality; adjust §13 thresholds by facts.

## Output

1. Report `_tools/reports/retro-YYYY-MM-DD.md` per `references/retro-template.md`.
2. Proposals as a list, each with price, risk and "what happens if we don't" (§0).
3. Record the human's decisions in the report; accepted changes — as separate tasks.
