# Changelog

*[Русская версия](CHANGELOG.ru.md)*

## v1.2.0 — 2026-08-10

Clean-machine install fixes (issues reproduced in a sandbox with a fresh $HOME and re-tested green):

- **`install.sh` now installs copies by default** — the clone may be moved or deleted afterwards (symlink mode caused broken links when the clone was relocated). `--link` restores the old symlink behaviour (update via `git pull`; don't move the clone), `--update` refreshes existing copies.
- **No junk directories**: `~/.codex/skills` and `~/.gemini/skills` are touched only if those CLIs are actually present on the machine (`~/.codex` / `~/.gemini` exist).
- **Anti-hijack**: symlinks created by any other skill-management tooling are never overwritten — skipped with a notice (previously `ln -sfn` silently re-pointed them at the clone).
- README (both languages): install modes documented.

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
