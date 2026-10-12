#!/bin/bash
# Синхронизация дистрибутива pf-workflow из канона разработки перед релизом.
# Канон живёт в _tools: skill-library/{skills,agents,hooks,evals}, сканер — security/.
# docs/rules-sections.{en,ru}.md — СОБСТВЕННЫЕ файлы дистрибутива (правила для
# чужой машины, без путей и правил мастерской автора); синк их не трогает —
# раньше он копировал сюда §7–§12 личного свода без фильтра (QA 11.10, К-1).
# Подсистема непрерывности сессий (pf-handoff/pf-resume, хуки, §13) — ОТДЕЛЬНЫЙ инструмент
# github.com/turvodnik/pf-handoff и сюда намеренно не входит.
# Запуск: bash sync-from-tools.sh [путь-к-_tools]
# Дальше руками: git diff → запись в CHANGELOG.md → commit → tag vX.Y.Z → push --tags.
set -euo pipefail

TOOLS="${1:-$HOME/Проекты ai/_tools}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Every source is checked BEFORE the first write: a sync that fails half-way
# (canon dir missing) must not leave skills/ already overwritten — that is
# exactly what happened on 2026-09-16 when hooks/ was not in the canon yet.
[ -d "$TOOLS/skill-library/skills/pf-spec" ] || { echo "ОШИБКА: не найден канон в $TOOLS" >&2; exit 2; }
YS_SRC="$TOOLS/skill-library/tests/yaml-strict.sh"
[ -f "$YS_SRC" ] || { echo "ОШИБКА: не найден $YS_SRC" >&2; exit 2; }
HOOKS_SRC="$TOOLS/skill-library/hooks"
[ -d "$HOOKS_SRC" ] || { echo "ОШИБКА: не найден $HOOKS_SRC" >&2; exit 2; }
hooks_n=0
for h in "$HOOKS_SRC"/*.sh; do [ -f "$h" ] && hooks_n=$((hooks_n + 1)); done
[ "$hooks_n" -gt 0 ] || { echo "ОШИБКА: в $HOOKS_SRC нет ни одного *.sh" >&2; exit 2; }
# agents/index.yaml (T-117, pf-agents scaffold): checked here, copied below —
# fail closed on the source like every other file this script carries, not a
# bare cp mid-script (this repo's own header above warns exactly against that).
INDEX_SRC="$TOOLS/skill-library/agents/index.yaml"
[ -f "$INDEX_SRC" ] || { echo "ОШИБКА: не найден $INDEX_SRC" >&2; exit 2; }
# evals/ (T-144, SPEC-plugin-evals p. 3): the plugin's eval suite for
# `claude plugin eval` — canon skill-library/evals/pf-workflow/ lands here as
# evals/ (cases + README). Checked here, copied below, like everything else.
EVALS_SRC="$TOOLS/skill-library/evals/pf-workflow"
[ -f "$EVALS_SRC/README.md" ] || { echo "ОШИБКА: не найден $EVALS_SRC/README.md" >&2; exit 2; }
# The secret scanner council.sh runs before its launcher commit (T-187): on a
# machine without _tools, council.sh finds this copy next to itself
# (skills/pf-do/scripts/secret-scan/). Three canon files — the hook, its rules
# beside it, the false-positive ledger tool one level up (pre-commit loads it
# as HERE.parent). The canon keeps no second copy; only this script makes it.
SCAN_SRC="$TOOLS/security"
for f in repo-hooks/pre-commit repo-hooks/pf-secret-rules.toml gitleaks-fp-ledger.py; do
  [ -f "$SCAN_SRC/$f" ] || { echo "ОШИБКА: не найден $SCAN_SRC/$f" >&2; exit 2; }
done

for sk in pf-spec pf-tickets pf-do pf-replan pf-retro pf-auto; do
  mkdir -p "$HERE/skills/$sk"
  rsync -a --delete "$TOOLS/skill-library/skills/$sk/" "$HERE/skills/$sk/"
done

# The scanner copy — AFTER the rsync --delete of pf-do above, which would
# sweep it otherwise (sources checked at the top).
SCAN_DST="$HERE/skills/pf-do/scripts/secret-scan"
mkdir -p "$SCAN_DST/repo-hooks"
for f in repo-hooks/pre-commit repo-hooks/pf-secret-rules.toml gitleaks-fp-ledger.py; do
  cp "$SCAN_SRC/$f" "$SCAN_DST/$f"
done
chmod +x "$SCAN_DST/repo-hooks/pre-commit"

mkdir -p "$HERE/agents"
for ag in pf-architect pf-executor pf-reviewer; do
  cp "$TOOLS/skill-library/agents/$ag.md" "$HERE/agents/$ag.md"
done
cp "$INDEX_SRC" "$HERE/agents/index.yaml"

# tests/yaml-strict.sh (T-009, I-004): this repo's own test suite
# (tests/run.sh, T-016) runs it against skills/*/SKILL.md + agents/*.md
# frontmatter, but nothing carried it forward on sync — it had only ever
# been transplanted by hand (T-016), same class of drift risk fixed for
# pf-handoff's threshold-parity.sh (T-017). No path adaptation needed here
# (unlike that file): source and destination are both tests/yaml-strict.sh.
# Fail closed on the source so a moved/renamed canon file stops the sync
# instead of silently leaving a stale copy in place.
mkdir -p "$HERE/tests"
cp "$YS_SRC" "$HERE/tests/yaml-strict.sh"
chmod +x "$HERE/tests/yaml-strict.sh"

# hooks/ (T-110): process hooks of the workflow — the Stop hook wait-guard.sh
# lives in canon skill-library/hooks/, its bash tests in skill-library/hooks/
# tests/. They land here as hooks/*.sh and tests/*.sh (next to run.sh, so
# `bash tests/wait-guard.sh` works after sync; the test resolves the hook in
# both layouts). Copied file by file — NOT rsync --delete on tests/, which
# would sweep this repo's own run.sh/base-exec.sh. Sources were checked at
# the top of the script (fail closed before any write).
mkdir -p "$HERE/hooks" "$HERE/tests"
for h in "$HOOKS_SRC"/*.sh; do
  [ -f "$h" ] || continue
  cp "$h" "$HERE/hooks/$(basename "$h")"
  chmod +x "$HERE/hooks/$(basename "$h")"
done
for t in "$HOOKS_SRC"/tests/*.sh; do
  [ -f "$t" ] || continue
  cp "$t" "$HERE/tests/$(basename "$t")"
  chmod +x "$HERE/tests/$(basename "$t")"
done

# evals/ — rsync with --delete so a case removed from canon disappears here
# too; results/ (claude plugin eval output, gitignored) is excluded, so it is
# neither copied nor swept.
mkdir -p "$HERE/evals"
rsync -a --delete --exclude='results/' "$EVALS_SRC/" "$HERE/evals/"

# Стоп-лист частных слов (QA 11.10, К-1): имена проектов и клиентов автора не
# должны уехать в публичный репозиторий. Список живёт ВНЕ дистрибутива
# (${PF_PRIVATE_WORDS:-$TOOLS/security/private-words.txt}; строка — слово или
# шаблон grep -E, без учёта регистра; # и пустые строки пропускаются). Нашлось
# в дереве дистрибутива (без .git и .claude/) — синк падает с кодом 3 и
# называет файл:строку, само слово не печатает. Файла нет (у друга его нет) —
# предупреждение в stdout и продолжение. tests/run.sh делает ту же проверку.
PW="${PF_PRIVATE_WORDS:-$TOOLS/security/private-words.txt}"
if [ -f "$PW" ]; then
  pw_pat="$(mktemp "${TMPDIR:-/tmp}/pfwf-pw.XXXXXX")"; pw_err="$(mktemp "${TMPDIR:-/tmp}/pfwf-pw.XXXXXX")"
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$PW" > "$pw_pat" || true
  pw_hits=""
  if [ -s "$pw_pat" ]; then
    pw_hits="$(cd "$HERE" && find . -type f -not -path './.git/*' -not -path './.git' -not -path './.claude/*' -print0 \
      | xargs -0 grep -I -i -n -E -f "$pw_pat" -- /dev/null 2>"$pw_err" | cut -d: -f1,2 | sed 's|^\./||')" || true
  fi
  if [ -s "$pw_err" ]; then
    echo "ОШИБКА: стоп-лист $PW не проверен (grep: $(head -1 "$pw_err" | cut -c1-160))" >&2; rm -f "$pw_pat" "$pw_err"; exit 3
  fi
  rm -f "$pw_pat" "$pw_err"
  if [ -n "$pw_hits" ]; then
    echo "ОШИБКА: в дереве дистрибутива нашлись слова из стоп-листа $PW (файл:строка; слово не печатается):" >&2
    printf '%s\n' "$pw_hits" | sed 's/^/  /' >&2
    echo "Уберите их из канона (обезличить: «проект клиента») и повторите синк. Публиковать нельзя." >&2
    exit 3
  fi
  echo "Стоп-лист частных слов: чисто ($PW)"
else
  echo "ПРЕДУПРЕЖДЕНИЕ: стоп-лист частных слов не найден ($PW) — проверка пропущена"
fi

echo "Синхронизировано из: $TOOLS"
echo "Дальше: git diff → CHANGELOG.md → commit → tag vX.Y.Z → git push --tags"
