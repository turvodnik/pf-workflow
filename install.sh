#!/bin/bash
# pf-workflow install: COPIES of the skills into the CLI agents' folders (default)
# and of the agents — into Claude Code. Copies do not depend on the clone: it may
# be moved or deleted; update — git pull && bash install.sh --update.
# Modes:
#   bash install.sh            — copies (default, recommended)
#   bash install.sh --update   — refresh already-installed copies
#   bash install.sh --link     — symlinks to the clone (update = git pull;
#                                do NOT move the clone afterwards)
#   bash install.sh --sync     — hooks only: (re)register hooks/*.sh in
#                                ~/.claude/settings.json, skills/agents untouched
#   --force (with any mode)    — also repoint a hook registered elsewhere (below)
# Foreign symlinks (created by your own skill-management tooling) are NEVER
# overwritten — skipped with a notice.
# Hooks (hooks/*.sh, e.g. the Stop hook wait-guard.sh) are registered in
# Claude Code's settings.json on every run (idempotent upsert keyed by the
# script file name; foreign entries such as Orca's are never touched). They
# are registered BY PATH INTO THIS CLONE — do not move the clone afterwards,
# or re-run `--sync` from its new place. The wrapper self-disables when the
# file is gone. CLAUDE_SETTINGS_PATH overrides the settings file (tests).
# A registration of the same hook that points at an EXISTING file outside
# this clone (a canon checkout, another copy) is someone else's wiring: it is
# KEPT as is, with a `KEPT:` line; --force points it at this clone (T-187).
# After installing, paste docs/rules-sections.en.md (or .ru.md) into your
# global AGENTS.md/CLAUDE.md.
# Session continuity (handoff/compaction) is the companion tool: github.com/turvodnik/pf-handoff.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MODE="copy"; UPDATE=0; SYNC=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --link) MODE="link" ;;
    --update) UPDATE=1 ;;
    --sync) SYNC=1 ;;
    --force) FORCE=1 ;;
    *) echo "install.sh: unknown flag: $a (valid: --link, --update, --sync, --force)" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- hooks
# Registration after the pattern of pf-handoff's hooks/install.sh: an
# idempotent upsert keyed by the script file name (marker "/<name>.sh"), a
# guard wrapper with the interpreter named EXPLICITLY (`bash`: Claude Code
# runs the command through /bin/sh, which is dash on Debian/Ubuntu and does
# not read the shebang), self-disabling when the file is missing. The event
# each hook binds to is declared by the hook itself in a header line
# `# hook-event: <Event>` — a hook without it is reported and skipped.
SETTINGS_PATH="${CLAUDE_SETTINGS_PATH:-$HOME/.claude/settings.json}"

wrap_hook() {
  # The path goes inside single quotes; a quote in it (`Mike's tools`) is
  # written as '\'' — otherwise the command does not parse and a Stop hook
  # returns 2 on every turn (QA 11.10, Ж-2).
  local script
  script="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
  printf "if [ -f '%s' ] && [ -r '%s' ] && [ -x '%s' ] && command -v bash >/dev/null 2>&1; then bash '%s'; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi" \
    "$script" "$script" "$script" "$script"
}

