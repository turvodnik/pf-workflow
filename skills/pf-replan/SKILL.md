---
name: pf-replan
description: Передумал посреди работы — пересобрать спеку и тикеты без переделки всего. Rebuilding the spec mid-execution — a new idea or a changed decision. Impact assessment (what stays, what to rewrite, what to roll back), SPEC edit, ticket cancellation/rewrite, targeted commit rollback. Use when «изменилась идея», «передумал», «пересобери спеку», «откатись на шаг», «/pf-replan».
---

# pf-replan — changing course without losing finished work

Always communicate with the user in the user's language (Russian in the origin system). SPEC, ticket and journal formats stay as specified.

Mid-execution a new idea appeared or a decision changed. Two forbidden reflexes: continuing by inertia ("pity to waste the work") and redoing everything from scratch. The right path — assess the impact and edit surgically.

## Steps

1. **Mini-interview** (1–3 questions by pf-spec rules): what exactly changes and why; is it a new requirement on top, or a cancellation of an already-made decision?
2. **Impact tracing** — along the chain «spec → tickets → commits»: find the SPEC sections the change touches → the tickets referencing them (`spec:` in the frontmatter) → their dependents (`depends_on`). That is the revision zone; everything outside it stays untouched.
3. **Classify and show the human a report** (change nothing until «ок»):
   - **A — additive**: does not touch finished work → append to SPEC + new tickets at the tail. No rollback.
   - **B — changes unfinished work**: done tickets stay valid → rewrite or cancel the unfinished ones (`status: cancelled`, reason in «Результат»), fix the SPEC.
   - **C — invalidates finished work**: some done tickets contradict the new decision → two options, each priced: (1) revert their commits (`git revert`, list — from the tickets' «Результат») + new tickets; (2) rework tickets on top, no revert. Show both, recommend the cheaper.
4. **After «ок»**: edit the SPEC (+ a record in «История изменений»: date, what, why, class A/B/C), mark cancelled tickets, create new ones (by pf-tickets rules), for class C — revert commits strictly by the list. If a HANDOFF is kept (pf-handoff companion) — update it: the cancelled goes to «Не делать» (§13).
5. **Journal** (§10): what changed, the class, what was cancelled/reverted. This is the defense against "why is everything different from the spec?" a month later.

## Why the rollback is cheap

Every ticket records its commits in «Результат» → rolling a ticket back = reverting exactly its commits. Hence the discipline: small tickets, a commit per ticket. Never roll "the whole project back" when you can revert two tickets.

## When NOT needed

A small edit inside the current ticket (S-level) — just do it and mention it in «Результат». pf-replan is for changes touching the spec or other tickets.
