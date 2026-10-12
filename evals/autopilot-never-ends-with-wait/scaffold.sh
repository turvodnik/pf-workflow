#!/usr/bin/env bash
# Fixture for autopilot-never-ends-with-wait: an autopilot registry
# (.agents/runtime/autopilot-run.md, pf-auto/references/registry-template.md
# shape, companion pf-handoff NOT installed) with one job in «запущен» and
# the packets it refers to. Runs in the empty eval workspace (cwd) before the
# agent starts; --scaffold only. Ids and names are invented.
set -euo pipefail
mkdir -p .agents/runtime/tasks .agents/journal
cat > AGENTS.md <<'MD'
# Проект demo-auto — инструкции агентам

- Журнал решений: `.agents/journal/YYYY-MM-DD.md` (§10).
- Task-пакеты: `.agents/runtime/tasks/T-###-slug.md` (§9).
- Реестр автопилота: `.agents/runtime/autopilot-run.md` (компаньон pf-handoff не установлен).
MD
cat > .agents/runtime/autopilot-run.md <<'MD'
# Реестр автопилота · demo-auto · 2026-01-12
session_id: 0f3a7c2e-demo

Параметры: fix_rounds=3, parallel=2, batch=1–3. BASE волны 1: 9c1d2e3.

| Задание | Тикеты | Субагент (модель/усилие) | Worktree | sha | fix_rounds | Маркер препасса | Статус |
|---|---|---|---|---|---|---|---|
| A (волна 1) | T-001 | pf-executor (Sonnet, low) `a7f19c0d4e2b5a61` | нет | — | 0/3 | — | запущен |
| B (волна 2) | T-002 | — | — | — | — | — | ждёт A |

## Запарковано (💭 — решает финальный ревью/отчёт)
1. —

## Стопы
- —
MD
cat > .agents/runtime/tasks/T-001-readme-usage.md <<'MD'
---
id: T-001
title: README — раздел «Использование»
status: in_progress
owner: claude
depends_on: []
spec: SPEC.md#usage
updated: 2026-01-12
---

## Контекст
Проект demo-auto. README без раздела «Использование».

## Задача
Добавить в README.md раздел «Использование» с примером запуска.

## Критерии приёмки
- [ ] В README.md есть заголовок `## Использование` — change
  cmd: grep -c '^## Использование' README.md
  expect: 1

## Результат (заполняет исполнитель)
MD
cat > .agents/runtime/tasks/T-002-changelog.md <<'MD'
---
id: T-002
title: CHANGELOG — запись о разделе «Использование»
status: todo
owner: —
depends_on: ['T-001']
spec: SPEC.md#usage
updated: 2026-01-12
---

## Контекст
После T-001 нужна запись в CHANGELOG.md.

## Задача
Добавить строку в `[Unreleased]`.

## Критерии приёмки
- [ ] `grep -c 'Использование' CHANGELOG.md` → 1 — change

## Результат (заполняет исполнитель)
MD
printf '# demo-auto\n\nДемо-проект.\n' > README.md
printf '# Changelog\n\n## [Unreleased]\n' > CHANGELOG.md
cat > .agents/journal/2026-01-12.md <<'MD'
## 09:00 · claude (оркестратор) · автопилот волна 1
Что: запущено задание A (T-001). Итог: ждёт сводки.
MD
