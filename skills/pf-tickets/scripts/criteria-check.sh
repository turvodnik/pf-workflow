#!/usr/bin/env bash
# criteria-check.sh — run a task packet's acceptance criteria on the CURRENT HEAD
# before the packet is handed out (pf-tickets step 6, gate G3; T-125 / I-069).
#
# Usage: criteria-check.sh <ticket.md> [--cwd DIR]
#
# `cmd:` runs through the shell as written — a ticket is trusted input
# (pf-tickets), never paste external text into it.
#
# Reads the «## Критерии приёмки» / «## Acceptance criteria» section. Each
# bullet `- [ ] <text> — <kind>` may carry indented fields underneath:
#
#     - [ ] <condition> — change
#       cmd: grep -c "foo" path/file
#       expect: 1
#       expect_head: 0          # optional: what the cmd prints on HEAD today
#       cwd: <repo dir>         # optional: absolute, or relative to --cwd
#
# Kinds: change | invariant | observation (canon, references/task-template.md).
# Synonyms accepted without error: behaviour, behavior, output -> change;
# manual -> observation.
#
# Verdict per criterion:
#   change + cmd, stdout(trim) == expect        -> RED-BEFORE-WORK FAIL (green
#                                                  with no work done: rewrite it)
#   change + cmd, stdout != expect              -> OK (red on HEAD)
#   expect_head present and stdout != expect_head -> HEAD-MISMATCH FAIL
#   invariant / observation                     -> SKIP (<kind>)
#   change without cmd                          -> NO-CMD WARN (old format, valid)
#   unknown kind                                -> UNKNOWN-KIND WARN
#   invariant/observation carrying a cmd        -> SKIP (...) — cmd present, not run
#   cmd wrote to stderr                         -> STDERR WARN (first line; `ls`
#                                                  on a missing file is legitimate)
#   criteria section with bullets but no `- [ ]` -> NO-CHECKBOX WARN (old format)
# The cmd runs under `bash -o pipefail -c`: a pipeline whose first link is not
# found (`/typo/bin | wc -l`) is a run error (rc 127), not a "red on HEAD".
# The kind is the LAST dash-kind pair in the bullet (` - manual` inside the text
# before `— change` does not win).
# Summary line: `criteria-check: N checked, F fail, S skipped`.
# Exit: 0 clean; 1 any FAIL; 2 usage error, section missing, or a cmd that
# could not run (not found / not executable / timeout 60 s) — loud, never silent.
#
# Dependencies: bash + python3 standard library only (public distribution).
set -u

if ! command -v python3 >/dev/null 2>&1; then
  echo "criteria-check: python3 not found" >&2
  exit 2
fi

exec python3 - "$@" <<'PYEOF'
import os
import re
import signal
import subprocess
import sys

TIMEOUT = 60
CANON = {"change", "invariant", "observation"}
SYNONYMS = {"behaviour": "change", "behavior": "change", "output": "change",
            "manual": "observation"}
KIND_RE = re.compile(r"(?:[—–]|\s-\s)\s*(change|invariant|observation|behaviour|behavior|output|manual)\b",
                     re.IGNORECASE)
SECTION_RE = re.compile(r"^##\s+(Критерии приёмки|Acceptance criteria)\b", re.IGNORECASE)
ITEM_RE = re.compile(r"^-\s+\[( |x|X)\]\s+(.*)$")
FIELD_RE = re.compile(r"^\s+(cmd|expect|expect_head|cwd):\s?(.*)$")


def usage(msg=None):
    if msg:
        print(f"criteria-check: {msg}", file=sys.stderr)
    print("usage: criteria-check.sh <ticket.md> [--cwd DIR]", file=sys.stderr)
    sys.exit(2)


def parse_args(argv):
    ticket, cwd = None, os.getcwd()
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--cwd":
            if i + 1 >= len(argv):
                usage("--cwd needs a directory")
            cwd = argv[i + 1]
            i += 2
        elif a.startswith("--cwd="):
            cwd = a[len("--cwd="):]
            i += 1
        elif a.startswith("-"):
            usage(f"unknown option {a}")
        elif ticket is None:
            ticket = a
            i += 1
        else:
            usage("one ticket file only")
    if ticket is None:
        usage("ticket file missing")
    if not os.path.isfile(ticket):
        usage(f"ticket not found: {ticket}")
    if not os.path.isdir(cwd):
        usage(f"--cwd is not a directory: {cwd}")
    return ticket, os.path.abspath(cwd)


