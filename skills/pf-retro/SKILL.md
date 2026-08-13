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
- **The improvement ledger `~/ai/optimize/IMPROVEMENTS.md` is the standing register.** Reconcile it every retro: move journal «⚙️» marks in, promote candidates that hit ×3, flag `done` rows without a commit proof, and re-surface stale candidates. Tools unused for 2 periods (see Usage above) get a `candidate: ablation` row — non-usage is a FLAG, not a verdict (maybe no fitting tasks arose). The verdict comes from an ablation experiment: the same 3–5 real tasks, arms A (as-is) / B (without) / C (simplified), ≥3 runs per arm, medians compared (a gap smaller than in-arm variance = "no signal, keep as-is" — an honest outcome); metrics: criteria met, interventions, rework, time, tokens incl. the skill's always-on context cost. Blind executor (does not know the arm). Detach/simplify only after LOSING the comparison, C-simplification tried before removal; disciplinary and safety skills (secrets, stops, verification) are never ablated — their value is prevented disasters that 3 runs cannot show. `claude plugin eval` ships a no-plugin baseline arm — use it where the unit under test is a plugin/skill it can drive.
- **Repetition → automation candidates (rule of three).** Scan the journals for the same manual action or the same class of fix appearing ≥3 times across the period (also honor explicit «⚙️» marks agents may leave). For each candidate propose: what to automate (skill / routine / hook / test), why it pays (frequency × cost per occurrence), the price and the risk of automating, and whether it belongs to one project or to the shared skill-library. Boris rule holds: automate the CONFIRMED repetition, never the single incident.
- **Where models/fronts underperform.** From fix-cycle counts and gate returns per journals: which task classes needed escalation or repeated rounds — feed the per-role experience files (`agents/experience/`) and, where checkable, propose an eval task for the real-tasks eval set.
- Automation candidates: anything repeated by hand ≥3 times over the period.
- Automation maturity levels — per `references/maturity-scale.md`; promotion only after 2 clean runs, an incident = demotion.
- Dead weight: skills/plugins/agents unused for 2 periods — detach candidates (less context — lower limit spend).
- Context (if the pf-handoff companion is installed): review `~/.claude/context-state/compacts.log` and the period's HANDOFF quality; adjust §13 thresholds by facts.

## Output

1. Report `_tools/reports/retro-YYYY-MM-DD.md` per `references/retro-template.md`.
2. Proposals as a list, each with price, risk and "what happens if we don't" (§0).
3. Record the human's decisions in the report; accepted changes — as separate tasks.
