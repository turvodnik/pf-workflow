#!/bin/bash
# wait-guard.sh — Claude Code `Stop` hook (pf-workflow, T-110).
# hook-event: Stop
#
# Problem it closes (I-029, three incidents 13.08 / 15.09 / 15.09): an
# orchestrator launches subagents or background jobs, ends its turn with
# "Жду" ("Waiting"), and the harness never starts a new turn on its own —
# the wave stands still for hours. The fix in the skills is the waiting
# contract (pf-auto "Waiting contract", pf-do step 4a): a turn never ends
# while the registry has a running job; waiting is a BLOCKING call
# (`TaskOutput(block=true)`, or a foreground `Bash` whose command is an
# `until`/`while` wait loop or a `--wait`). `Monitor` is NOT a wait: it is a
# background stream ("you keep working"), and the 15.09 stall was lost on
# exactly its kind of notification. This hook enforces the contract at the
# one point the harness gives us — the Stop event.
#
# Decision:
#   exit 2 + reason on stderr — the turn is NOT allowed to end: the registry
#       of THIS session has a running job («запущен») and the turn made no
#       blocking wait. Claude Code feeds stderr back to the agent, which
#       continues the turn. The next Stop of that continuation arrives with
#       `stop_hook_active: true` and passes — at most one nudge per turn,
#       never a loop.
#   exit 0 — everything else: `stop_hook_active: true`, no own active
#       registry, no running job, a blocking wait found — or ANY error
#       ("wait-guard: skipped (<reason>)" on stderr). The contract shared by
#       all our hooks: never fail, never wedge the session. "Cannot check"
#       must never turn into "block".
#
# Own registry = a file whose `session_id` matches the `session_id` from
# stdin: `.agents/runtime/handoff/*.md` with `status: active` in the
# frontmatter, or `.agents/runtime/autopilot-run.md` with a `session_id:`
# line in its head. A foreign active HANDOFF (another session's autopilot
# left in the same project) is ignored on purpose. The id is stored in full
# and "own" is exact equality (R02, 2.1.1: two ids sharing their first 8
# characters used to accept each other's registry). A legacy 8-character
# value (written before 2.1.1) is own only when this session's id starts
# with it AND no other registry here carries an id with the same prefix (a
# full one or another legacy one) — an ambiguous prefix belongs to nobody.
# Neighbouring Stop hooks (Orca, the Codex plugin's stop-review-gate, …):
# Claude Code runs EVERY registered Stop hook in the order they stand in the
# hooks settings file, and each one decides on its own — a block from any of
# them stops the turn, an exit 0 from this one never overrides a neighbour.
# This hook reads only stdin and the transcript, writes nothing, prints one
# reason line on stderr, and yields (exit 0) on any doubt, so it can sit
# before or after a foreign Stop hook without changing that hook's verdict.
#
# A running job = a table row (`| … |`) of the registry whose STATUS cell
# contains the word «запущен» (also запущена/запущено/запущены, перезапущен)
# not negated by «не» («НЕ запущен», «не запущено»). The status cell is the
# column headed «Статус» — the LAST one in pf-auto's registry template; a
# table without that header — its last cell. Some live registries keep
# «Статус» in the middle (6 of 66 tables, 03.10): there it is found by the
# header, and when a row's cells do not line up with the header (a `|` inside
# a cell) the whole row is checked — the safe side for a stall guard. A row
# appended after prose, far below its header (a live registry of a client
# project), is read with the latest header of the file.
# The word in any other cell (the row's history, notes) does not count: two
# of the three live blocks were exactly that (20.09 history cell, 21.09
# «НЕ запущен»; T-154). Anywhere inside the status cell it does count — a
# gate or a fix round noted there («сводка принята; гейт запущен 14:33») is
# a running job, and missing it is the I-029 stall this hook exists for.
# Registry files are read safely (QA 11.10, Ж-1): only a regular file — not a
# symlink, a device, a FIFO or a directory — and at most the first 1 MB and
# 5000 lines of it, BEFORE any parsing; anything else is skipped. A symlink to
# /dev/zero planted in a foreign repository used to grow the hook to gigabytes
# on every Stop; the file-type checks stop that, the limit only bounds a
# giant regular file. Live registries reach ~500 lines / 134 KB (10.10), so
# the limit leaves room; rows past it are not seen and the guard yields.
# A blocking wait = the LAST tool call of the LAST turn of the transcript
# (entries after the last human/notification `user` record) is a `tool_use`
# of `TaskOutput` with `block: true`, or of `Bash` WITHOUT run_in_background
# whose command contains `until `/`while ` or `--wait` — "waited for A, then
# edited files, then prose" while B still runs is the stall, not a wait.
# Its OUTCOME counts too (R08, 2.1.1): a wait that came back timed out
# (TaskOutput `retrieval_status` timeout / not_ready or `status` running in
# the service fields, not in the job's `<output>`; a Bash call that failed
# with "Command timed out after" or a `--wait` "FAIL: wait timeout" line)
# proves the job is still running — the turn is blocked once more. The deliberate stop stays
# open: record it in the registry (a status other than «запущен»), and the
# next Stop passes; `stop_hook_active` still bounds it to one nudge per turn.
#
# Registered by pf-workflow's install.sh (`bash install.sh --sync`); stdin is
# Claude Code's hook JSON: session_id, transcript_path, stop_hook_active, cwd.
set -u

