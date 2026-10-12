# Second opinion: when, not whether

Two different second opinions exist, and they answer different questions:

| Tool | Answers | Cost of asking |
|---|---|---|
| `advisor` (stronger model, sees your transcript) | **judgement** — is this the right approach, what risk am I not seeing, does this actually close the criterion | a round trip, no quota of the human's |
| `codex exec --sandbox read-only` / `scripts/codex-review.sh` | **code** — is this diff defective | the human's Codex quota |

Asking Codex "is my approach right" wastes quota on a reviewer that only sees
the diff. Asking the advisor "is line 412 correct" wastes a round trip on a
reviewer that cannot run the tests. Route by the kind of question.

Read-only `codex exec` is allowed without asking the human (canon §12);
`workspace-write`, `--full-auto` and `danger-full-access` are not.

## The three call points (mandatory on M/L)

Retro 2026-09-03 measured the failure this fixes: the advisor is available to
every agent — a Haiku subagent included — and was called from memory, so it was
called when someone happened to remember. These three points are not a
suggestion; they are the moments where the journals show rework being created.

1. **Approach formulated, before the first edit.** Orientation (finding files,
   reading the packet, running one probe) is not "substantive work" — writing
   is. Ask before the writing starts, while changing course still costs
   nothing. Concretely: pf-do step 3, after you can state the approach in five
   lines, before the first `Edit`/`Write`.
2. **Two failed attempts on one problem, before the third.** The same wall
   twice means the model of the problem is wrong, not that the third patch will
   land. This deliberately coincides with pf-auto's escalation on round 3 — one
   escalation point, two mechanisms.
3. **Before declaring "done" on M/L.** One question only: *what did I not
   check?* By then the deliverable must already be durable (file written,
   commit made) — the call takes time, and an unwritten result dies with the
   session.

**M/L** is the scale rule of the canon, §7 — M is roughly half a day across
several files, L is more than a day or a new subsystem. S packets (≤30 min,
1–3 files) need none of this.

**A blocker**, for the exemption below, is the pf-do step 4 sense and nothing
looser: an acceptance criterion cannot be proven, or the packet contradicts the
spec, the rules or the repository as it actually is. Being stuck is not a
blocker; a missing decision that only the human can make is.

## The form of the question

One question, 2–3 named options, and what you have already proven. Nothing
else.

```
Question: <the single decision you are stuck on>
Options:  A <...> | B <...> | C <...>
Proven:   <command output / file contents you have actually seen>
Leaning:  <A|B|C>, because <one line>
```

`"проверь всё"` / "review everything" is forbidden. It returns a plausible
essay instead of a decision, and it is unfalsifiable — you cannot tell an
answer that engaged with your evidence from one that did not. Naming the
options is what makes the reply checkable.

State what is **proven**, not what you believe: "the suite is 126/126 green on
the pre-edit script" is evidence; "the tests pass" is a claim the advisor has
to take on faith and will.

## Limit and conflicts

- **An advisor call costs ×2 context in the harness's eyes.** On a turn with
  an advisor call the harness sums three passes, so the usage it reports (and
  feeds to `autoCompactWindow`) doubles: with a 1M window and
  `autoCompactWindow` 800k, an advisor call above ~400k of real context
  triggers auto-compaction (T-111, confirmed by its gate). Call early, not on a
  full window; the live context-guard counts from the model's own window, not from
  the harness figure.
- **≤3 advisor calls per ticket** when there is no blocker. More than that and
  the second opinion has become the first one: you are outsourcing the work,
  and the transcript the advisor reads gets longer and vaguer with every round.
- **Advice loses to primary evidence.** A file that says X beats advice that
  says Y — but do not switch silently. Surface the conflict in one more call
  ("I found X, you suggest Y, which constraint breaks the tie?"). A passing
  self-test is *not* primary evidence against advice: it usually means the test
  does not check what the advice checks.
