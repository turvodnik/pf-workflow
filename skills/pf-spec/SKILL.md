---
name: pf-spec
description: "Допрос перед большой задачей — вопросы до полного покрытия, на выходе SPEC.md. Interview before a large (L) task — step-by-step questions until full coverage, producing SPEC.md. Use when starting a large task or new project, when the user asks «сделай спеку», «спек-режим», «/pf-spec», when scope is unclear (scale rule §7) — or when the human cannot yet NAME the goal: «помоги сформулировать», «не знаю, чего именно хочу», «есть ощущение проблемы», «давай вместе поймём цель» (start with Phase 0, goal discovery)."
---

# pf-spec — interview down to a specification

Always communicate with the user in the user's language (Russian in the origin system); SPEC.md follows the template.

Goal: before work starts, learn everything the human decides and record it in SPEC.md. The human answers questions ONCE at the start — then the agents work autonomously.

## Phase 0 — goal discovery (when the goal is fuzzy — or the echo-check fails)

**Echo-check first, always.** Even when the goal sounds clear, open with one
paraphrase: «Правильно понимаю: <цель своими словами, 1–3 строки>?» — «да» →
straight to the interview; «нет» or «не совсем» → this phase. Ten seconds of
echo against a day of building the wrong thing.

Direct trigger: the human signals they cannot name the goal yet («не знаю,
как сформулировать», «есть ощущение проблемы», a vague pain). A confirmed
clear goal skips the rest of this phase entirely — Phase 0 beyond the echo
on a clear goal is bureaucracy.

This is a CONVERSATION, not a questionnaire. The palette in
`references/goal-discovery.md` lists question THEMES — pick the one or two
that unlock the most right now, skip everything already answered by context,
files, or the journal. Non-negotiables:

- **Facts before questions**: look at the code/journal/site first; never ask
  what you can find out yourself.
- **Drafts over blank pages**: the human reacts better than they formulate.
  After 2–3 answers, offer a DRAFT («я понял так: проблема …, цель …,
  проверим так: …») built strictly from THEIR facts — editing a draft is
  easier than writing one. Propose the acceptance checks yourself; the human
  approves or corrects, they do not have to invent verification.
- **Mirror early and often**, not one big summary at the end. Iterate until
  the human says «да, это оно» — that confirmation, not question count, ends
  the phase. Two questions may be enough; ten may be needed. Both are fine.
- **When in doubt — ask or default, visibly**: a clarifying question is
  always allowed; but first ask yourself «does this detail improve the
  decision, or just complicate it?» If it only complicates — record an
  assumption in the spec and move on instead of asking.
- The confirmed problem+goal (each claim tied to a concrete fact the human
  gave) becomes the spec's «Проблема»; then continue with the normal
  interview below — skipping every question Phase 0 already answered.

## Interview rules

1. One question at a time. Wait for the answer. Do not dump a list of ten questions.
2. Attach your recommended answer and its consequences to every question: "I would pick X because …; the cost is …" (in the origin system the answer is phrased in Russian). The human may simply agree.
3. Facts learnable from files, code, git or the internet — find YOURSELF before asking. Ask only what is the human's decision: goals, boundaries, priorities, budgets, tastes.
4. Topic order: goal and motivation → boundaries (what we do NOT do) → consumers of the result → data and sources → integrations and secrets (names only, per §5) → acceptance criteria → risks and reactions → timing/priority.
4a. **Codex second opinion — ask once, here.** Only when the spec involves code AND `command -v codex` succeeds (otherwise skip the question entirely — never advertise a tool the machine does not have). Ask: may executors run Codex as a read-only reviewer of their diffs in this project? Price: a few minutes and OpenAI quota per ticket; gain: an outside pass that does not inherit our blind spot. On «да» write `.agents/codex-review.json` — `{"enabled": true, "model": "gpt-5.6-luna", "effort": "max"}` — and record the decision in the spec's assumptions. On «нет» write `{"enabled": false}` so nobody asks again. Details: `pf-do/references/codex-review.md`.
5. Continue until every template section can be filled without invention. "I don't know" — offer a default and mark it in the spec as an assumption.
6. Answer per §0: plain words + the term alongside.

## Output

1. Fill `SPEC.md` per `references/spec-template.md` in the project root (or the phase folder per project convention).
2. Show the human a 10–15 line digest, ask for «ок» or corrections.
3. After «ок» offer `pf-tickets`. A SPEC without the human's «ок» is a draft — no work happens on it.

## When NOT to use

S/M tasks (§7): the interview is overkill there — it wastes the human's time and the limits.