register_hooks() {
  local hooks_dir="$HERE/hooks" h event name cmd specs=""
  if ! command -v python3 >/dev/null 2>&1; then
    echo "install.sh: python3 not found — hooks NOT registered (skills are installed; re-run --sync once python3 is available)" >&2
    return 1
  fi
  if [ -L "$SETTINGS_PATH" ]; then
    # dotfiles repos keep settings.json as a symlink: write through to the
    # target, otherwise the file replace below would swap the link for a copy.
    SETTINGS_PATH="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SETTINGS_PATH")"
    echo "install.sh: settings.json is a symlink, working with its target: $SETTINGS_PATH"
  fi
  for h in "$hooks_dir"/*.sh; do
    [ -f "$h" ] || continue          # no hooks/ or an empty one — nothing to register
    name="$(basename "$h")"
    if [ ! -x "$h" ]; then
      echo "install.sh: hook $name is not executable — skipped (chmod +x and re-run --sync)" >&2
      continue
    fi
    event="$(sed -n 's/^# hook-event: *\([A-Za-z]*\).*$/\1/p' "$h" | head -1)"
    if [ -z "$event" ]; then
      echo "install.sh: hook $name declares no '# hook-event: <Event>' line — skipped" >&2
      continue
    fi
    cmd="$(wrap_hook "$h")"
    specs="${specs}${event}"$'\x1f'"/${name}"$'\x1f'"${cmd}"$'\x1f'"${h}"$'\x1e'
  done
  if [ -z "$specs" ]; then
    echo "install.sh: no hooks to register (hooks/*.sh missing or empty)"
    return 0
  fi
  if [ ! -f "$SETTINGS_PATH" ]; then
    mkdir -p "$(dirname "$SETTINGS_PATH")"
    printf '{}\n' > "$SETTINGS_PATH"
    echo "install.sh: settings.json not found — created an empty one: $SETTINGS_PATH"
  fi
  # Output through a file, not "$(… <<'PYEOF' …)": a quote inside a here-doc
  # nested in a command substitution derails bash's parser.
  local out outf py_ok=1
  outf="$(mktemp "${TMPDIR:-/tmp}/pfwf-hooks.XXXXXX")"
  if ! HOOK_SPECS="$specs" HOOK_FORCE="$FORCE" PYTHONIOENCODING=utf-8 python3 - "$SETTINGS_PATH" > "$outf" <<'PYEOF'
import json, os, re, shlex, stat, sys, tempfile

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
except ValueError:
    print("ERROR: %s is not valid JSON — nothing changed" % path)
    sys.exit(1)
if not isinstance(d, dict):
    print("ERROR: %s top level is not an object — nothing changed" % path)
    sys.exit(1)
before = json.dumps(d, sort_keys=True)

def existing_timeout(arr, marker, default):
    # A timeout someone raised by hand survives a reinstall (pf-handoff lesson).
    for item in arr:
        for h in item.get("hooks", []) if isinstance(item, dict) else []:
            if marker in (h.get("command") or "") and "timeout" in h:
                return h["timeout"]
    return default

INTERP = {"sh", "bash", "zsh", "dash", "env", "python", "python3", "node", "ruby", "perl"}

def words(cmd):
    # Shell words with quoting resolved ('\'' included, Ж-2) and ; && || |
    # split off; a command shlex cannot read falls back to the plain regex.
    try:
        lx = shlex.shlex(cmd or "", posix=True, punctuation_chars=True)
        lx.whitespace_split = True
        return list(lx)
    except ValueError:
        return [a or b or c for a, b, c in re.findall(r"'([^']*)'|\"([^\"]*)\"|([^\s;'\"]+)", cmd or "")]

def cmd_paths(cmd):
    # Path-like words of a shell command: quoted or bare; not redirections,
    # not interpreters. Same reading as pf-handoff hooks/install.sh.
    out = []
    for t in words(cmd):
        if "/" not in t or re.match(r"^[0-9]*[<>&|]", t) or t.startswith("/dev/"):
            continue
        t = os.path.expanduser(os.path.expandvars(t))
        if os.path.basename(t) in INTERP:
            continue
        out.append(t)
    return out

def foreign(arr, marker, ours):
    # The path of a registration of this hook that names an EXISTING file
    # other than ours (someone else's wiring, T-187), else None.
    name = marker.lstrip("/")
    for item in arr:
        for h in (item.get("hooks") or []) if isinstance(item, dict) else []:
            cmd = (h.get("command") or "") if isinstance(h, dict) else ""
            if marker not in cmd:
                continue
            for p in cmd_paths(cmd):
                if os.path.basename(p) != name:
                    continue
                if os.path.realpath(p) != os.path.realpath(ours) and os.path.isfile(p):
                    return p
                break
    return None

def upsert(arr, marker, hook):
    # Only OUR hook object is replaced; its neighbours in the same group and
    # the group's own keys (matcher) stay as they are (QA 11.10, Ж-3). A new
    # group is added only when ours stands in none.
    for item in arr:
        hs = item.get("hooks") if isinstance(item, dict) else None
        if not isinstance(hs, list):
            continue
        for j, h in enumerate(hs):
            if isinstance(h, dict) and marker in (h.get("command") or ""):
                hs[j] = hook
                return
    arr.append({"hooks": [hook]})       # foreign entries stay where they are

hooks = d.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print("ERROR: 'hooks' in %s is not an object — nothing changed" % path)
    sys.exit(1)
registered, kept = [], []
for spec in os.environ["HOOK_SPECS"].split("\x1e"):
    if not spec:
        continue
    event, marker, cmd, script = spec.split("\x1f", 3)
    arr = hooks.setdefault(event, [])
    if not isinstance(arr, list):
        print("ERROR: hooks.%s in %s is not a list — nothing changed" % (event, path))
        sys.exit(1)
    other = None if os.environ.get("HOOK_FORCE") == "1" else foreign(arr, marker, script)
    if other:
        kept.append("KEPT: %s \u2192 %s (registered elsewhere; re-run with --force to point it at this clone)" % (event, other))
        continue
    timeout = existing_timeout(arr, marker, 15)
    upsert(arr, marker, {"type": "command", "command": cmd, "timeout": timeout})
    registered.append("%s -> %s" % (marker.lstrip("/"), event))

for line in kept:
    print(line)
if json.dumps(d, sort_keys=True) == before:
    print("unchanged: " + (", ".join(registered) or "nothing registered here"))
    sys.exit(0)
fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", dir=os.path.dirname(path) or ".")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
backup = path + ".bak-pf-workflow"
# The copy gets the original's mode BEFORE any byte is written: settings.json
# often holds API keys in `env`, and a 0600 file must not leave a 0644 copy
# (QA 11.10, Ж-4). A new copy is created 0600, an existing one is chmod-ed.
try:
    mode = stat.S_IMODE(os.stat(path).st_mode)
    bfd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(bfd, "wb") as dst:
        os.fchmod(dst.fileno(), mode)
        with open(path, "rb") as src:
            dst.write(src.read())
except OSError:
    pass
os.replace(tmp, path)
print("registered: " + ", ".join(registered) + " (backup: %s)" % backup)
PYEOF
  then
    py_ok=0
  fi
  out="$(cat "$outf")"; rm -f "$outf"
  [ "$py_ok" = 1 ] || { echo "install.sh: hook registration failed: $out" >&2; return 1; }
  # KEPT lines stand on their own; the summary is the last line.
  printf '%s\n' "$out" | grep '^KEPT: ' || true
  echo "install.sh: hooks in $SETTINGS_PATH — $(printf '%s\n' "$out" | grep -v '^KEPT: ' | tail -1)"
}

if [ "$SYNC" = 1 ]; then
  register_hooks
  exit $?
fi

# Surfaces: ~/.claude — always; Codex/Gemini — only if those CLIs exist on
# this machine (their directory is present): no junk directories.
SURFACES=("$HOME/.claude/skills")
if [ -d "$HOME/.codex" ]; then SURFACES+=("$HOME/.codex/skills"); fi
if [ -d "$HOME/.gemini" ]; then SURFACES+=("$HOME/.gemini/skills"); fi

install_one() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    local target; target="$(readlink "$dst")"
    case "$target" in
      "$HERE"/*)  # our own previous symlink — safe to refresh
        if [ "$MODE" = "link" ]; then
          ln -sfn "$src" "$dst"; echo "OK (link): $dst"
        else
          rm -f "$dst"; cp -R "$src" "$dst"; echo "OK (copy, replaced our previous symlink): $dst"
        fi ;;
      *) echo "SKIP: $dst — foreign symlink ($target), leaving it alone" ;;
    esac
    return 0
  fi
  if [ -e "$dst" ]; then
    if [ "$UPDATE" = 1 ]; then
      # Replace only OUR OWN items (name: matches in SKILL.md / the agent file) — foreign ones are left alone.
      local base own_name
      base="$(basename "$dst")"; own_name="${base%.md}"
      if { [ -d "$dst" ] && grep -q "^name: $own_name\$" "$dst/SKILL.md" 2>/dev/null; } || \
         { [ -f "$dst" ] && grep -q "^name: $own_name\$" "$dst" 2>/dev/null; }; then
        rm -rf "$dst"
        if [ "$MODE" = "link" ]; then ln -s "$src" "$dst"; echo "OK (link, replaced the copy): $dst"
        else cp -R "$src" "$dst"; echo "OK (updated): $dst"; fi
      else
        echo "SKIP: $dst — does not look like our skill/agent (name: mismatch); resolve manually"
      fi
    else
      echo "SKIP: $dst already exists (replace with: --update)"
    fi
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  if [ "$MODE" = "link" ]; then
    ln -s "$src" "$dst"; echo "OK (link): $dst"
  else
    cp -R "$src" "$dst"; echo "OK: $dst"
  fi
}

for dir in "$HERE"/skills/*/; do
  name="$(basename "$dir")"
  for s in "${SURFACES[@]}"; do
    install_one "${dir%/}" "$s/$name"
  done
done

for f in "$HERE"/agents/*.md; do
  install_one "$f" "$HOME/.claude/agents/$(basename "$f")"
done

register_hooks || true   # skills are in place; a missing python3 is reported above

echo "Done (mode: $MODE). Don't forget the rules: docs/rules-sections.en.md (or .ru.md) → your AGENTS.md/CLAUDE.md."
