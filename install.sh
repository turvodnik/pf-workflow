#!/bin/bash
# pf-workflow install: COPIES of the skills into the CLI agents' folders (default)
# and of the agents — into Claude Code. Copies do not depend on the clone: it may
# be moved or deleted; update — git pull && bash install.sh --update.
# Modes:
#   bash install.sh            — copies (default, recommended)
#   bash install.sh --update   — refresh already-installed copies
#   bash install.sh --link     — symlinks to the clone (update = git pull;
#                                do NOT move the clone afterwards)
# Foreign symlinks (created by your own skill-management tooling) are NEVER
# overwritten — skipped with a notice.
# After installing, paste docs/rules-sections.en.md (or .ru.md) into your
# global AGENTS.md/CLAUDE.md.
# Session continuity (handoff/compaction) is the companion tool: github.com/turvodnik/pf-handoff.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MODE="copy"; UPDATE=0
for a in "$@"; do
  case "$a" in
    --link) MODE="link" ;;
    --update) UPDATE=1 ;;
    *) echo "install.sh: unknown flag: $a (valid: --link, --update)" >&2; exit 2 ;;
  esac
done

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

echo "Done (mode: $MODE). Don't forget the rules: docs/rules-sections.en.md (or .ru.md) → your AGENTS.md/CLAUDE.md."
