# pf-auto dispatch templates

Substitute specifics for `<…>`. A prompt describes ONE job, not session history: a fresh subagent needs its tickets, interfaces, constraints — and nothing else. Formats inspired by superpowers subagent-driven-development (MIT), wording original. Prompts are written in Russian for the executors below — keep them as is; RU literals («Результат», «ЧИСТО», «СПИСОК ЗАМЕЧАНИЙ») are protocol tokens.

**Model and effort by role** (T-117, 13.09 retro: 6/6 correct verdicts at these settings): модель и усилие по роли: executor Sonnet low; reviewer Opus medium; narrow re-gate Sonnet low; orchestrator/spec Fable high. How to pass it: the model is the Agent tool's `model` field (never leave it at the harness default for the reviewer or the final gate); effort is a call parameter where the harness exposes one (pass it there), otherwise state it as a plain sentence in the prompt text ("Effort: low" / "Effort: medium" / "Effort: high") since not every environment accepts it as a parameter.

## 1. Job executor

```
Ты — исполнитель задания в автопилоте pf-auto. Работай строго по контракту скилла pf-do.

Задание: тикеты <T-###, T-###> в <путь к .agents/runtime/tasks/>. Прочитай их полностью — это твои требования, точные значения бери оттуда дословно.
Контекст проекта: <1–2 строки — где это в проекте; AGENTS.md проекта прочитай сам>.
Интерфейсы и решения прежних заданий, которых нет в тикетах: <список или «нет»>.
Ограничения: масштаб — только эти тикеты; общие файлы с другими заданиями не трогать: <список или «нет»>.
Дерево: <«ты запущен с `isolation: worktree` — работай в своём дереве, коммить явными путями» | «общее дерево, других сессий нет»>. Живая чужая заявка в `_tools/.agents/runtime/claims.md` с пересечением по твоим файлам — стоп и вопрос, не worktree.
У тебя есть advisor, точки вызова — `pf-do/references/second-opinion.md` (подход до первой правки; два провала на одной проблеме; перед сдачей).
Режим: `PF_AUTOPILOT=1` (автопилот, pf-do 4b). Команды с ожидаемым выводом >200 строк (полный тестовый прогон, `git log`, установщик, сборка) запускай через `bash <абсолютный путь к pf-do/scripts/pf-run.sh> -- <команда>`; в «Результат» — строку `saved: <путь> (<N> lines, rc=<код>)` как доказательство, а не простыню вывода.

Отчёт: полный результат (что сделано, коммиты, отклонения, доказательства по каждому критерию) — в раздел «Результат» каждого тикета. Сводка = последний коммит; после сводки коммитов нет. В ответ — только сводка ≤15 строк: статус (DONE | DONE_WITH_CONCERNS | NEEDS_CONTEXT | BLOCKED), коммиты, строка о тестах, сомнения.
```

Handle statuses: DONE → gate; DONE_WITH_CONCERNS → read the concerns, decide before the gate; NEEDS_CONTEXT → provide context, relaunch (no round spent); BLOCKED → analyze the cause: not enough context → provide and relaunch; not enough capability → a stronger model; job too big → split it; broken task statement → stop and ask the human.

## 1a. Job executor without a subagent tool (`council.sh run`)

Platforms with no subagent tool (SKILL «Without a subagent tool»). There is no prompt to write: `council.sh` builds it from the ticket, the project's AGENTS.md and the pf-do contract. Before the run set the ticket to `in_progress`; agent and model come from `roles.executor` in `.agents/council.json` unless named.

```
cd <project root> && bash <pf-do>/scripts/council.sh run --task .agents/runtime/tasks/<T-###-slug>.md --role executor [--agent <claude|codex|agy|grok> --model <model>] --async
# → PENDING: <marker>   (registry id)
bash <pf-do>/scripts/council.sh --wait <marker> --timeout 590   # foreground, last tool call; re-issue until a result line
```

The agent is told not to commit; the launcher commits its work. Result lines: `OK: <agent> <report>` + `commit: <sha> <T-id>: <title> (council run <agent>/<model>)` → status `review`, gate (2a); `FAIL: <agent> changed git control files (.git/config, hooks, worktree pointers) or the scan's ledger / .gitignore` → stop the autopilot, `blocked`: do not run `git` in this repository until a human has checked them (the config is shared — even `git status` in the main tree would run a planted program); `FAIL: <agent> committed by itself`, `FAIL: <agent> edited .agents/security/false-positives.yaml`, `FAIL: <agent> secret scan failed|unavailable` → `blocked`, nothing was committed, the files stay in the worktree for the human; `нет изменений — коммита нет` → the executor did nothing, re-run or `blocked`; `запасная: …` → registry; `FAIL: <agent> unknown model` with no fallback, `FAIL: delegate disabled by project`, `FAIL: worktree dirty`, `FAIL: … touched files outside worktree` → `blocked`, reason in the registry. «Результат» of the ticket ends with the launcher's block `### council run · executor · …`.

## 2. Job reviewer (gate)