INPUT="$(cat 2>/dev/null || true)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "wait-guard: skipped (python3 not found)" >&2
  exit 0
fi

# All parsing in one python3 process; its exit code is the decision (0 or 2),
# and it prints the reason itself. Anything else (interpreter crash, signal,
# a code we do not expect) is "could not check" → exit 0. The hook JSON goes
# in through the environment: python's stdin is the program (heredoc).
WAIT_GUARD_INPUT="$INPUT" python3 - <<'PYEOF'
import glob, json, os, re, stat, sys

BLOCK = 2

def skip(reason):
    sys.stderr.write("wait-guard: skipped (%s)\n" % reason)
    sys.exit(0)

def ok(reason):
    sys.stderr.write("wait-guard: ok (%s)\n" % reason)
    sys.exit(0)

MAX_BYTES = 1048576  # per registry file, read before any parsing (Ж-1)
MAX_LINES = 5000

def read_lines(path):
    """The first MAX_BYTES / MAX_LINES of a REGULAR file, as lines; None for
    anything else (symlink, device, FIFO, directory, unreadable). lstat first,
    then open with O_NOFOLLOW|O_NONBLOCK and fstat again — a file swapped for
    a symlink or a FIFO in between is refused too, never followed or waited on."""
    try:
        if not stat.S_ISREG(os.lstat(path).st_mode):
            return None
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        chunks, left = [], MAX_BYTES
        while left > 0:
            b = os.read(fd, left)
            if not b:
                break
            chunks.append(b)
            left -= len(b)
    except OSError:
        return None
    finally:
        os.close(fd)
    return b"".join(chunks).decode("utf-8", "replace").splitlines(True)[:MAX_LINES]

def read_head(path):
    """The safe head of a file (enough for any frontmatter; the registry id
    sits at the top); [] when the file is skipped."""
    return read_lines(path) or []

def head_field(lines, key):
    """`key: value` in the file head (frontmatter or a plain line); a trailing
    `# comment` is dropped (older HANDOFF files carry one)."""
    for line in lines:
        s = line.strip()
        if s.startswith(key + ":"):
            return s[len(key) + 1:].split("#", 1)[0].strip().strip("`\"'")
    return None

def frontmatter_lines(lines):
    """Lines inside the leading `---` … `---` block; [] when there is none or
    the block is not closed within the head (unreadable → not a registry)."""
    if not lines or lines[0].strip() != "---":
        return []
    out = []
    for line in lines[1:]:
        if line.strip() == "---":
            return out
        out.append(line)
    return []

LEGACY_LEN = 8  # the short form written before 2.1.1

def id_matches(file_id, session_id, other_ids=()):
    """Exact equality of the full id. A legacy 8-character value is own only
    when session_id starts with it and no OTHER registry's id starts with the
    same prefix — a full id or another legacy value (R02: ambiguity → not own)."""
    if not file_id or not session_id:
        return False
    if file_id == session_id:
        return True
    if len(file_id) != LEGACY_LEN or not session_id.startswith(file_id):
        return False
    return not any(o and o.startswith(file_id) for o in other_ids)

def find_agents_dir(cwd):
    """`.agents/runtime` in cwd or its ancestors (the orchestrator usually
    sits at the project root; a subdirectory cwd still belongs to it)."""
    d = os.path.abspath(cwd)
    while True:
        cand = os.path.join(d, ".agents", "runtime")
        if os.path.isdir(cand):
            return cand
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent

# The status word: «запущен» and its short forms, «перезапущен» too (a restart
# runs); a longer word such as «запущенный» is not a status.
RUNNING_WORD = re.compile(r"(?<![А-Яа-яЁё])(?:пере)?запущен[аоы]?(?![А-Яа-яЁё])", re.IGNORECASE)
# Text right before the word ends with a standalone «не» (markdown allowed:
# «**НЕ** запущен») — the job is NOT running.
NEGATED = re.compile(r"(?<![А-Яа-яЁё])не[\s*_`~]*$", re.IGNORECASE)