def parse_criteria(text):
    """Return list of dicts: text, kind, fields. Only the criteria section."""
    lines = text.splitlines()
    start = None
    for n, line in enumerate(lines):
        if SECTION_RE.match(line):
            start = n + 1
            break
    if start is None:
        return None
    items = []
    cur = None
    other = 0  # non-empty lines that are not checkbox items nor their fields
    for line in lines[start:]:
        if line.startswith("## "):
            break
        m = ITEM_RE.match(line)
        if m:
            body = m.group(2).strip()
            kinds = KIND_RE.findall(body)
            raw = kinds[-1].lower() if kinds else None  # canon puts the kind LAST
            kind = SYNONYMS.get(raw, raw) if raw else None
            if kind not in CANON:
                kind = None  # a word the regex knows but the vocabulary does not: warn, never skip silently
            cur = {"text": body, "kind": kind, "raw_kind": raw, "fields": {}}
            items.append(cur)
            continue
        if cur is not None:
            f = FIELD_RE.match(line)
            if f:
                cur["fields"][f.group(1)] = f.group(2).strip()
                continue
            if line.strip() == "":
                continue
            if not line.startswith((" ", "\t")):
                cur = None  # a non-indented, non-bullet line ends the block
                other += 1
        elif line.strip():
            other += 1
    return items, other


def short(text, n=90):
    text = " ".join(text.split())
    return text if len(text) <= n else text[: n - 1] + "…"


def run_cmd(cmd, cwd):
    """Returns (stdout_trimmed, stderr_trimmed, error_message_or_None)."""
    try:
        p = subprocess.Popen(["bash", "-o", "pipefail", "-c", cmd], cwd=cwd,
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, start_new_session=True)
    except OSError as e:
        return None, None, f"cannot start: {e}"
    try:
        out, err = p.communicate(timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.communicate()
        return None, None, f"timeout after {TIMEOUT}s"
    out = out.decode("utf-8", "replace").strip()
    err = err.decode("utf-8", "replace").strip()
    if p.returncode in (126, 127):
        return None, err, f"cannot run (rc {p.returncode}): {err or cmd}"
    return out, err, None


def main():
    ticket, base_cwd = parse_args(sys.argv[1:])
    with open(ticket, encoding="utf-8") as fh:
        parsed = parse_criteria(fh.read())
    if parsed is None:
        print(f"criteria-check: no «## Критерии приёмки» / «## Acceptance criteria» "
              f"section in {ticket}", file=sys.stderr)
        sys.exit(2)
    items, other = parsed
    if not items and not other:
        print(f"criteria-check: criteria section is empty in {ticket}", file=sys.stderr)
        sys.exit(2)
    if not items:
        # Numbered / plain bullets without `- [ ]` — the pre-T-125 format, valid.
        print(f"NO-CHECKBOX WARN: {other} lines in the criteria section, none is a `- [ ]` item (old format)")
        print("criteria-check: 0 checked, 0 fail, 0 skipped")
        sys.exit(0)

    checked = fails = skipped = 0
    run_error = False
    for i, it in enumerate(items, 1):
        label = f"[{i}] {short(it['text'])}"
        kind, f = it["kind"], it["fields"]
        if kind is None:
            print(f"UNKNOWN-KIND WARN: {label}")
            skipped += 1
            continue
        if kind != "change":
            tail = " — cmd present, not run" if f.get("cmd") else ""
            print(f"SKIP ({kind}): {label}{tail}")
            skipped += 1
            continue
        if "cmd" not in f or not f["cmd"]:
            print(f"NO-CMD WARN: {label}")
            skipped += 1
            continue
        if not f.get("expect", "").strip():
            print(f"NO-EXPECT FAIL: {label} (cmd without expect)")
            checked += 1
            fails += 1
            continue
        cwd = os.path.expanduser(f.get("cwd") or base_cwd)
        if not os.path.isabs(cwd):
            cwd = os.path.join(base_cwd, cwd)
        if not os.path.isdir(cwd):
            print(f"criteria-check: cwd not a directory for {label}: {cwd}", file=sys.stderr)
            run_error = True
            continue
        out, stderr, err = run_cmd(f["cmd"], cwd)
        if err is not None:
            print(f"criteria-check: RUN-ERROR {label}: {err}", file=sys.stderr)
            run_error = True
            continue
        checked += 1
        if stderr:
            print(f"STDERR WARN: {label}: {stderr.splitlines()[0]}")
        verdicts = []
        if out == f["expect"].strip():
            verdicts.append(f"RED-BEFORE-WORK FAIL: {label} (cmd already gives expect={f['expect']!r} on HEAD)")
        if "expect_head" in f and out != f["expect_head"].strip():
            verdicts.append(f"HEAD-MISMATCH FAIL: {label}: expected {f['expect_head']!r}, got {out!r}")
        if verdicts:
            fails += 1
            for v in verdicts:
                print(v)
        else:
            print(f"OK (red on HEAD): {label} (got {out!r}, expect {f['expect']!r})")

    print(f"criteria-check: {checked} checked, {fails} fail, {skipped} skipped")
    if run_error:
        print("criteria-check: one or more commands could not run (see stderr)", file=sys.stderr)
        sys.exit(2)
    sys.exit(1 if fails else 0)


main()
PYEOF
