# Журнал изменений

*[English version](CHANGELOG.md)*

## v1.0.0 — 2026-08-09

Первый релиз дистрибутива.

- 5 скиллов конвейера: pf-spec (допрос → SPEC), pf-tickets (SPEC → самодостаточные task-пакеты, со шлюзом параллельности), pf-do (контракт исполнителя, коммит на тикет обязателен), pf-replan (изменение курса: классы влияния A/B/C, статус `cancelled`), pf-retro (шкала зрелости автоматизаций L1→L3).
- 3 агента: pf-architect, pf-executor, pf-reviewer.
- docs/rules-sections.ru.md — готовые разделы правил §7–§12 (генерируются из канона sync-скриптом).
- docs/PROCESS.{ru,en}.md — полное описание процесса; README на русском и английском.
- install.sh (симлинки в Claude Code / Codex / Gemini), sync-from-tools.sh (релизы из канона).
- Подсистема непрерывности сессий вынесена в отдельный инструмент-компаньон: github.com/turvodnik/pf-handoff.
