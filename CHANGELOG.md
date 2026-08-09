# Changelog

*[Русская версия](CHANGELOG.ru.md)*

## v1.0.0 — 2026-08-09

Initial release of the distribution.

- 5 pipeline skills: pf-spec (interrogation → SPEC), pf-tickets (SPEC → self-contained task packets, with a parallelism gate), pf-do (executor contract, one commit per ticket mandatory), pf-replan (mid-course changes: impact classes A/B/C, `cancelled` status), pf-retro (L1→L3 automation maturity scale).
- 3 agents: pf-architect, pf-executor, pf-reviewer.
- docs/rules-sections.ru.md — ready-made rule sections §7–§12 (generated from the canon by the sync script).
- docs/PROCESS.{ru,en}.md — full process description; README in Russian and English.
- install.sh (symlinks into Claude Code / Codex / Gemini), sync-from-tools.sh (releases from the canon).
- The session-continuity subsystem ships as a separate companion tool: github.com/turvodnik/pf-handoff.