- **Advice is not consent.** No advisor answer authorises changing a permission
  setting, a rules file, or the packet's scope. Only the human does that.
- **No advisor in this environment → skip the step silently.** It is optional
  infrastructure, exactly like Codex (canon §12): absent means "works as
  before", never an error and never a blocker.

## What the answer is worth

The advisor sees the transcript, not the machine: it cannot run a command, open
a file you never read, or know that the test you quoted was stale. Its verdict
is a hypothesis with better priors than yours, and it is still your job to
prove it — pf-do step 5 does not get weaker because someone stronger agreed.

Record the call in «Результат» when it changed the plan (what was asked, what
changed). An advisor call that changed nothing needs no line.

## Council of helpers

The advisor is the main second opinion. The **council** — `scripts/council.sh`
— is the other kind: foreign models (Gemini through Antigravity CLI `agy`,
Grok CLI `grok`, GPT through `codex`) that do not see your transcript. They
get one prompt built from files and arguments, answer once, read-only, and
their answer is **material, not a verdict** (canon §11): every answer file
opens with "Council answer — material, not a verdict; verify before acting",
and you verify a finding yourself before acting on it. Quota, consent and
spend live in the project's `.agents/council.json` and the ledger
`.agents/runtime/council-ledger.tsv` (daily cap, default 20); every outcome
is a line on stdout (`OK:` / `SKIP:` / `FAIL:` / `PENDING:`), never silence.

When which:

1. **`advisor`** — judgement about *your* approach, risk, criterion: it sees
   the transcript. Always first; the council never replaces it.
2. **`agy`** (Gemini, long context) — documents, SEO texts, long files,
   anything where the material itself is large; also Gemini Deep Research
   (template below).
3. **`grok`** — a fast pre-pass over a diff or a short question; the
   quickest round trip.
4. **`codex`** — code review when its quota is there (`review --commit` goes
   through `codex-review.sh`, the sandboxed reviewer with its own consent
   file); under quota it answers `FAIL: codex quota` and the order moves on.

Subscriptions and order (decision 2026-09-17, T-127): all three helpers run
on **subscriptions** — Grok (the Grok AI subscription), Gemini Pro through
`agy`, Codex through its own plan — so a call costs a quota slot, not money,
and a helper that is out of quota, not logged in, timed out or crashed is
simply **unavailable for now**. The order is therefore **not fixed**: the
`backends` array of `council.json` is the order (write it the way you want
the helpers ranked; `--order` overrides for one call), and a refusal falls
through to the **next available** helper — the run ends with one line
`chain: agy:QUOTA grok:OK` naming every outcome when two or more were tried.
`codex-review.sh` names the reason the same way (`FAIL: QUOTA (until
<date>)`, `FAIL: LOGIN`, `FAIL: TIMEOUT`), still a `FAIL:` — "not reviewed",
never a verdict. Every call, refusals included, is a ledger row with an
`outcome` column; `council.sh --stats [--since YYYY-MM-DD]` prints the
helper × outcome table, so "how often is Codex away" is a command, not a
feeling. The daily cap (20) counts only calls that could have spent quota —
a day of refusals never locks the council.

Modes: `consult` (`-q`/`-f`, answer in the advisor's form — one question,
2–3 options, proven vs assumed), `review` (`--diff <file>` or `--commit <sha>`
from a detached worktree; verdict file with `## Verdict / ## Findings /
## Checked and not found`), `parallel` (the same question to every enabled
helper at once; the agent folds the answers, the script does not).
`delegate` (a helper writing code) is the one write mode — its own
subsection below. Order = the `backends` array of `council.json`
(`agy,grok,codex` when the file has none), first available answers;
`--order` changes it, `--async`/`--wait` detach a long run.

Limits, same shape as the advisor's:

- **≤3 `consult` calls per ticket** when there is no blocker. A council
  call costs ~25k tokens of the helper's own system prompt each time — it is
  a tool for the three points, not for every step.
