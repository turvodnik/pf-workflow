---
name: pf-auto
description: Автопилот конвейера — доделать всё до конца субагентами после утверждения спеки. Pipeline autopilot — after SPEC approval, execute everything to the end with subagents. Waves of 1–3 tickets, independent review at every milestone, fix cycles ≤3 with model escalation, parallelism ≤2, stops at dangerous boundaries. Use ONLY on explicit command or phrase — «/pf-auto», «сделай на автопилоте», «сделай сам всё до конца», autopilot. Never enable silently (§8).
---

# pf-auto — autopilot: from approved spec to done

Always communicate with the user in the user's language (Russian in the origin system). Registry, tickets, journal and report formats stay exactly as specified.

You are the orchestrator. You do NOT execute tickets yourself: you dispatch jobs to subagents, accept short summaries, verify through independent hands, and keep the registry. Your window is the most expensive resource: full results live in tickets and files, not in the chat.

## Preconditions

- An approved SPEC.md and tickets in `.agents/runtime/tasks/`. Missing — first the regular `/pf-spec` → human's «ок» → `/pf-tickets`: the interview is not automatable, a human answers the questions.
- An explicit human command (see description). Autopilot enabled silently is a §8 violation.

## Parameters (defaults; the human may override in words at launch)

`fix_rounds = 3` · `parallel = 2` · `batch = 1–3 tickets per job` · `gate = auto` (by risk; alternatives in words: «гейт после каждого» / «гейт по вехам»).

## Cycle

1. **Waves.** Group tickets into jobs of 1–3 related ones (by `depends_on` and volume: a job ≤ half the executor's window — §13 heuristic). Build the wave order; in parallel — up to `parallel` jobs, and only with no shared files. Print the wave plan as one table for transparency and continue without waiting for a reply.
2. **Registry before every wave**: «задание → тикеты → субагент → статус» — in the HANDOFF (if the pf-handoff companion is installed, §13 rule) or in `.agents/runtime/autopilot-run.md` (template — `references/registry-template.md`). Update on every event: summary accepted, review verdict, fix round.
3. **Executor** — a fresh subagent with a clean context (mechanics — Sonnet-class, integration/judgment — a senior model; state the model explicitly). Before launch record BASE (`git rev-parse HEAD`). The prompt — per `references/dispatch-templates.md`: ticket paths + "work by the pf-do contract" + interfaces/decisions from earlier jobs that are not in the tickets + "full result into the tickets, reply with a summary ≤15 lines". Never paste session history into a prompt.
4. **Gate** — a fresh reviewer subagent (pf-reviewer role) gets the ticket paths + the BASE..HEAD diff as a file + the acceptance criteria. It re-verifies with proofs and does not trust the executor's «Результат». Clean → tickets `done` (§9 authority), registry, next wave.
   **When to place gates (`gate = auto`)** — by risk, not mechanically:
   - *after every job* — when jobs build on each other or touch executables: code, configs, data schemas, scripts, infrastructure. An error here sinks into the foundation of the following jobs, and a late find costs a multiple of a reviewer;
   - *one gate per milestone* (a group of jobs) — when jobs are independent and a fix is cheap: texts, documentation, separate pages/articles, markup. The reviewer gets all the milestone's diffs at once.
   - **Always mandatory, regardless of mode**: a gate before a job that depends on the group's results; a gate before any external action; the final end-to-end review (step 7).
   - Write the chosen mode and the reason into the registry in one line — the retro will show whether you guessed right.
5. **Fix cycle ≤ `fix_rounds`**: rounds 1–2 — the same executor, remarks verbatim; round 3 — a fresh executor on a stronger model ("the previous one tried twice — here is its report and the open remarks"). After each round — a scoped re-review strictly against the remark list. Failure after round 3 → tickets `blocked`, this branch of waves halts; independent branches continue; the report goes into the final report (or immediately if everything is halted).
6. **Stops** — the autopilot halts and asks the human:
   - a question only a human can decide (batch them up unless the current wave is blocked);
   - **a ticket needs a secret** (API key, password, token): subagents and headless runs usually cannot call `ai-secret`. Do not push such tickets through the fix cycle — straight to `blocked` with «нужна интерактивная сессия, scope <имя>» and into the report to the human. Visible in advance — pull them out of the waves at planning time;
   - a ticket contradicts the SPEC → a mini-report in the pf-replan spirit (impact class, options);
   - an external irreversible action — publishing to a live site, deploy, mailing, DNS changes, spending money: prepare everything and stop. Commit and push to the private repo are allowed (pf-do rule);
   - orchestrator window thresholds (§13): above 60% — launch no new waves, accept current ones, checkpoint; 90% — full handoff and a stop-point report.
7. **Final**: an end-to-end review of the whole task diff against the SPEC — a fresh subagent on the strongest available model. Remarks → ONE fix pass (one subagent with the whole list, not a fixer-per-remark) + one scoped re-review. Leftovers: non-critical — park in the report with a "why acceptable" verdict; critical — `blocked` to the human. Clean → final report to the human: done / proofs / deviations / parked / statistics (waves, subagents, fix rounds). Journal entry (§10).

8. **Hygiene between waves**: after accepting summaries check `git status` — the tree must be clean. An executor stopped by a blocker must commit its work (pf-do step 4); an uncommitted "tail" breaks the diffs of subsequent gates and is lost on session change.

## Forbidden

- Executing or fixing tickets with the orchestrator's hands: the context is for coordination, and fixes bypassing review are a quality hole.
- Setting `done` without independent verification; skipping mandatory gates (before a dependent job, before an external action, the final one) — «гейт по вехам» does not cancel them.
- Continuing the fix cycle past the limit; silently dropping remarks (only parking with a verdict in the report).
- Running jobs with shared files in parallel.
- Taking external irreversible actions without asking the human.