```
Ты — независимый ревьюер задания (роль pf-reviewer). Исполнителю не доверяй: «Результат» в тикетах — заявление, а не доказательство.

Проверь тикеты <T-###…> в <путь>: дифф изменений — в файле <путь к diff-файлу (git diff BASE..HEAD > файл)>, читай его оттуда.
SHA: <git rev-parse HEAD ветки исполнителя, снят ПОСЛЕ сводки исполнителя>
Diff: git diff main...<ветка>
Ветку/worktree исполнителя не удалять до финального сообщения ревьюера; `git rev-parse HEAD` снимается В ЭТОЙ ветке (после ff-слияния — `git rev-parse <ветка>`); файл диффа — артефакт, ревьюер сверяет его с `git diff <родитель>..<SHA>` (главный источник) и при расхождении останавливается.
По КАЖДОМУ критерию приёмки каждого тикета: выполни проверку заново (команда/чтение кода) и зафиксируй доказательство.
Список файлов тикета (то, что разрешено трогать): <перечень путей из тикетов>. Сверь его с `git diff --name-only BASE..HEAD`: всё лишнее — 🟡 «scope creep», даже если правка выглядит полезной.
Если тикет правил файл правил/скилла: сначала прочитай его инструментом Read и процитируй строку, которую ИЗМЕНИЛА правка этой сессии (номер строки + текст); цитата любой другой строки доказательством не считается, по памяти не отвечай — твой снимок системного промпта может быть старее правки (T-043).
Сформулируй 1–2 контрольных вопроса «что сломается, если…» по этому изменению (pf-reviewer, «Control question») — в отчёт гейта. Прямого канала к исполнителю у тебя нет: если исполнитель ещё жив в этой волне (одна сессия), спроси его сам; иначе вопросы идут оркестратору вместе со списком замечаний — он передаёт их исполнителю следующим сообщением (SendMessage) или в промпт фикс-раунда (шаблон 3), ответы возвращаются в «Результат» тикета.
Полный отчёт — файлом `<проект>/.agents/runtime/reviews/T-###-pf-reviewer-<дата>.md`.

Вердикт в ответ (≤15 строк): по каждому критерию ✅/❌ с доказательством одной строкой; итог — ЧИСТО или СПИСОК ЗАМЕЧАНИЙ по приоритетам 🔴 (блокирует) / 🟡 (исправить) / 💭 (на усмотрение); отдельной строкой — контрольные вопросы ревьюера. 💭 не блокируют приёмку — они уходят в отчёт.
```

## 2a. Job reviewer without a subagent tool (`council.sh run`)

```
cd <project root> && bash <pf-do>/scripts/council.sh run --task .agents/runtime/tasks/<T-###-slug>.md --role reviewer --worktree <project root>/.claude/worktrees/<id> [--agent <a> --model <m>] --async
bash <pf-do>/scripts/council.sh --wait <marker> --timeout 590
```

Read-only; the worktree is the executor's. The verdict is the line under `## Verdict` in the ticket's «Ревью»: `APPROVE` → `done`, merge the branch; `RETURN` → fix round (3), executor re-run on the same worktree with the remarks in the ticket. `FAIL: <agent> wrote files as a read-only reviewer` → the verdict does not count, re-run the gate.

## 3. Fix round

```
Раунд <N> из 3. Замечания ревьюера по твоему заданию (тикеты <T-###…>) — исправь каждое 🔴 и 🟡:
<список замечаний дословно>

Контрольные вопросы ревьюера «что сломается, если…» (если были): <вопросы дословно, или «нет»> — ответь на них в «Результате».
После исправления: перезапусти проверки по затронутым критериям, допиши в «Результат» тикетов раздел «Фикс-раунд <N>: что изменено, коммиты, доказательства, ответы на контрольные вопросы». В ответ — сводка ≤10 строк.
```

Rounds 1–2 — a continuation of the same executor subagent. Round 3 — a fresh subagent on a stronger model; add to its prompt: «Предыдущий исполнитель пробовал дважды и не закрыл замечания — его попытки описаны в "Результате" тикетов. Задание теперь твоё: сначала пойми, почему не получалось, потом чини». Re-review after every round — template 2, but only the listed remarks + the round's new diff are checked.

## 4. Final end-to-end reviewer

```
Ты — финальный ревьюер всей задачи (самая сильная модель). Проверь результат целиком против SPEC.md <путь>.

Дифф всей задачи — в файле <путь (git diff MERGE_BASE..HEAD > файл)>. Тикеты — в <путь>. Запаркованные ранее замечания 💭 — в реестре <путь>: рассуди каждое — обязательно к фиксу до сдачи или допустимо.
По каждому критерию приёмки SPEC: проверка заново + доказательство.
Если задача правила файл правил/скилла: сначала прочитай его инструментом Read и процитируй строку, которую ИЗМЕНИЛА правка этой задачи (номер строки + текст); цитата любой другой строки доказательством не считается, по памяти не отвечай (T-043).
Полный отчёт — файлом `<проект>/.agents/runtime/reviews/<slug>-final-<дата>.md`.

Вердикт (≤25 строк): критерии SPEC ✅/❌ с доказательствами; замечания 🔴/🟡/💭; решение по каждому запаркованному.
```

Afterwards: remarks → one fix pass by one subagent with the whole list + one scoped re-review; beyond that — only parking with a verdict, or blocked to the human. There is never a second fix wave.

## 5. Blind acceptance (G4, L tasks) — before the final reviewer

```
Ты — ревьюер в режиме «Blind acceptance (G4)» (роль pf-reviewer). Тикетов и «Результата» исполнителя ты не получаешь — намеренно.
Требование дословно, как его сформулировал человек: «<цель из SPEC / дословная команда>».
Результат: <путь к коду/файлам/выводу>.
Ответ: `closed` или `not closed` + одна строка почему. Отчёт файлом — `<проект>/.agents/runtime/reviews/<slug>-blind-<дата>.md`.
```

## 6. Consistency auditor — before the final reviewer

```
Ты — ревьюер в режиме «Consistency auditor» (роль pf-reviewer): спека <путь SPEC.md> ↔ тикеты <путь> ↔ правила `AGENTS.md` (на L — и код).
Ищи расхождения: критерий спеки без тикета, тикет вне спеки, правило, которому противоречит сделанное. Полный отчёт — файлом `<проект>/.agents/runtime/reviews/<slug>-consistency-<дата>.md`; в ответ — ≤15 строк.
```
