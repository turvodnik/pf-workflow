#!/bin/bash
# pf-session-id.sh — Claude Code `SessionStart` hook (pf-workflow, T-191).
# hook-event: SessionStart
#
# Why (QA 11.10, Ж-5): wait-guard.sh blocks only the registry of THIS
# session — the `session_id:` line of an active HANDOFF or of
# .agents/runtime/autopilot-run.md must match the id Claude Code passes to
# its hooks (an 8-character prefix is enough). The agent itself never sees
# that id; without this line it writes a placeholder and the guard silently
# stays off. At session start (and after /clear, resume, compaction) this
# hook prints one line into the agent's context:
#
#   Сессия: <first 8 characters> — это значение поля session_id в HANDOFF/реестре
#
# The same line is printed by pf-handoff's start hook (hooks/sessionstart.sh);
# when that hook is registered in the same settings file and carries the
# line, this one stays silent — no duplicate. Also silent: PF_COUNCIL_RUN=1
# (a child CLI started by council.sh is not an orchestrator), no usable
# session_id on stdin. stdin is read up to 64 KB. Never fails: exit 0.
# Registered by pf-workflow's install.sh like every hooks/*.sh (upsert/KEPT).
set -u

INPUT="$(head -c 65536 2>/dev/null || true)"
[ "${PF_COUNCIL_RUN:-}" = 1 ] && exit 0

sid="$(printf '%s' "$INPUT" | tr -d '\n' | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]\{8,\}\)".*/\1/p' | head -1)"
[ -n "$sid" ] || exit 0

# pf-handoff's start hook registered in the settings file AND printing the
# line → silent. Read with python3 (JSON + quoting); no python3 → print
# (a duplicate line is harmless, a missing one switches the guard off).
settings="${CLAUDE_SETTINGS_PATH:-$HOME/.claude/settings.json}"
if [ -f "$settings" ] && command -v python3 >/dev/null 2>&1 && python3 - "$settings" <<'PYEOF' 2>/dev/null
import json, os, re, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    sys.exit(1)
groups = ((d.get("hooks") or {}) if isinstance(d, dict) else {}).get("SessionStart") or []
for g in groups if isinstance(groups, list) else []:
    for h in (g.get("hooks") or []) if isinstance(g, dict) else []:
        cmd = (h.get("command") or "") if isinstance(h, dict) else ""
        for a, b, c in re.findall(r"'([^']*/sessionstart\.sh)'|\"([^\"]*/sessionstart\.sh)\"|(\S*/sessionstart\.sh)", cmd):
            p = os.path.expanduser(os.path.expandvars(a or b or c))
            try:
                if os.path.isfile(p):
                    with open(p, "rb") as fh:
                        if "значение поля session_id".encode() in fh.read(262144):
                            sys.exit(0)
            except OSError:
                pass
sys.exit(1)
PYEOF
then
  exit 0
fi

printf 'Сессия: %s — это значение поля session_id в HANDOFF/реестре\n' "$(printf '%s' "$sid" | cut -c1-8)"
exit 0
