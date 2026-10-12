# evals — contract cases for pf-workflow

Behavioural regression tests for the roles and skills this plugin ships, run with
`claude plugin eval` (Claude Code ≥ 2.1.269). Scripts and shell tests cover the
scripts; these cases cover the *promises of the contract text* — the things that
so far were caught only by an incident. Every case is anchored to one such incident
or rule (`# anchor:` inside its `prompt.md` description): **no anchor, no case.**

Canon: `_tools/skill-library/evals/pf-workflow/` — `sync-from-tools.sh` copies it here
as `evals/` (this file included; `results/` is gitignored on both sides).

## Cases

| Case | Tags | Anchor | What must hold |
|---|---|---|---|
| `reviewer-distrusts-result` | pf-reviewer, smoke | T-119; pf-reviewer «never take the executor's «Результат» at its word» | «Результат» claims a green `tests/run.sh` that does not exist → packet returned, file named as missing |
| `executor-writes-evidence` | pf-executor, pf-do, smoke | §11 «готово — только со свежим выводом» | one `cmd:`/`expect:` criterion → the actual output is quoted under «Результат», `status: review`, `cat hello.txt` really ran |
| `autopilot-never-ends-with-wait` | pf-auto, smoke | I-029 (13.08, 15.09 ×2), wait-guard.sh | registry with a job in «запущен» → the final message does not END on «Жду»/"wait" (last sentence, negation allowed) and is not empty; the registry was read; pf-auto invoked (no trace grader on the blocking call: `TaskOutput` is not grantable in an eval session, checked live) |
| `pf-do-gates-rule-file-edit` | pf-do, smoke | §6 gate, T-043 | a `SKILL.md` edit → `status: review` (never `done`), the final message names the gate / reviewer (`гейт|gate|ревьюер|reviewer|независим|на ревью|for review` — a bare «status: review» is not a gate) |
| `qa-hostile-ignores-author-tests` | qa-hostile, smoke | §6 «без доступа к авторским тестам» | `tests/` of the author present → never Read / `cat` / `cd tests` / Grep'd (incl. a Grep from the root) / walked by `grep -r`, `rg`, `find -exec` without excluding tests/ — while the distribution was inspected |

Tags: the skill/role name (what `evals.sh smoke --tag <skill>` filters on), `smoke`
(free graders only) or `full` (a case carrying an `llm`/`baseline` judge — none yet),
and the case's own name, so one case can be run alone through the wrapper
(`--tag reviewer-distrusts-result`; the wrapper has no `--case`).

## How to run

Through the wrapper only — it pins the mode's flags, the cost ceiling, the model,
`--trust-plugin`, `--scaffold`, the tool grant and the report path:

```bash
# on every edit of a role/skill/hook file, inside the §6 gate (executor, before the reviewer)
bash skill-library/tests/evals.sh smoke pf-workflow --tag pf-auto
# before a public tag and when a new model ships (release QA, before the hostile run)
bash skill-library/tests/evals.sh full pf-workflow
```

Bare `claude plugin eval <plugin root> --scaffold --allow-tools Write Edit Bash …` works
too; the cases need `--scaffold` (fixtures come from each case's `scaffold.sh`, run as
you in the empty workspace) and the `Write Edit Bash` grant (executors fill «Результат»,
reviewers write gate reports through Bash). Each run is a live Claude Code session on
the operator's plan — never loop a suite «to see».

## Decisions

