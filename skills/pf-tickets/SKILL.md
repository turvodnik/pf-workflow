---
name: pf-tickets
description: Разбить утверждённую спеку на самодостаточные задачи для исполнителей. Splitting an approved SPEC.md into self-contained task packets in .agents/runtime/tasks/ with dependencies and acceptance criteria. Use after SPEC approval, when user says «разбей на задачи», «декомпозиция», «/pf-tickets».
---

# pf-tickets — from spec to task packets

Always communicate with the user in the user's language (Russian in the origin system); packets follow the template.

Goal: turn the approved SPEC.md into packets, each executable in a separate fresh session with no access to this chat. Fresh session = small context = cheaper on limits and more precise in quality.

## Slicing rules

1. A packet is self-contained: the executor will see ONLY the packet + the project's AGENTS.md. Everything needed is inside: file paths, decisions from the spec, constraints.
2. No placeholders: no "fill this in" or "roughly like this". Concrete files, concrete commands, concrete criteria.
3. Size: one packet ≤ ~2 hours of one session's work. Comes out bigger — slice smaller.
4. Dependencies — via `depends_on`; mark independent work as parallelizable.
5. Every packet gets an executor recommendation: owner (claude|codex|gemini|vladimir) and model class (thinking/design — a senior model; mechanics against a ready plan — Sonnet-class).
6. Packet acceptance criteria — verifiable by command or observation; derive them from the spec's criteria. Pinning a criterion to where a report ends? Write «последний содержательный раздел» (last substantive section), not «заканчивается X» (ends with X) — the mandatory mini-glossary (§0) makes itself the literal last section of any long report, so «ends with X» stops being satisfiable the moment X isn't the glossary.
   Sort every criterion before hand-out; one bullet, one kind — split a compound
   bullet first. Ask: **what would this criterion prove if it were green
   tomorrow with no work done?**
   - «nothing — the work would just be invisible» → **change**.
     RUN it on current HEAD before hand-out and it must fail. Already green:
     rewrite it onto something that could not exist before the edit. Write the
     check as fields under the bullet (`cmd:` / `expect:`, optional
     `expect_head:` — what the cmd prints today, taken from the command, not
     by hand — and `cwd:`; format in `references/task-template.md`) so that
     `scripts/criteria-check.sh` can run it instead of you.
   - «that the boundary still holds — nothing broke, nothing went outward» →
     **invariant**. Mark it as one in the packet, and stage its failure once: on
     a copy, on a throwaway clone, or by a mutation carrying an
     `assert old in s` anchor. The author writes the staging step INTO the
     packet; the executor shows the RED output in «Результат» —
     a second green run is not staging.
   - «a person or a probe has to look — the verdict is a judgement, not an exit
     code» → **observation**. Name the artifact inspected and how the decision
     is made. Commands may well be run: «ревьюер сам запускает и цитирует» is an
     observation, because what settles it is someone reading the output.

   A bullet holding both a proof and a guard («хук стоит И запись Orca на
   месте») is split in two, or each half carries its own kind — never sorted by
   whichever half looks bigger. Halves that ALL fail on current HEAD are one
   change criterion, not a compound — split only when one half would pass today
   and another would not. Reasons and cases:
   `references/acceptance-criteria.md`.
   Kind vocabulary on disk is `change | invariant | observation`; the spec
   names `behaviour` / `output` (→ change) and `manual` (→ observation) are
   synonyms — the script accepts them without error, packets may use either.
7. Parallelism gateway (idea after workflow-planner): if ≥5 tickets are mutually independent (no `depends_on` among them) — offer the human a parallel launch instead of a queue: several fresh windows at once (works for any agent) or a subagent swarm in Claude Code. Name the price honestly: parallel — faster in wall time but more expensive in tokens (every executor carries its own context); a queue — cheaper but longer. The human decides.

## Gate G3 — two-way reconciliation before hand-out

Both directions in full, empty lists included; every divergence closed
before work starts, one wording per outcome (`references/gate-g3.md`).

1. **Ticket → spec point** — each `spec:`; resolving ≠ covering (an anchor on a
   non-requirement section, or on another packet's, is unmatched). Orphan packet
   → real work: spec point by delta «найдено в волне, вне исходной спеки» +
   причина, дата; not needed: `status: cancelled`; needs a person:
   `⏳ человек: <что> · <дата>`.
2. **Spec point → ticket** — each requirement of «Что делаем». Uncovered → write
   the packet, or «вне объёма: <причина>» in the spec.

Re-run G3 on every packet born mid-execution.

## Output

1. Files `.agents/runtime/tasks/T-###-slug.md` per `references/task-template.md` (numbering continuous across the project). Its «Ограничения» secrets line is constant — verbatim in every packet (§5).
   Before releasing a packet run `scripts/criteria-check.sh <ticket>` on
   current HEAD (`--cwd <repo>` when the commands live elsewhere); a green
   change criterion (`RED-BEFORE-WORK FAIL`) means the packet is not released —
   rewrite the criterion; `HEAD-MISMATCH FAIL` means `expect_head` was written
   by hand — take it from the command. `NO-CMD WARN` / `NO-CHECKBOX WARN` is the
   old format, still valid; a `RUN-ERROR` (rc 2 — command not found, also as the
   first link of a pipeline, or timeout) is a typo in the criterion, not a red; invariant / observation are skipped by design (they are proven by
   staging and by a reader, not by a green run — pf-do step 6).
2. In SPEC.md, the «Декомпозиция» section: the packet list in order.
3. Once G3 is clean — a digest for the human: a table (id, essence, depends on, executor), what can run in parallel, and the ready launch command for the first batch: new session → «выполни task-пакет T-00N по pf-do» — or with one command `/pf-auto`: the whole pipeline by subagents to the end (the pf-auto skill).