def status_running(cell):
    """True when the status cell has a non-negated «запущен»."""
    return any(not NEGATED.search(cell[:m.start()]) for m in RUNNING_WORD.finditer(cell))

STATUS_HEADER = re.compile(r"^[\s*_`~]*(?:статус|status)[\s*_`~]*$", re.IGNORECASE)

def split_row(line):
    # Markdown escapes a pipe inside a cell as `\|`: split only on unescaped
    # pipes, so «запущен 14:00 \| ждёт B» stays one status cell (review 03.10
    # 💭2). A bare `|` inside a cell still shifts the row — not handled on
    # purpose, see case 27 (the 20.09 false block).
    return [c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]

def is_separator(cells):
    return bool(cells) and bool(cells[0]) and set(cells[0]) <= set("-: ")

def running_rows(path):
    rows = []
    lines = [line.strip() for line in (read_lines(path) or [])]
    status_idx, ncols = None, 0  # from the latest header row of the file
    for i, s in enumerate(lines):
        if not s.startswith("|"):
            continue  # prose between rows does not forget the header
        cells = split_row(s)
        if is_separator(cells):
            continue
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        if nxt.startswith("|") and is_separator(split_row(nxt)):
            hits = [k for k, c in enumerate(cells) if STATUS_HEADER.match(c)]
            status_idx, ncols = (hits[0] if hits else None), len(cells)
            continue  # the header row itself
        if status_idx is None or status_idx == ncols - 1:
            status = cells[-1]  # template layout: «Статус» is the last column
        elif len(cells) == ncols:
            status = cells[status_idx]  # «Статус» in the middle, cells line up
        else:
            status = " | ".join(cells)  # misaligned row: check all of it
        if not status_running(status):
            continue  # the status column decides, not the history
        label = " / ".join(c for c in cells[:2] if c)
        rows.append(label or s[:60])
    return rows

def is_blocking_wait(name, inp):
    """TaskOutput(block=true), or a foreground Bash whose command is a wait
    loop (`until `/`while `) or a `--wait`. Monitor and Bash with
    run_in_background are background launches, not waits."""
    if not isinstance(inp, dict):
        return False
    if name == "TaskOutput":
        return inp.get("block") is True
    if name == "Bash":
        if inp.get("run_in_background") is True:
            return False
        cmd = inp.get("command")
        if not isinstance(cmd, str):
            return False
        # A loop keyword counts only in command position (start of the
        # command or right after `;`, `&&`, `||`, `|`, `(`, a newline) or with
        # its own `; do` (a quoted `bash -c 'until …; do …'`) — `echo "until we
        # meet"` is prose and a `for … ; do` loop is not a wait (17.09).
        if re.search(r'(?:^|[;&|(\n]\s*)(?:until|while)\s', cmd) or re.search(r'\b(?:until|while)\b[^;\n]*;\s*do\b', cmd):
            return True
        return re.search(r'(?:^|\s)--wait(?:[\s=]|$)', cmd) is not None
    return False

TASK_TIMED_OUT = re.compile(r"<retrieval_status>\s*(?:timeout|not_ready)\s*<|<status>\s*running\s*<")
BASH_TIMED_OUT = re.compile(r"^(?:Command timed out after|FAIL: wait timeout)", re.MULTILINE)