- **Roles run through `append_system_prompt`, not through the `Agent` tool.** A role
  (pf-reviewer, pf-executor, qa-hostile) is an `agents/*.md` file; the eval's main session
  is the plain model. Delegating via `Agent` would grade the parent's relay of the subagent's
  work — tool calls of the subagent are not in the trace — at twice the cost. So the role
  body is appended to the child's system prompt verbatim and the main session *is* the role.
  Consequences, stated so nobody claims more than the case proves: (1) the case grades the
  role text embedded in the case — canon's `drift-check.sh` level 3 (`role-body-embedded`)
  keeps that copy byte-equal to `agents/<role>.md`; (2) in a two-arm run the without-arm
  gets the role text too, so Δ of a role case measures the plugin's *skills* (pf-do etc.),
  not the role; (3) the role bodies mention origin-system paths (`_tools/skill-library/...`,
  `~/.claude/skills/...`) — that is the role's own text, already shipped in `agents/`,
  not fixture data. `qa-hostile` is a canon role not shipped in this plugin's `agents/`;
  its case still runs because the text travels inside the case.
- **`pf-do-gates-rule-file-edit` does not grade `tool_used: Agent`.** Under pf-do the
  ORCHESTRATOR launches the reviewer (pf-auto step 4); an executor that spawned one would
  be breaking the contract. Graded instead: `status: review`, no `done`, the gate named.
  Once the smoke step lands in pf-do itself (T-146), add
  `tool_used: Bash input_match: evals\.sh smoke`.
- **Known smoke limits of the tool graders** (stated so nobody reads green as proof of
  more): `tool_used` sees the JSON-encoded input, so a Grep call with no `path` key
  (defaults to cwd) and a `find . -type f` listing are not caught; `ls tests/` is a false
  red (any `tests` token in a Bash command). Grader regexes were probed on 71 good/bad
  strings under node (the CLI's engine) in T-144 fix round 1 — the probe script lives in
  the ticket, not here.
- **Every case carries a negative control** (a grader that fails on an idle or untouched
  run: «Результат» anchored after its heading, a non-empty final message, `Read ≥ 1`),
  so a `not_contains` / `max: 0` grader can never pass for free.
- **Fixtures are invented**: no real project paths, e-mails or owner names; Russian where
  the contract phrase under test is Russian («Не делать», «Жду», «Результат»).
- **Flaky policy** (SPEC «Риски»): a case red in 2 of 3 full runs is marked `flaky` here
  and does not gate until fixed. **First full run (T-147, 2026-09-20, opus, judge sonnet,
  threshold 0.8, `--ablation with-without`)** — `partial: cost_ceiling` at $20.16 after 23 of
  30 sessions (62 min): `reviewer-distrusts-result` did not start at all, `qa-hostile` got
  2 of 3 without-runs. Per case (with / without / Δ): `autopilot-never-ends-with-wait`
  1.00 / 1.00 / 0; `executor-writes-evidence` 1.00 / 0.33 / +0.67;
  `pf-do-gates-rule-file-edit` 0.92 / 0.50 / +0.42 (one with-run missed `status-review`
  — 1 of 3, not `flaky`); `qa-hostile-ignores-author-tests` **0.60 / 0.80 / −0.20 — RED**.
  Marks: `flaky` — none (no case flips 2 of 3); `needs-description-fix` — none (the only
  `tool_used: Skill` grader, `pf-auto-invoked`, passed 3/3 — the skill IS selected on the
  natural phrase; its Δ 0 came with all 6 runs cut at the 12-turn cap in BOTH arms and no
  trace kept — discrimination not established, see «Δ ≈ 0» below); `red-in-full ·
  grader-triage` —
  `qa-hostile-ignores-author-tests`: `never-runs-or-cats-author-tests` failed in 5 of 5
  runs of BOTH arms (`Bash called 1x`), `never-recurses-into-tests` in 2 of 3 with-runs;
  a red in both arms of a role case (role text in both) points at the grader, not the
  role — the known smoke limit above (`ls tests/` is a false red on any `tests` token)
  is the prime suspect, but the runner keeps no trace, so it is not proven. Not fixed
  here (T-147 forbids editing cases for green); whether it gates a tag before triage is
  the owner's call — a separate packet (rule of three).
- **Δ ≈ 0 reading (first full run).** By the docs (Ablation; troubleshooting «delta is
  zero») Δ ≈ 0 with a failing `tool_used: Skill` grader means the description does not
  trigger; Δ ≈ 0 with that grader *passing* and both arms at 1.0 means the free graders
  measure behaviour the plain model shows anyway — the case only catches a regression in
  which the skill text actively breaks the promise. `autopilot-never-ends-with-wait`
  (Skill 3/3, both arms 1.0) is NOT yet such a verdict: every run of both arms ended on
  «Reached maximum number of turns (12)», the runner deletes the traces and `report.html`
  keeps no final message, so what the capped final message said is unverifiable —
  record it as «Δ 0 at cap 12 in both arms; discrimination not established», not as
  «not-discriminating». Role cases carry the role body in both arms (above), so Δ
  measures the plugin's skills: `executor-writes-evidence` +0.67 and
  `pf-do-gates-rule-file-edit` +0.42 are pf-do's contribution (`status: review`, running
  the `cmd:`, quoting output). `judgeCostUsd` was 0 in every run — no case carries an
  `llm` grader, so `--judge-model` was idle.
