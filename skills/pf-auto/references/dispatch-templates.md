# pf-auto dispatch templates

Substitute specifics for `<…>`. A prompt describes ONE job, not session history: a fresh subagent needs its tickets, interfaces, constraints — and nothing else. Formats inspired by superpowers subagent-driven-development (MIT), wording original. Prompts are written in Russian for the executors below — keep them as is; RU literals («Результат», «ЧИСТО», «СПИСОК ЗАМЕЧАНИЙ») are protocol tokens.

## 1. Job executor

```
Ты — исполнитель задания в автопилоте pf-auto. Работай строго по контракту скилла pf-do.

Задание: тикеты <T-###, T-###> в <путь к .agents/runtime/tasks/>. Прочитай их полностью — это твои требования, точные значения бери оттуда дословно.
Контекст проекта: <1–2 строки — где это в проекте; AGENTS.md проекта прочитай сам>.
Интерфейсы и решения прежних заданий, которых нет в тикетах: <список или «нет»>.
Ограничения: масштаб — только эти тикеты; общие файлы с другими заданиями не трогать: <список или «нет»>.

Отчёт: полный результат (что сделано, коммиты, отклонения, доказательства по каждому критерию) — в раздел «Результат» каждого тикета. В ответ — только сводка ≤15 строк: статус (DONE | DONE_WITH_CONCERNS | NEEDS_CONTEXT | BLOCKED), коммиты, строка о тестах, сомнения.
```

Handle statuses: DONE → gate; DONE_WITH_CONCERNS → read the concerns, decide before the gate; NEEDS_CONTEXT → provide context, relaunch (no round spent); BLOCKED → analyze the cause: not enough context → provide and relaunch; not enough capability → a stronger model; job too big → split it; broken task statement → stop and ask the human.

## 2. Job reviewer (gate)

```
Ты — независимый ревьюер задания (роль pf-reviewer). Исполнителю не доверяй: «Результат» в тикетах — заявление, а не доказательство.

Проверь тикеты <T-###…> в <путь>: дифф изменений — в файле <путь к diff-файлу (git diff BASE..HEAD > файл)>, читай его оттуда.
По КАЖДОМУ критерию приёмки каждого тикета: выполни проверку заново (команда/чтение кода) и зафиксируй доказательство.
Проверь границы: нет ли изменений вне задачи тикетов.
Если тикет правил файл правил/скилла: сначала прочитай его инструментом Read и подтверди текущую редакцию (номер строки/размер или цитата), не отвечай по памяти — твой снимок системного промпта может быть старее правки.

Вердикт в ответ (≤20 строк): по каждому критерию ✅/❌ с доказательством одной строкой; итог — ЧИСТО или СПИСОК ЗАМЕЧАНИЙ по приоритетам 🔴 (блокирует) / 🟡 (исправить) / 💭 (на усмотрение). 💭 не блокируют приёмку — они уходят в отчёт.
```

## 3. Fix round

```
Раунд <N> из 3. Замечания ревьюера по твоему заданию (тикеты <T-###…>) — исправь каждое 🔴 и 🟡:
<список замечаний дословно>

После исправления: перезапусти проверки по затронутым критериям, допиши в «Результат» тикетов раздел «Фикс-раунд <N>: что изменено, коммиты, доказательства». В ответ — сводка ≤10 строк.
```

Rounds 1–2 — a continuation of the same executor subagent. Round 3 — a fresh subagent on a stronger model; add to its prompt: «Предыдущий исполнитель пробовал дважды и не закрыл замечания — его попытки описаны в "Результате" тикетов. Задание теперь твоё: сначала пойми, почему не получалось, потом чини». Re-review after every round — template 2, but only the listed remarks + the round's new diff are checked.

## 4. Final end-to-end reviewer

```
Ты — финальный ревьюер всей задачи (самая сильная модель). Проверь результат целиком против SPEC.md <путь>.

Дифф всей задачи — в файле <путь (git diff MERGE_BASE..HEAD > файл)>. Тикеты — в <путь>. Запаркованные ранее замечания 💭 — в реестре <путь>: рассуди каждое — обязательно к фиксу до сдачи или допустимо.
По каждому критерию приёмки SPEC: проверка заново + доказательство.
Если задача правила файл правил/скилла: сначала прочитай его инструментом Read и подтверди текущую редакцию (номер строки/размер или цитата), не отвечай по памяти — твой снимок системного промпта может быть старее правки.

Вердикт (≤25 строк): критерии SPEC ✅/❌ с доказательствами; замечания 🔴/🟡/💭; решение по каждому запаркованному.
```

Afterwards: remarks → one fix pass by one subagent with the whole list + one scoped re-review; beyond that — only parking with a verdict, or blocked to the human. There is never a second fix wave.
