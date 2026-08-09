# Changelog

*[Русская версия](CHANGELOG.ru.md)*

## v1.1.0 — 2026-08-10

Public release.

- Repository made public under the MIT license; Pifagor Studio signature, noreply commit identity (history rewritten accordingly).
- Standalone operation verified: every HANDOFF mention in the skills is now explicitly optional ("if the pf-handoff companion is installed") — pf-workflow works on its own or together with pf-handoff.
- docs/rules-sections.en.md — English translation of the rule sections; the generated Russian version now notes that §0–§6/§13 references belong to the author's full rule set.
- README footers with authorship and license.

## v1.0.0 — 2026-08-09

Initial release of the distribution.

- 5 pipeline skills: pf-spec (interrogation → SPEC), pf-tickets (SPEC → self-contained task packets, with a parallelism gate), pf-do (executor contract, one commit per ticket mandatory), pf-replan (mid-course changes: impact classes A/B/C, `cancelled` status), pf-retro (L1→L3 automation maturity scale).
- 3 agents: pf-architect, pf-executor, pf-reviewer.
- docs/rules-sections.ru.md — ready-made rule sections §7–§12 (generated from the canon by the sync script).
- docs/PROCESS.{ru,en}.md — full process description; README in Russian and English.
- install.sh (symlinks into Claude Code / Codex / Gemini), sync-from-tools.sh (releases from the canon).
- The session-continuity subsystem ships as a separate companion tool: github.com/turvodnik/pf-handoff.