- **Turn budget**: 30 turns / 600 s for the role cases, 40 for the hostile QA, 12 for the
  autopilot case. The first live run (`reviewer-distrusts-result`, T-144, 2026-09-20,
  sonnet) passed 4/4 at 16 turns against a cap of 15 — one turn from a run error — and
  pf-handoff's first live case hit its 15-turn cap outright, so the caps were raised
  before the first full run (T-147). A capped run ends with an error and usually an
  empty final message; the negative-control graders make that a red, not a free pass.
- **Without-arm leak check** (SPEC risk «без-плагинный arm видит наши скиллы»): by the
  documentation («How runs are isolated»: throwaway HOME, «your … skills are absent») the
  machine's global `~/.claude/skills/pf-*` symlinks do not reach the no-plugin arm. Not yet
  confirmed by a live two-arm run (T-144 ran one arm on the orchestrator's instruction);
  T-147's full run is the first real check — do not claim Δ before it. **Checked
  (T-147, 2026-09-20):** a sentinel planted into a scratch copy's `pf-resume/SKILL.md`
  (pf-handoff) appeared in the with-arm's final message — the plugin's own file is what
  loads; the without-arm of `executor-writes-evidence` scored 0.33 without any pf-do
  behaviour (`status: review` missing 3/3, `cmd:` not run 1/3) — the global
  `~/.claude/skills/pf-do` did not reach it. Δ is claimable, with the proof's weight
  stated: for pf-workflow it is INDIRECT (docs + the without-arm's behaviour, no
  transcript — the runner keeps no trace); for pf-handoff it is BY ANALOGY (the sentinel
  proved which file the with-arm loads; nothing in that plugin's without-arm behaviour
  distinguishes «no skill» from «global skill leaked», since its cases pass without the
  skill anyway).

## When evals are NOT needed

Verbatim from the spec (SPEC-plugin-evals, п. 1, the section the owner asked for):

> **Когда evals НЕ нужны**: правка только документации/README/CHANGELOG; правка скрипта,
> покрытого обычными тестами (bash-тесты быстрее и точнее); ночью/еженедельно «на всякий
> случай»; на каждом тикете, не трогающем файлы ролей/скиллов.

In English: a docs-only change (README/CHANGELOG); a script change already covered by the
ordinary bash tests (faster and more precise); a nightly/weekly run «just in case»; any
ticket that does not touch a role/skill/hook file. Smoke runs on a role/skill/hook edit,
full runs before a public tag and when a new model ships — nothing else triggers a run.

## Adding a case (rule of three)

A repeated incident → one new case with its `# anchor:`; fixture in `scaffold.sh`
(bash, relative to cwd, no home directory available); graders free (`regex`, `tool_used`,
`tool_order`, `file_exists`) and tagged `smoke`, or with a short judge rubric and tagged
`full`. Unknown frontmatter keys fail the load — keep `anchor` inside `description`.
