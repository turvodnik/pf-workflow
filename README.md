# pf-workflow — a spec-driven workflow toolkit for multi-agent CLI development

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE) [![Release](https://img.shields.io/github/v/release/turvodnik/pf-workflow)](https://github.com/turvodnik/pf-workflow/releases) [![tests](https://github.com/turvodnik/pf-workflow/actions/workflows/tests.yml/badge.svg)](https://github.com/turvodnik/pf-workflow/actions/workflows/tests.yml)

Русская версия: [README.ru.md](README.ru.md)

Rules, 6 skills and 3 agents that turn work with CLI agents (Claude Code, Codex, Gemini) from "one endless chat" into a managed process:

```
idea → pf-spec (interview → SPEC.md) → pf-tickets (slice into tickets)
     → pf-do (execute a ticket in a fresh window) → pf-replan (change of course)
     → pf-retro (process review every 2 weeks)
     → pf-auto (autopilot: the same pipeline driven end-to-end by subagents — explicit command only)
     + pf-handoff / pf-resume (session continuity: state cheat-sheet + compaction survival)
```

## Problems it solves

- Big tasks fall apart in a single chat: the context window gets expensive, quality degrades, usage limits burn.
- Decision history ("why we did it this way") is lost between sessions and agents.
- "I changed my mind mid-work" costs a full redo, because nobody knows what depends on what.
- Several agents in one project don't know what the others did.

## Components

| Component | What it does |
|---|---|
| `skills/pf-spec` | Interview until full coverage (one question at a time + a recommended answer) → SPEC.md |
| `skills/pf-tickets` | SPEC → self-contained tickets with dependencies; parallelism gate (≥5 independent → offer a swarm) |
| `skills/pf-do` | Executor contract: fresh window, evidence-based acceptance, commit per ticket, statuses, journal |
| `skills/pf-replan` | Change of course: "spec → tickets → commits" tracing, impact classes A/B/C, surgical rollback |
| `skills/pf-retro` | Retro over all projects' journals; automation trust ladder L1 → L2 → L3 |
| `skills/pf-auto` | Autopilot: subagent waves, a review gate at every milestone, fix loops ≤3 with model escalation, parallelism ≤2, safety stops. Without a subagent tool, `council.sh run` commits the agent's work after a secret scan — needs gitleaks ≥ 8.19 in PATH (the `gitleaks git` command; macOS — `brew install gitleaks`, Ubuntu/Debian — the binary from GitHub Releases: apt ships the older 8.16) |
| `agents/` | pf-architect (spec + slicing), pf-executor (one ticket, Sonnet-class), pf-reviewer (acceptance with evidence) |
| `hooks/wait-guard.sh` | Claude Code `Stop` hook: a turn may not end in prose while this session's registry still has a running job (I-029). Lives next to other Stop hooks (Orca, the Codex plugin's stop-review-gate): Claude Code runs every registered Stop hook in the order they stand in the hooks settings, each decides alone — a block from any one stops the turn, our exit 0 never overrides a neighbour; ours reads only stdin + transcript, writes nothing, prints one reason line, yields on any doubt |
| `hooks/pf-session-id.sh` | Claude Code `SessionStart` hook: prints `Сессия: <full session_id> — это значение поля session_id в HANDOFF/реестре`, the value the registry's `session_id:` needs for `wait-guard.sh` to recognise it. Silent when pf-handoff's own start hook already prints that line, and in agents started by `council.sh` |
| `docs/rules-sections.en.md` | Ready-made rule sections §7–§12 for your global AGENTS.md/CLAUDE.md, written for your machine (no paths of the author's environment) — [RU](docs/rules-sections.ru.md) |
| `docs/PROCESS.en.md` | Full process description from idea to retro ([RU](docs/PROCESS.ru.md)) |

Session continuity (live state cheat-sheet, 40/60/75 % window thresholds, compaction survival) is a **separate companion tool, [pf-handoff](https://github.com/turvodnik/pf-handoff)**: the pf-handoff/pf-resume skills, hooks and rules section §13. The two tools work together but are installed and evolve independently.

## Key principles

1. **Files are the only bus between agents.** Tickets, journal, cheat-sheets are plain Markdown in git — works with any CLI agent, readable by humans.
2. **A fresh window per ticket.** The executor sees only the ticket + project rules — cheap on limits, sharper in quality.
3. **A commit per ticket.** Hashes are recorded in the ticket → rolling back an idea = reverting two commits, not "the whole project".
4. **Evidence before "done".** Success may only be claimed with fresh verification-command output.
5. **Automation trust climbs a ladder: L1 (report only) → L2 (apply with confirmation) → L3 (autonomous, with a kill switch).** Promotion after 2 clean runs.

## Install

```bash
git clone https://github.com/turvodnik/pf-workflow.git && cd pf-workflow
bash install.sh          # copies skills into ~/.claude/skills (+ .codex/.gemini if those CLIs exist) and agents into ~/.claude/agents
# bash install.sh --update  # refresh existing copies after git pull
# bash install.sh --link    # symlink mode instead of copies (then don't move the clone)
# then paste docs/rules-sections.en.md (or .ru.md) into your global AGENTS.md/CLAUDE.md
# recommended companion: github.com/turvodnik/pf-handoff (session continuity)
```

The installer also registers `hooks/wait-guard.sh` as a Claude Code `Stop` hook and `hooks/pf-session-id.sh` as a `SessionStart` hook in `~/.claude/settings.json`. Each time it changes the file, it first copies the previous contents to `settings.json.bak-pf-workflow` next to it (overwriting the earlier copy; nothing is written when nothing changes), so keep your own copy if you need the original; other tools' Stop hooks (Orca's, for example) are never touched. The entry points into this clone, so do not move the clone — or re-run `bash install.sh --sync` from its new place.

If a registration of the same hook already points at an existing file outside this clone (another copy, a checkout of the author's workshop), the installer leaves it as it is and prints one line per entry:

```
KEPT: Stop → <path> (registered elsewhere; re-run with --force to point it at this clone)
```

KEPT is not an error: it means "someone's wiring is already there". If you want it to run from this clone instead, run `bash install.sh --force` (works with any mode). A registration that points at a file which no longer exists is repaired without `--force`.

**Where to keep `SOLUTIONS.md`.** If `~/.config/pf-handoff/config.json` already exists (pf-handoff wrote it), the installer does not ask. Otherwise it asks the same question as pf-handoff (`1` — your own GitHub repository, `2` — locally, default; silently local with no terminal), or takes `PF_HANDOFF_SOLUTIONS=local|github:<url>`, and writes the same file — including `solutions_path`, the SOLUTIONS file the agent appends to (added to an older file too; for GitHub, clone your repository with the printed `git clone` command).

### Update

```bash
cd <your clone> && git pull && bash install.sh --update
```

The hook entry points into the clone, so `git pull` already updates the hook; skills and agents are copies, so `--update` refreshes them. pf-workflow stands alone: it is installed and updated separately from [pf-handoff](https://github.com/turvodnik/pf-handoff), which has its own `git pull && bash install.sh`. The quiet mode of child CLIs (`PF_COUNCIL_RUN=1`, set by `council.sh`) works with pf-handoff ≥ 2.0.0; with an older pf-handoff the child still gets its start hook's hint to read the HANDOFF and continue — update both.

`.claude-plugin/plugin.json` exists for `claude plugin validate`/`eval` only — it does not declare `hooks`, so installing this repo as a plugin never double-registers `hooks/wait-guard.sh`; the install path above (`install.sh`, writing to `~/.claude/settings.json`) is unchanged.

### Uninstall

Remove only what this installer wrote, keep every other setting (restoring an old backup would roll back everything written since). Run from the clone:

```bash
f=~/.claude/settings.json
if [ -f "$f" ]; then cp "$f" "$f.bak-before-uninstall" && python3 - "$f" "$PWD/hooks/" <<'EOF'
import json, sys
path, ours = sys.argv[1], sys.argv[2]
d = json.load(open(path, encoding="utf-8"))
mine = lambda c: ours in str(c or "").replace("'\\''", "'")
hooks = d.get("hooks") or {}
for evt in list(hooks):
    for g in hooks[evt]:
        g["hooks"] = [h for h in g.get("hooks", []) if not mine(h.get("command"))]
    hooks[evt] = [g for g in hooks[evt] if g.get("hooks")]
    if not hooks[evt]:
        del hooks[evt]
json.dump(d, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
EOF
fi
for d in skills/*/; do n=$(basename "$d"); for s in ~/.claude/skills ~/.codex/skills ~/.gemini/skills; do
  { [ "$(readlink "$s/$n")" = "$PWD/skills/$n" ] || grep -q "^name: $n\$" "$s/$n/SKILL.md" 2>/dev/null; } && rm -rf "$s/$n"; done; done
for a in agents/*.md; do n=$(basename "$a" .md); t=~/.claude/agents/$n.md
  { [ "$(readlink "$t")" = "$PWD/agents/$n.md" ] || grep -q "^name: $n\$" "$t" 2>/dev/null; } && rm -f "$t"; done
```

This drops our `Stop` and `SessionStart` entries (those pointing into this clone's `hooks/`), and the skill and agent copies or links that carry our names; anything foreign stays. `~/.config/pf-handoff/config.json` (the SOLUTIONS choice) is shared with pf-handoff: delete `~/.config/pf-handoff` only if pf-handoff is not installed, and move your `SOLUTIONS.md` out first if you keep it there. Finally remove the rules sections you pasted into your `AGENTS.md`/`CLAUDE.md`.

## For your AI agent

Short steps an agent (Claude Code, Codex, Gemini) can follow as written. Run them in a terminal on the user's machine; nothing here needs the author's environment.

1. **Install.**
   ```bash
   git clone https://github.com/turvodnik/pf-workflow.git ~/pf-workflow
   cd ~/pf-workflow && bash install.sh
   ```
   Expected: `OK: …` lines for 6 skills and 3 agents, a line `install.sh: hooks in …/settings.json — registered: …` and `Done (mode: copy)`.
2. **Check.**
   ```bash
   ls ~/.claude/skills/pf-do/SKILL.md ~/.claude/agents/pf-executor.md
   grep -c -e 'wait-guard.sh' -e 'pf-session-id.sh' ~/.claude/settings.json   # 2 or more
   gitleaks git --help >/dev/null 2>&1 || echo "gitleaks missing or older than 8.19 — needed for council.sh run and delegate --audit (macOS: brew install gitleaks; Ubuntu/Debian: the binary from GitHub Releases, apt ships 8.16)"
   ```
3. **What is installed.** Skills `pf-spec`, `pf-tickets`, `pf-do`, `pf-replan`, `pf-retro`, `pf-auto` (in `~/.claude/skills`, plus `~/.codex/skills` / `~/.gemini/skills` when those folders exist); roles `pf-architect`, `pf-executor`, `pf-reviewer` (in `~/.claude/agents`); two Claude Code hooks in `~/.claude/settings.json` — `Stop` → `hooks/wait-guard.sh` (a turn may not end while this session's registry has a running job) and `SessionStart` → `hooks/pf-session-id.sh` (prints `Сессия: <full session_id> — это значение поля session_id в HANDOFF/реестре`; the agent copies the full id into the registry's `session_id:`); `skills/pf-do/scripts/council.sh` — runs an executor or reviewer as a separate CLI when there is no subagent tool. `council.sh run` commits only after a secret scan, so it needs gitleaks ≥ 8.19 in `PATH` (the `gitleaks git` command). Its own files (`.claude/worktrees/`, `.agents/runtime/council*`) go to the repository's local `.git/info/exclude`, not to `.gitignore`.
4. **Rules.** Show the user `docs/rules-sections.en.md` (or `.ru.md`) and, with their "ok", paste it into their global `~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md`. It is their rules file — do not edit it without asking.
5. **Start working.** Phrases the user (or you) can say: "make a spec" / «сделай спеку» (`pf-spec`, for a large task) → "slice into tickets" / «разбей на задачи» (`pf-tickets`) → in a fresh chat "execute packet T-001" / «выполни пакет T-001» (`pf-do`) → `/pf-auto` — the whole pipeline on autopilot, only on the user's explicit command.
6. **If you see `KEPT: …`.** The same hook is already registered from another copy on this machine. Leave it, or run `bash install.sh --force` from this clone to point it here. It is not an error.
7. **Update.**
   ```bash
   cd ~/pf-workflow && git pull && bash install.sh --update
   ```
8. **Do not move the clone**: the hook entries point into it. If it was moved, run `bash install.sh --sync` from the new place.

## Usage cheat-sheet

- `/pf-spec` — "make a spec" before any large task; `/pf-tickets` — slicing after your "ok".
- New chat window → "execute ticket T-003" — runs under the pf-do contract.
- Changed your mind → `/pf-replan`. Every 2 weeks → `/pf-retro`.
- Pausing / window filling up → `/pf-handoff`, continue in a new chat → `/pf-resume` (companion pf-handoff commands).

## Development & releases

The canon lives in the author's working environment (`_tools/skill-library`); changes arrive here as releases: `bash sync-from-tools.sh` → `CHANGELOG.md` → commit → tag `vX.Y.Z` → push. Ongoing work happens on the `dev` branch; `main` holds released states only. Companion standalone distribution of the context subsystem: [pf-handoff](https://github.com/turvodnik/pf-handoff).

Run the test suite locally with `bash tests/run.sh` (bash 3.2+, coreutils, git, `jq`, `python3`, and a YAML parser for `python3` — PyYAML, or `ruby` if PyYAML is absent. `jq` and `python3` are hard requirements: without either, the suite turns red rather than skipping gracefully. ShellCheck and `actionlint` are the only genuinely optional tools, skipped with a reason when absent). The same command runs in CI on every push and pull request ([`.github/workflows/tests.yml`](.github/workflows/tests.yml)). It never invokes the real Codex CLI or touches the network — a fixture stands in for `codex` throughout. [`tests/known-failures-T017.txt`](tests/known-failures-T017.txt) tracks cases where an un-synced copy in this repo is knowingly red against canon — empty right now, since this release is freshly synced.

Skill and agent instructions are in English. The rules sections come in English and Russian ([docs/rules-sections.en.md](docs/rules-sections.en.md), [docs/rules-sections.ru.md](docs/rules-sections.ru.md)). Artifact templates (SPEC, task packets, registries) are Russian — the author's working language; the process design itself is language-agnostic, and the skills answer in the user's language.

---

**Pifagor Studio** — Vladimir ([@turvodnik](https://github.com/turvodnik)) · [MIT License](LICENSE)