def result_text(content):
    """The text of a tool_result's content (a string or a list of blocks)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") if isinstance(b, dict) else str(b) for b in content)
    return ""

def wait_timed_out(name, block, record):
    """Did this wait come back unfinished? TaskOutput: the structured result
    (`toolUseResult`) when the record has it, else the service fields of the
    text BEFORE `<output>` — the job's own output may say anything. Bash: only
    a failed call (`is_error`) whose output has a line starting with the
    harness timeout or a `--wait` timeout."""
    text = result_text(block.get("content"))
    if name == "TaskOutput":
        tur = record.get("toolUseResult")
        if isinstance(tur, dict) and "retrieval_status" in tur:
            task = tur.get("task") if isinstance(tur.get("task"), dict) else {}
            return tur.get("retrieval_status") in ("timeout", "not_ready") or task.get("status") == "running"
        return TASK_TIMED_OUT.search(text.split("<output>", 1)[0]) is not None
    return block.get("is_error") is True and BASH_TIMED_OUT.search(text) is not None

def turn_has_blocking_wait(transcript_path):
    """"wait" when the LAST tool call of the LAST turn is a blocking wait
    (see is_blocking_wait) that came back finished; "timeout" when that wait
    came back timed out with the job still running (R08); "" otherwise.
    A wait whose result is not in the transcript counts as finished — "cannot
    check" never turns into "block".

    "Last tool call", not "any call this turn": a turn that waited for job A,
    then edited the registry / wrote files and ended in prose while job B is
    still «запущен» is exactly the I-029 stall — the wait must be re-issued
    until nothing is running (council review, T-110). A turn starts at a
    `user` record whose content is a plain string (a human prompt or a
    <task-notification>) or a list without tool_result blocks; a `user`
    record carrying tool_result blocks is inside a turn. Sidechain records
    (subagent transcripts inlined) are ignored.
    """
    waited, last_id, last_name, timed_out = False, None, None, False
    with open(transcript_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if '"type"' not in line:
                continue
            if ('"user"' not in line) and ('"assistant"' not in line):
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict) or d.get("isSidechain"):
                continue
            t = d.get("type")
            msg = d.get("message") or {}
            content = msg.get("content") if isinstance(msg, dict) else None
            if t == "user":
                results = [b for b in content if isinstance(b, dict) and b.get("type") == "tool_result"] \
                    if isinstance(content, list) else []
                if results:
                    for b in results:  # tool result — still the same turn
                        if waited and last_id and b.get("tool_use_id") == last_id:
                            timed_out = wait_timed_out(last_name, b, d)
                    continue
                waited, timed_out = False, False  # a new turn begins here
            elif t == "assistant" and isinstance(content, list):
                for b in content:
                    if not isinstance(b, dict) or b.get("type") != "tool_use":
                        continue
                    # the LAST call decides: a later non-wait call resets it
                    waited = is_blocking_wait(b.get("name"), b.get("input") or {})
                    last_id, last_name, timed_out = b.get("id"), b.get("name"), False
    if not waited:
        return ""
    return "timeout" if timed_out else "wait"

def main():
    raw = os.environ.get("WAIT_GUARD_INPUT", "")
    try:
        data = json.loads(raw)
    except ValueError:
        skip("stdin is not JSON")
    if not isinstance(data, dict):
        skip("stdin JSON is not an object")
    if data.get("stop_hook_active") is True:
        ok("stop_hook_active — the agent is already continuing")
    session_id = str(data.get("session_id") or "")
    if not session_id:
        skip("no session_id in stdin")
    cwd = str(data.get("cwd") or os.getcwd())
    runtime = find_agents_dir(cwd)
    if not runtime:
        ok("no .agents/runtime under %s" % cwd)

    regs = []  # (path, session_id) of every registry: active HANDOFFs + autopilot-run.md
    for path in sorted(glob.glob(os.path.join(runtime, "handoff", "*.md"))):
        fm = frontmatter_lines(read_head(path))
        if not fm:
            continue  # no frontmatter — not a registry we understand
        if (head_field(fm, "status") or "") != "active":
            continue
        regs.append((path, head_field(fm, "session_id")))
    autopilot = os.path.join(runtime, "autopilot-run.md")
    if os.path.isfile(autopilot):
        regs.append((autopilot, head_field(read_head(autopilot), "session_id")))
    own = [p for k, (p, i) in enumerate(regs)
           if id_matches(i, session_id, [o for j, (_, o) in enumerate(regs) if j != k])]
    if not own:
        ok("skipped: no own registry for session %s" % session_id[:8])

    running = []
    for path in own:
        running.extend("%s [%s]" % (r, os.path.basename(path)) for r in running_rows(path))
    if not running:
        ok("own registry has no running jobs")

    transcript = str(data.get("transcript_path") or "")
    if not transcript or not os.path.isfile(transcript):
        skip("transcript_path missing or not a file")
    waited = turn_has_blocking_wait(transcript)
    if waited == "wait":
        ok("running jobs exist, but this turn made a blocking wait")
    if waited == "timeout":
        sys.stderr.write(
            "wait-guard: registry has running jobs (%s) and the last blocking wait timed out with the job"
            " still running - re-issue the wait as the last tool call, or record a deliberate stop in the"
            " registry (a status other than «запущен»)\n" % "; ".join(running)
        )
        sys.exit(BLOCK)

    sys.stderr.write(
        "wait-guard: registry has running jobs (%s) and this turn did not end on a blocking wait"
        " - call TaskOutput(block=true) or a foreground Bash until-loop as the last tool call,"
        " or update the registry\n" % "; ".join(running)
    )
    sys.exit(BLOCK)

try:
    main()
except SystemExit:
    raise
except BaseException as exc:  # never fail: any parse/IO error → skipped
    skip("%s: %s" % (type(exc).__name__, exc))
PYEOF
rc=$?
case "$rc" in
  0|2) exit "$rc" ;;
  *) echo "wait-guard: skipped (python exited $rc)" >&2; exit 0 ;;
esac
