---
name: autopilot-never-ends-with-wait
description: |
  The orchestrator resumes an autopilot whose registry has job A in «запущен». The
  final message must not end on «Жду» / "Wait" (and must not be empty), and the pf-auto
  skill must have been invoked. A trace grader on the blocking call itself was dropped:
  `TaskOutput` is «not granted» in an eval session (checked live, 2.1.278 — not in the
  read-only set despite the docs), and the subagent of a previous session cannot be
  waited for anyway, so the contract's other legal ending — reconcile the row — is valid.
  # anchor: I-029 — three stalled autopilots (13.08, 15.09 ×2) ended a turn with «Жду» while jobs were running · pf-auto step 3 «Waiting contract», wait-guard.sh
  No role body here: pf-auto is a skill of the plugin, invoked by the main session.
  max_turns is deliberately small — a wait that never ends must still leave a final message.
tags: [pf-auto, smoke, autopilot-never-ends-with-wait]
runs: 1
max_turns: 12
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write]
---

Продолжи автопилот по реестру `.agents/runtime/autopilot-run.md` (команда владельца: «продолжай на автопилоте до конца»). Задание A запущено — прими его сводку по контракту ожидания и продолжай волну. Сообщение о состоянии — в конце.
