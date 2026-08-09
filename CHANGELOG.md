# Changelog

## v1.0.0 — 2026-08-09

Первый релиз дистрибутива. / Initial release.

- 5 скиллов конвейера: pf-spec, pf-tickets (со шлюзом параллельности), pf-do (коммит на тикет обязателен), pf-replan (классы влияния A/B/C, статус cancelled), pf-retro (шкала L1→L3).
- 3 агента: pf-architect, pf-executor, pf-reviewer.
- docs/rules-sections.ru.md — готовые разделы правил §7–§12 (генерируются из канона sync-скриптом).
- docs/PROCESS.{ru,en}.md — полное описание процесса; README на русском и английском.
- install.sh (симлинки в Claude Code / Codex / Gemini), sync-from-tools.sh (релизы из канона).
- Подсистема непрерывности сессий вынесена в отдельный инструмент-компаньон: github.com/turvodnik/pf-handoff (v1.0.0).
