#!/bin/bash
# Синхронизация дистрибутива pf-workflow из канона разработки перед релизом.
# Канон живёт в _tools: skill-library/{skills,agents}; правила — AGENTS.md §7–§12.
# Подсистема непрерывности сессий (pf-handoff/pf-resume, хуки, §13) — ОТДЕЛЬНЫЙ инструмент
# github.com/turvodnik/pf-handoff и сюда намеренно не входит.
# Запуск: bash sync-from-tools.sh [путь-к-_tools]
# Дальше руками: git diff → запись в CHANGELOG.md → commit → tag vX.Y.Z → push --tags.
set -euo pipefail

TOOLS="${1:-$HOME/Проекты ai/_tools}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

[ -d "$TOOLS/skill-library/skills/pf-spec" ] || { echo "ОШИБКА: не найден канон в $TOOLS" >&2; exit 2; }

for sk in pf-spec pf-tickets pf-do pf-replan pf-retro pf-auto; do
  mkdir -p "$HERE/skills/$sk"
  rsync -a --delete "$TOOLS/skill-library/skills/$sk/" "$HERE/skills/$sk/"
done

mkdir -p "$HERE/agents"
for ag in pf-architect pf-executor pf-reviewer; do
  cp "$TOOLS/skill-library/agents/$ag.md" "$HERE/agents/$ag.md"
done

# tests/yaml-strict.sh (T-009, I-004): this repo's own test suite
# (tests/run.sh, T-016) runs it against skills/*/SKILL.md + agents/*.md
# frontmatter, but nothing carried it forward on sync — it had only ever
# been transplanted by hand (T-016), same class of drift risk fixed for
# pf-handoff's threshold-parity.sh (T-017). No path adaptation needed here
# (unlike that file): source and destination are both tests/yaml-strict.sh.
# Fail closed on the source so a moved/renamed canon file stops the sync
# instead of silently leaving a stale copy in place.
YS_SRC="$TOOLS/skill-library/tests/yaml-strict.sh"
[ -f "$YS_SRC" ] || { echo "ОШИБКА: не найден $YS_SRC" >&2; exit 2; }
mkdir -p "$HERE/tests"
cp "$YS_SRC" "$HERE/tests/yaml-strict.sh"
chmod +x "$HERE/tests/yaml-strict.sh"

mkdir -p "$HERE/docs"
{
  echo "# Готовые разделы правил для вашего AGENTS.md / CLAUDE.md"
  echo
  echo "Сгенерировано sync-from-tools.sh из канонического _tools/AGENTS.md (§7–§12). English translation: rules-sections.en.md (обновляется вручную при релизе)."
  echo "Ссылки в текстах на §0–§6 (политика секретов и др.) — разделы полного свода правил автора: замените своими. §13 (бюджет контекста) поставляется с инструментом-компаньоном pf-handoff."
  echo
  awk '/^## 7\. /{f=1} /^## 13\. /{f=0} f' "$TOOLS/AGENTS.md"
} > "$HERE/docs/rules-sections.ru.md"

echo "Синхронизировано из: $TOOLS"
echo "Дальше: git diff → CHANGELOG.md → commit → tag vX.Y.Z → git push --tags"
