#!/bin/bash
# Установка pf-workflow на машину: симлинки скиллов в папки трёх CLI-агентов и агентов — в Claude Code.
# Скиллы остаются в этом клоне; обновление = git pull (или переключение тега) без переустановки.
# После установки вставьте docs/rules-sections.ru.md в свой глобальный AGENTS.md/CLAUDE.md.
# Непрерывность сессий (handoff/компакт) — отдельный инструмент: github.com/turvodnik/pf-handoff.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SURFACES=("$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.gemini/skills")

for dir in "$HERE"/skills/*/; do
  name="$(basename "$dir")"
  for s in "${SURFACES[@]}"; do
    mkdir -p "$s"
    if [ -e "$s/$name" ] && [ ! -L "$s/$name" ]; then
      echo "ПРОПУСК: $s/$name — реальная папка, не перезаписываю"; continue
    fi
    ln -sfn "${dir%/}" "$s/$name"
  done
  echo "OK: скилл $name"
done

mkdir -p "$HOME/.claude/agents"
for f in "$HERE"/agents/*.md; do
  ln -sfn "$f" "$HOME/.claude/agents/$(basename "$f")"
  echo "OK: агент $(basename "$f" .md)"
done

echo "Готово. Не забудьте правила: docs/rules-sections.ru.md → ваш AGENTS.md/CLAUDE.md."
