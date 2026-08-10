# Changelog

*[Русская версия](CHANGELOG.ru.md)*

## v1.4.0 — 2026-08-10

- **pf-auto gating is now risk-based** (`gate = auto`): a gate after every batch when batches build on each other or touch executable artifacts (code, configs, data schemas, scripts, infrastructure); a single gate per milestone when batches are independent and cheap to fix (texts, docs, standalone pages). Three gates stay mandatory in any mode: before a batch that depends on a group's results, before any external action, and the final whole-task review. The chosen mode and its reason are recorded in the run registry, so a retro can tell whether the call was right.

## v1.3.0 — 2026-08-10

- New skill **pf-auto** — autopilot: after spec approval the orchestrator drives the whole task to done via subagents. Waves of 1–3-ticket batches; a mandatory independent review gate per batch; fix loops ≤3 rounds with a fresh executor on a stronger model on round 3; parallelism ≤2 for disjoint batches; safety stops (human-only questions, spec contradictions → pf-replan, irreversible external actions, orchestrator window thresholds); a final whole-task review on the strongest model with a single fix pass. Wave registry in the HANDOFF (pf-handoff companion) or standalone `.agents/runtime/autopilot-run.md`. Dispatch prompt templates in `skills/pf-auto/references/`.
- pf-tickets now mentions the `/pf-auto` launch option; rules §8 gains one line: autopilot only on an explicit human command.
- Verified by a synthetic run: two parallel executors, both gates passed with evidence, a planted SPEC↔ticket drift caught by the final review, a single fix pass + scoped re-review clean, and the stop boundary held (no external publish without the human).
- Independent pre-release QA (per the author's release rule): headline skill count fixed (6, hooks mention removed — they ship with pf-handoff), author-environment paths in pf-retro/pf-architect marked as adaptable, a registry template added for standalone autopilot runs.

## v1.2.1 — 2026-08-10

Independent-QA fixes:

- README (both languages): clone commands switched from SSH (`git@github.com:…`) to `https://` — anonymous installation by the book now works without an SSH key.
- `install.sh --link --update` now really converts existing copies into symlinks; with `--update`, replacement happens only for our own skills/agents (`name:` must match) — foreign same-named items are skipped with a notice.

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
