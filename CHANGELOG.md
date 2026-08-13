# Changelog

*[Русская версия](CHANGELOG.ru.md)*

Semver: breaking changes (task-packet frontmatter contract, skill behavior contracts, `.agents/` runtime layout) = major; new features = minor; fixes = patch.

## v1.8.0 — 2026-08-13

Canon re-synced: a stricter dependency gate, `codex-review.sh` hardened further, plus a test suite that watches its own back.

- **Dependency gate is now done-only.** `depends_on` used to clear on a dependency in `done` *or* `review`; `review` alone no longer counts — `pf-auto` may still start a job on a `review` dependency, but only as an explicit, reasoned exception recorded in the wave registry, never silently. Minor, not major: this tightens an existing safety contract (closes a gap where a ticket could start on an unreviewed dependency) the same way v1.5.0's blocked-work-must-be-committed rule did — it does not rename or remove anything a caller depends on.
- **`pf-auto`'s Codex pre-pass no longer hangs on a literal placeholder.** The resolver line in `pf-auto/SKILL.md` used to run `bash "$SC" --base <BASE> --deep` verbatim — bash reads the unquoted `<BASE>` as `< BASE`, a stdin redirect from a file that does not exist (F-15, originally fixed in canon by T-014; this repo's own copy had drifted behind it until this sync). It now reads `PF_AUTO_BASE` from the environment and prints an explicit "no BASE recorded" note when it is unset, instead of failing on the placeholder text itself. `tests/base-exec.sh` (below) is the regression guard for exactly this line.
- **`codex-review.sh` hardened again.** Six findings on top of v1.7.0's eight are closed here: five in the review logic itself — consent is fail-closed on every unreadable, malformed or ambiguous state of the consent file, not only a recorded `false`; `--out` now refuses a FIFO, a dangling symlink and a directory (previously just an existing file), with `noclobber` closing the check-then-write race between the refusal check and the write itself; a Codex run that exits 0 with an auth-failure/rate-limit/traceback-shaped message now reads as "not reviewed", not "0 findings"; a `--base`/`--commit` ref is resolved to a full hex commit SHA before it reaches a prompt or `argv`, so shell metacharacters legal in a git ref name (`;`, `` ` ``, `$()`) can no longer leak through; the timeout watchdog no longer races its own `wait` — bash 3.2 returns from `wait` on a disowned PID immediately, without actually waiting, which used to let a SIGTERM-resistant descendant survive past the deadline — plus a sixth, portability rather than logic: its own two `mktemp` calls move off the BSD-only `-t <prefix>` form that GNU coreutils (`ubuntu-latest`) rejects outright, the same fix as in the test suite below.
- **`--out` no longer clobbers a different file than the one it just checked.** A *relative* `--out` was never absolutized: the F-05 existence guard and the `noclobber` test-write ran in the caller's own working directory, but the actual report write ran later, after this script's internal `cd` to the repo root — so a relative path could resolve to two different files, with the guard protecting one while a plain `>` truncated the other, behind a reported `OK`. Found in a subsequent independent review pass, not by the authored regression test itself: that test always ran from the repo root with an absolute `--out`, the one blind spot this bug lived in. `OUT` is now absolutized immediately after it is decided, before any guard check and before the `cd`; two regression cases were added to `skills/pf-do/scripts/tests/run.sh` to cover it directly (59 → 61 total cases).
- **Strict YAML frontmatter**: `pf-retro`'s `description` is now quoted — unquoted, the `cadence: 2 weeks → a month` aside inside it reads as a nested mapping key under a strict YAML parser. The other eight skill/agent descriptions don't need it: none of them contain that colon-space shape.
- **New: `bash tests/run.sh` + GitHub Actions CI.** One command runs `bash -n` and ShellCheck on every script, validates the workflow YAML, re-runs the `codex-review.sh` safety harness (T-008, 61 cases) and a full-canon YAML-strict frontmatter scan (T-009), checks that every `SKILL.md` resolver line is actually executable (`tests/base-exec.sh`), and two negative controls (a mutated file must turn its own check red). Portable `mktemp` throughout (a BSD-only `-t <prefix>` form silently no-ops the negative controls on `ubuntu-latest`'s GNU coreutils — found and fixed before this shipped, not after). README (both languages) gets the CI badge and a one-line "how to run it locally".
- **The new test suite hardened again, same day (fix round on this release, before tagging):** the workflow-YAML check now SKIPs, not FAILs, when `python3` has no PyYAML module — it used to blame a valid file for a missing third-party module on the exact stock configuration (`python3` present, PyYAML absent) that ships on `ubuntu-latest` and on macOS's Command Line Tools; each of the three sub-harnesses (`codex-review`, `yaml-strict`, `base-exec`) now has its own exit code checked, so one that aborts mid-setup (missing `jq`, no YAML-capable interpreter) can no longer read as "fully green" through the `known-failures-T017.txt` bookkeeping, which only tracks named cases, not "did this even run"; the no-network `grep`'s self-exclusion is anchored to this file's own absolute path instead of matching any file named `run.sh`, so a real `curl`/`wget` added to the transplanted `codex-review.sh` test harness could no longer hide behind it.
- `pf-spec`'s `spec-template.md` no longer hardcodes an owner name in the template body.

Verified: `bash tests/run.sh` — 11/11 GREEN, and — unlike every run before this release — the three re-synced sub-harnesses (codex-review 61/61, yaml-strict 9/9, base-exec 2/2) are green on their own merits, not merely matched against `tests/known-failures-T017.txt`, which is now empty for the first time since it was introduced.

## v1.7.1 — 2026-08-12

Discretionary findings of the v1.7.0 independent QA, all closed:

- `--yes` no longer overrides a recorded refusal: `{"enabled": false}` is a decision the human made (pf-spec writes it precisely so nobody asks again), not a missing answer. A missing file and an unreadable file are now distinguished too.
- The report no longer dirties the working tree — the report directory carries its own `.gitignore`, so pf-auto's "the tree must be clean between waves" still holds in someone else's project.
- Two runs in the same minute no longer overwrite each other's report (seconds in the stamp).
- `--help` printed the first line of code; the script path is resolved across every surface the installer writes to (`~/.claude`, `~/.codex`, `~/.gemini`) instead of being pinned to `~/.claude`, so a machine without it gets a silent skip rather than a bash error; the last Russian comments in an otherwise English file are translated.
- The watchdog now signals Codex's whole process group (`set -m`), so children no longer outlive a timeout.

## v1.7.0 — 2026-08-12

Optional Codex second opinion, wired into the pipeline:

- **New: `skills/pf-do/scripts/codex-review.sh`** — a read-only review of the current diff by the local Codex CLI. The full report goes to a file (`workspace/runs/codex-review/`), only a ~6-line digest reaches the agent's context, so a review costs minutes of wall-clock and almost no window.
- **Nothing is required.** Four silent gates, each exiting 0: no `codex` in PATH → no project consent (`.agents/codex-review.json`) → not a git repo or an empty diff → a diff with only prose and lockfiles. Without Codex installed the pipeline behaves exactly as before — that is the point, not a fallback.
- **Hooks:** `pf-do` step 5a (before `status: review`), `pf-auto` — a pre-pass before a milestone gate (`--deep`, never replacing the reviewer subagent), `pf-spec` step 4a — the single consent question, asked while the spec is written and only when `codex` exists on the machine, `pf-handoff` step 2a (companion tool) — on closing a session that still holds uncommitted code.
- **`pf-do/references/codex-review.md`** — the runbook: the two review modes and why a focused pass cannot use the native reviewer, the model policy (`gpt-5.6-luna`/`max` fast lane, `gpt-5.6-sol`/`xhigh` deep lane, `ultra` banned), and the traps: `codex exec review` always exits 0, an empty report means the run died, `codex exec` hangs forever without `</dev/null`.
- **Why a reviewer that does not replace §6:** Codex frames the native review itself, so the caller's blind spot stays out of the prompt — but it runs on the same machine against the same repository. It is the cheap half of the check, not the independent audit.

Eight defects of the tool itself were found and fixed before release, six of them by Codex reviewing this very script: an argument without a value spun the parser forever; `--deep` did not override a fast-lane project config; configs, CI workflows and schemas were filtered out as "docs"; untracked files were invisible in focused mode; an unwritable `--out` reported "OK, 0 findings"; the watchdog sent a single SIGTERM with no follow-up kill; `-s` did not distinguish a directory from a file (a second false-clean path); and the watchdog killed a subshell wrapper instead of Codex itself.

Independent QA before release added two more, both fixed: the watchdog held the script's stdout, so a caller reading the output through command substitution hung until the timeout budget expired *after* a successful review (and stray `sleep` processes piled up); and file names containing spaces or non-ASCII come back quoted from git, so the docs-only gate failed to recognise them — path lists are read with `-z` now. Also fixed: the native mode now pins `sandbox_mode="read-only"` it already claimed in the report; consent is no longer ignored with a wrong reason on a machine without both `jq` and `python3`; `"True"` in the consent file means the same everywhere; an unknown flag reports on stdout, where the caller is told to read.


## v1.6.1 — 2026-08-12

English follow-up (discretionary findings of the v1.6.0 independent QA):

- The three agents (`pf-architect`, `pf-executor`, `pf-reviewer`) are rewritten in English, same format as the skills: a Russian one-liner leads the description, protocol literals and priorities stay verbatim, and each agent answers in the user's language.
- `install.sh` messages and comments are English (logic unchanged).
- README language note now covers the agents; the English changelog quotes the pf-do blocker commit literal in its actual Russian form.

## v1.6.0 — 2026-08-12

Skills rewritten in English:

- All six skill instruction bodies (`pf-spec`, `pf-tickets`, `pf-do`, `pf-replan`, `pf-retro`, `pf-auto`) and the instructional references (`dispatch-templates`, `maturity-scale`) are now English — ≈35–45% fewer tokens per skill load, readable by the international audience. Trigger phrases in the descriptions stay bilingual.
- **Descriptions lead with a Russian one-liner.** Each skill's `description` opens with a short Russian phrase ("what and why") before the English text: the origin system's human reads the skill list with his eyes, and after the English rewrite that list stopped speaking his language. `pf-retro` also gained the Russian trigger phrases it was missing. Nothing in the skill logic depends on the leading phrase — for a monolingual fork, delete it.
- Behavior contracts unchanged: packet statuses, section names («Результат» etc.), journal format and the pf-auto dispatch-prompt protocol literals are kept verbatim. Artifact templates (`spec-template`, `task-template`, `registry-template`, `retro-template`) deliberately stay Russian — the origin system's artifacts are Russian; replace them with your language if needed. The skills now instruct the agent to answer in the user's language.
- Verified before release: a 20-phrase Russian trigger test (2 runs before / 2 after, 80/80 match, including the §8 autopilot key phrases) and a live executor run — output language and artifact formats unchanged.

## v1.5.0 — 2026-08-11

Findings from a second isolated test run (edge cases, not the happy path):

- **pf-do**: work done before a blocker must now be committed too (the commit-message literal is Russian: `T-###: blocked — сохраняю сделанное, <причина>`, "saving what was done") — an uncommitted tail breaks the next gate's diff and is lost when the session changes; evidence in "Result" must be command output, not a recollection (a run produced a "4 sentences" claim where the file had 3 — the milestone gate caught it).
- **pf-do / pf-auto**: a ticket that needs a secret is an immediate blocker — subagents and headless runs cannot call the secret helper. Such tickets are not sent through the fix loop; they are flagged "needs an interactive session" and, when known in advance, kept out of the waves entirely.
- **pf-auto**: a working-tree hygiene check between waves.
- Verified in the sandbox: milestone gating (one reviewer over three independent batches, caught a false claim), executor behaviour on contradictory criteria / missing source material / unavailable secrets (three correct BLOCKEDs, nothing invented), and orchestrator continuity — a successor given only the HANDOFF restored the goal, the registry, the exact next step and the blockers, and spotted the uncommitted tail the orchestrator had missed.

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
