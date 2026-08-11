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
6. Packet acceptance criteria — verifiable by command or observation; derive them from the spec's criteria.
7. Parallelism gateway (idea after workflow-planner): if ≥5 tickets are mutually independent (no `depends_on` among them) — offer the human a parallel launch instead of a queue: several fresh windows at once (works for any agent) or a subagent swarm in Claude Code. Name the price honestly: parallel — faster in wall time but more expensive in tokens (every executor carries its own context); a queue — cheaper but longer. The human decides.

## Output

1. Files `.agents/runtime/tasks/T-###-slug.md` per `references/task-template.md` (numbering continuous across the project).
2. In SPEC.md, the «Декомпозиция» section: the packet list in order.
3. A digest for the human: a table (id, essence, depends on, executor), what can run in parallel, and the ready launch command for the first batch: new session → «выполни task-пакет T-00N по pf-do» — or with one command `/pf-auto`: the whole pipeline by subagents to the end (the pf-auto skill).
