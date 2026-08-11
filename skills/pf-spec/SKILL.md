---
name: pf-spec
description: Допрос перед большой задачей — вопросы до полного покрытия, на выходе SPEC.md. Interview before a large (L) task — step-by-step questions until full coverage, producing SPEC.md. Use when starting a large task or new project, when the user asks «сделай спеку», «спек-режим», «/pf-spec», or when scope is unclear (scale rule §7).
---

# pf-spec — interview down to a specification

Always communicate with the user in the user's language (Russian in the origin system); SPEC.md follows the template.

Goal: before work starts, learn everything the human decides and record it in SPEC.md. The human answers questions ONCE at the start — then the agents work autonomously.

## Interview rules

1. One question at a time. Wait for the answer. Do not dump a list of ten questions.
2. Attach your recommended answer and its consequences to every question: «я бы выбрал X, потому что …; цена — …». The human may simply agree.
3. Facts learnable from files, code, git or the internet — find YOURSELF before asking. Ask only what is the human's decision: goals, boundaries, priorities, budgets, tastes.
4. Topic order: goal and motivation → boundaries (what we do NOT do) → consumers of the result → data and sources → integrations and secrets (names only, per §5) → acceptance criteria → risks and reactions → timing/priority.
5. Continue until every template section can be filled without invention. "I don't know" — offer a default and mark it in the spec as an assumption.
6. Answer per §0: plain words + the term alongside.

## Output

1. Fill `SPEC.md` per `references/spec-template.md` in the project root (or the phase folder per project convention).
2. Show the human a 10–15 line digest, ask for «ок» or corrections.
3. After «ок» offer `pf-tickets`. A SPEC without the human's «ок» is a draft — no work happens on it.

## When NOT to use

S/M tasks (§7): the interview is overkill there — it wastes the human's time and the limits.
