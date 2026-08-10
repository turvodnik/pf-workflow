#!/bin/bash
# Установка pf-workflow: КОПИИ скиллов в папки CLI-агентов (по умолчанию) и
# агентов — в Claude Code. Копии не зависят от клона: его можно перемещать и
# удалять; обновление — git pull && bash install.sh --update.
# Режимы:
#   bash install.sh            — копии (по умолчанию, рекомендуется)
#   bash install.sh --update   — обновить уже установленные копии
#   bash install.sh --link     — симлинки на клон (обновление = git pull;
#                                клон после этого НЕ перемещать)
# Чужие симлинки (созданные вашим собственным механизмом управления скиллами)
# установщик НИКОГДА не перезаписывает — пропускает с предупреждением.
# После установки вставьте docs/rules-sections.ru.md (или .en.md) в свой
# глобальный AGENTS.md/CLAUDE.md.
# Непрерывность сессий (handoff/компакт) — компаньон: github.com/turvodnik/pf-handoff.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MODE="copy"; UPDATE=0
for a in "$@"; do
  case "$a" in
    --link) MODE="link" ;;
    --update) UPDATE=1 ;;
    *) echo "install.sh: неизвестный флаг: $a (допустимо: --link, --update)" >&2; exit 2 ;;
  esac
done

# Поверхности: ~/.claude — всегда; Codex/Gemini — только если сами CLI есть
# на машине (их каталог существует): мусорных папок не создаём.
SURFACES=("$HOME/.claude/skills")
if [ -d "$HOME/.codex" ]; then SURFACES+=("$HOME/.codex/skills"); fi
if [ -d "$HOME/.gemini" ]; then SURFACES+=("$HOME/.gemini/skills"); fi

install_one() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    local target; target="$(readlink "$dst")"
    case "$target" in
      "$HERE"/*)  # наш прежний симлинк — можно обновлять
        if [ "$MODE" = "link" ]; then
          ln -sfn "$src" "$dst"; echo "OK (link): $dst"
        else
          rm -f "$dst"; cp -R "$src" "$dst"; echo "OK (copy, заменил наш прежний симлинк): $dst"
        fi ;;
      *) echo "ПРОПУСК: $dst — чужой симлинк ($target), не трогаю" ;;
    esac
    return 0
  fi
  if [ -e "$dst" ]; then
    if [ "$UPDATE" = 1 ]; then
      # Заменяем только СВОЁ (name: совпадает в SKILL.md/файле агента) — чужое не трогаем.
      local base own_name
      base="$(basename "$dst")"; own_name="${base%.md}"
      if { [ -d "$dst" ] && grep -q "^name: $own_name\$" "$dst/SKILL.md" 2>/dev/null; } || \
         { [ -f "$dst" ] && grep -q "^name: $own_name\$" "$dst" 2>/dev/null; }; then
        rm -rf "$dst"
        if [ "$MODE" = "link" ]; then ln -s "$src" "$dst"; echo "OK (link, заменил копию): $dst"
        else cp -R "$src" "$dst"; echo "OK (обновлено): $dst"; fi
      else
        echo "ПРОПУСК: $dst — не похоже на наш скилл/агент (name: не совпал); разберитесь вручную"
      fi
    else
      echo "ПРОПУСК: $dst уже существует (заменить: --update)"
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

echo "Готово (режим: $MODE). Не забудьте правила: docs/rules-sections.ru.md (или .en.md) → ваш AGENTS.md/CLAUDE.md."
