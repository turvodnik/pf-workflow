---
name: pf-do
description: Выполнить один тикет в свежей сессии — с доказательствами и коммитом. Executor contract for one task packet (ticket) in a fresh session — execute, prove by verification, commit, update status/Результат/journal. Use when asked to «выполни тикет T-###», «выполни task-пакет T-###», «возьми пакет в работу», run a task packet, execute ticket T-###.
---

# pf-do — executing a task packet

Always communicate with the user in the user's language (Russian in the origin system). File formats, section names and statuses stay exactly as written below.

You are the executor of one packet. The context is minimal by design: the packet + AGENTS.md. Do not ask for other chats' history — the packet must contain everything needed; anything missing is a blocker, not a license to guess.

## Steps

1. Read the packet `.agents/runtime/tasks/T-###-*.md`, the project's AGENTS.md and the global rules. If any dependency in `depends_on` is not `done`/`review` — stop and report. If a task HANDOFF is kept (pf-handoff companion, §13) — honor its «Состояние» and «Не делать».
2. Set `status: in_progress`, `owner: <you>`, refresh `updated`.
3. Execute the task step by step. §11 principles: minimal targeted edits; found a bug — root cause first (systematic-debugging), then the fix. Long packet — record progress as you go (interim notes in «Результат»; with the pf-handoff companion installed — a HANDOFF checkpoint, §13) instead of hoarding it until the end: hit the window limit and the finished part must not be lost.
4. Blocker (no access, contradiction in the task, neighboring code broken): `status: blocked`, reason in «Результат», journal entry, stop. Do NOT slip past a blocker with a silent "almost done". **Commit what was done before the blocker** («T-###: blocked — сохраняю сделанное, <причина>»): the working tree stays clean and the next session sees how far you got. The status stays until a human unblocks.
   Special case — **secrets**: the task needs a key value but `ai-secret` is unavailable in your mode (subagents and headless runs are often restricted) — that is an immediate blocker: `blocked` + «нужна интерактивная сессия с доступом к scope <имя>». Do not work around it, do not ask for the value in chat, do not burn rounds on it.
5. Before finishing — check EVERY acceptance criterion against fresh command output (verification-before-completion). No proof — not done.
5a. **Optional second opinion (only if the ticket touched code).** Run `SC=$(ls ~/.claude/skills/pf-do/scripts/codex-review.sh ~/.codex/skills/pf-do/scripts/codex-review.sh ~/.gemini/skills/pf-do/scripts/codex-review.sh 2>/dev/null | head -1); if [ -n "$SC" ]; then bash "$SC" --scope uncommitted; else echo "no script — skip this step"; fi` (the resolver covers every surface the installer writes to; no script — the step is skipped, not an error). It prints `SKIP:` and changes nothing when Codex is absent, unconsented, or the diff is docs-only — that is the normal path, not a failure, and never blocks the ticket. On `OK:` read only the printed digest; open the report file when findings exist. Confirmed findings inside this ticket's scope — fix now and note in «Результат»; anything outside — an observation, not a licence to touch neighbouring code. `FAIL:` means "not reviewed", never "clean". Details and traps: `references/codex-review.md`.
6. Fill in «Результат»: what was done, commits, deviations, proofs. A proof is command output, not a from-memory retelling (a claim without a check is a false proof — the reviewer catches it and returns the ticket). Set `status: review` — `done` is set by the human or the reviewer.
7. Commits for this ticket are mandatory: small, with clear messages; secret-scan before committing; hashes go into «Результат» (pf-replan uses them for targeted rollbacks); push to the project's private remote. Journal entry (§10).

## Forbidden

- Scope creep ("fixed the neighbor while at it") — record observations in «Результат»/journal, touch nothing.
- Claiming success without fresh proof for every criterion.