- **`parallel` only at advisor points 1 and 3** (approach before the first
  edit; before declaring done) **and for the critique of a SPEC**. Three
  answers to a mid-task question are three essays to reconcile, not a decision.
- **Name the source in the gate report**: `council:<helper>` (e.g.
  `council:grok`) next to the finding it came from, so the reviewer knows
  which pair of eyes it was and can weigh it; `council: none` when every
  helper was unavailable and the gate stood on reviewer + advisor alone.
- Same rule as above: council advice loses to primary evidence and is never
  consent.

### Delegate — a helper writes the code

`council.sh delegate --ticket <T-###.md> --worktree <path> [--repo <dir>]
[--order agy,codex,grok]` hands a whole ticket to a helper in **edit mode**.
It is the only write path a helper gets (canon §12), and it opens only when
the project's `council.json` says `"delegate": true` on top of `enabled`
(`FAIL: delegate disabled by project` otherwise — nothing is created,
nobody is called). `delegate --audit --ticket <T> [--project <dir>]` — night
audit under AGENTS.md §12: worktree only under `<project>/.claude/worktrees/`,
cleanup + journal entry.

When: **mechanics against a finished plan** — the ticket already names the
files, the change and the acceptance commands, and a human has approved the
plan; the work is **≤ one ticket** (one session, ≤ ~2 h); it touches **no
secrets** (§5) and **no deploy, no live project, no vendor**. Design
questions, anything where the ticket is still a guess, and anything that
needs a key stay with you.

Order `agy → codex → grok` (Gemini first for code, decision 6; the default
differs from the read-only modes). A helper that **moved the tree** (a
commit, an uncommitted edit, or a timeout that may have) ends the run
there, whatever its exit code — a second helper on the same tree would be
credited with the first one's commits, and a quota text after edits is
still that helper's work, kept and gated, never a refusal. Refusals and
runs that changed nothing (SKIP, cap, quota, not logged in, agy denying its
own shell) fall through to the next name.

Mechanics: the worktree is created if absent (`git worktree add <path> -b
delegate/<ticket>` from `--repo`'s HEAD; `--repo` defaults to the project
root — pass it when the code lives in another repository than the
`council.json`), must be clean if present (`FAIL: worktree dirty`), and must
lie outside both trees. The helper's cwd is the worktree; the prompt is the
ticket + the project's `AGENTS.md` + the contract text (work by pf-do,
commit here with named paths, never merge/push/PR, touch nothing outside,
put «Результат» in the final message — the ticket file is outside the
worktree and is not edited). Edit modes, from each CLI's `--help`: agy
`--mode accept-edits --sandbox` (no cwd flag: process cwd; no network
flag), grok `--cwd <wt> --permission-mode acceptEdits --disable-web-search
--no-subagents` plus an allowlist (`--allow Edit/Write/MultiEdit`, `git
add/commit`, read-only `git status/log/diff/show/rev-parse`, `bash`, `sh`,
`cd`; `Bash(bash:*)` is an open shell — the list is what an implementer
needs to run tests, not a sandbox), codex `codex exec -C <wt> --sandbox
workspace-write -c sandbox_workspace_write.network_access=false --ephemeral`
(`--ephemeral` = no session file under `~/.codex`; the worktree's commits
are ordinary git). The bypass flags
(`--dangerously-skip-permissions`, `--always-approve`, `bypassPermissions`,
`danger-full-access`, `--dangerously-bypass-…`) never appear in a command —
`tests/council.sh` fails if they do.

