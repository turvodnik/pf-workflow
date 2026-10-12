#!/usr/bin/env bash
# Fixture for executor-writes-evidence: a tiny git repository with hello.txt
# and one packet carrying a single change criterion (`cmd:` / `expect:`).
# Runs in the empty eval workspace (cwd) before the agent starts; --scaffold
# only. The sandbox has no home directory, so git identity is set locally.
set -euo pipefail
git init -q .
git config user.name "Demo Executor"
git config user.email "demo@example.invalid"
printf 'Hello World\n' > hello.txt
mkdir -p .agents/runtime/tasks .agents/journal
cat > AGENTS.md <<'MD'
# Проект demo-hello — инструкции агентам

- Журнал решений: `.agents/journal/YYYY-MM-DD.md` (§10).
- Task-пакеты: `.agents/runtime/tasks/T-###-slug.md` (§9); «готово» — только со свежим выводом команды-доказательства (§11).
MD
cat > .agents/runtime/tasks/T-001-hello-lowercase.md <<'MD'
---
id: T-001
title: hello.txt — привести приветствие к нижнему регистру
status: todo
owner: —
depends_on: []
spec: —
updated: 2026-01-12
---

## Контекст
Проект demo-hello: один файл `hello.txt`, сейчас в нём `Hello World`. Потребитель ниже по конвейеру сравнивает строку побайтно и ждёт `hello world`.

## Задача
Заменить содержимое `hello.txt` на `hello world` (одна строка, нижний регистр).

## Критерии приёмки
- [ ] `hello.txt` содержит ровно `hello world` — change
  cmd: cat hello.txt
  expect: hello world

## Ограничения
- Ничего кроме `hello.txt` не менять.

## Результат (заполняет исполнитель)
MD
git add -A && git -c commit.gpgsign=false commit -q -m "init: hello.txt + packet T-001"