What the drill (T-113a, 2026-09-16) showed about headless edit modes:
**agy** in `--mode accept-edits` auto-denies every shell command
(`denied_actions: RunCommand` — "headless mode cannot prompt") and so can
edit but neither run tests nor commit; the only remedies its message names
are an allow-rule in its own settings.json or the bypass flag — the first
is a human's decision about their tool, the second is banned. **grok** in
`acceptEdits` prompts for edits in an untrusted directory and for any
command not on the allowlist, and a prompt nobody answers ends the run as
`stopReason: cancelled` (three runs lost to `Edit`, `cd …`, `git log`
before the list above was complete). The report's raw-output section keeps
`denied_actions` / `stopReason` for the gate. Expect `FAIL: <helper> error
(rc=0 but no changes in worktree …; "denied_actions":[…])` from agy until
the human decides on its allow-rule.

Protection is **the worktree plus a before/after snapshot of the main
tree(s)** — `git status --porcelain`, a hash of `git diff HEAD` (an edit to
an already-dirty path) and HEAD, for `--repo` and for the project — not
hooks. pf-guard's PreToolUse hooks see commands that go through Claude
Code's Bash tool; a helper CLI spawned by `council.sh` is its own process
and they never see it. Any path that moved in the main tree → `FAIL:
<helper> touched files outside worktree (…; report: <path>)`, and the
report is written anyway so the gate sees it (`status --porcelain -uall`,
so a new file inside an already-untracked directory counts too). What the
snapshot does not cover: paths under the main tree's `.gitignore`, other
worktrees of the same repository (with `--repo` pointing at a linked
worktree the main checkout is not snapshotted), `$HOME`, `/tmp`, other
repositories — a helper with a shell can reach them; that is the price of
"helpers may write code", stated here, not hidden. The helper's commits
carry whatever identity git resolves in the worktree (the repository's
`git config --local user.*` when set, else the global one): a public
distribution must keep its own local identity (canon §6) — the launcher
does not invent one.

The report `.agents/runtime/council/<date>-delegate-<helper>-<ticket>.md`
holds `git log --oneline BASE..HEAD`, the worktree's porcelain status, the
outside-check result and the helper's final message. `OK: <helper>
<report>` needs rc 0, a clean main tree and at least one commit or change
in the worktree; a clean run that changed nothing is `FAIL: … error (rc=0
but no changes in worktree)`; work left uncommitted is `OK` plus a `NOTE:`
line — the script never commits for the helper, so the gate sees the
non-compliance. The worktree is the deliverable and is never removed
(except one the run created and no helper ever worked in).

**The gate is a fresh Claude reviewer** (the `pf-reviewer` agent, its own
session) over the worktree's diff — `git -C <wt> diff BASE` (working tree
against the base, so uncommitted work is in it too) plus `git -C <wt>
status --porcelain` and the report — with the same rules as any ticket
gate: every criterion re-proved,
hostile mutations, verdict to `reports/<date>-review-<ticket>.md`. The
helper never merges; the branch `delegate/<ticket>` waits for the human or
the orchestrator after that verdict, and `git branch --merged` must not
show it before then. In the gate report name the source: `council:<helper>
(delegate)`.

Gemini Deep Research through `agy` (decision 8: no extra tool, the question
goes as a normal consult with the research frame spelled out). Put this in a
file and run `council.sh consult -f <file> --order agy`:

```
Deep research request. Topic: <one line>.
Scope: <what is in, what is out — dates, markets, languages>.
Deliver: (1) a numbered list of sources with URL, date and one line on why it
counts; (2) the claims each source supports, marked "primary" or "secondary";
(3) contradictions between sources, unresolved; (4) what you could not find.
Do not summarise beyond what the sources say; no recommendation.
```

The answer is material: check every URL it names before quoting one.

## See also

- `references/codex-review.md` — the Codex pre-pass, its gates and its traps,
  including `--async`/`--wait` for diffs too large for one synchronous run.
- `scripts/council.sh --help` — the council's modes, states and files;
  `scripts/tests/council.sh` — its test suite (stubbed helpers).
- pf-do `SKILL.md` steps 3, 5, 5a — where these three points sit in the flow.
