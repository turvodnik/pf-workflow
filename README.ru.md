# pf-workflow — конвейер рабочих процессов для мульти-агентной разработки

[![Лицензия: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE) [![Релиз](https://img.shields.io/github/v/release/turvodnik/pf-workflow)](https://github.com/turvodnik/pf-workflow/releases) [![тесты](https://github.com/turvodnik/pf-workflow/actions/workflows/tests.yml/badge.svg)](https://github.com/turvodnik/pf-workflow/actions/workflows/tests.yml)

English overview: [README.md](README.md)

Один инструмент из правил, 6 скиллов и 3 агентов, который превращает работу с CLI-агентами (Claude Code, Codex, Gemini) из «одного бесконечного чата» в управляемый процесс:

```
идея → pf-spec (допрос → SPEC.md) → pf-tickets (нарезка на тикеты)
     → pf-do (исполнение тикета в свежем окне) → pf-replan (изменение курса)
     → pf-retro (пересмотр процессов раз в 2 недели)
     → pf-auto (автопилот: то же самое субагентами до конца — только по явной команде)
     + pf-handoff / pf-resume (непрерывность сессий: шпаргалка состояния + компакт)
```

## Какие боли это решает

- Большая задача в одном чате разваливается: контекстное окно дорожает, качество падает, лимиты сгорают.
- История решений («почему сделали так») теряется между сессиями и агентами.
- «Передумал посреди работы» стоит переделки всего, потому что непонятно, что от чего зависит.
- Несколько агентов в одном проекте не знают, что делали другие.

## Состав

| Компонент | Что делает |
|---|---|
| `skills/pf-spec` | Допрос до полного покрытия (один вопрос за раз + рекомендуемый ответ) → SPEC.md |
| `skills/pf-tickets` | SPEC → самодостаточные тикеты с зависимостями; шлюз параллельности (≥5 независимых → предложить стаю) |
| `skills/pf-do` | Контракт исполнителя тикета: свежее окно, доказательная приёмка, коммит на тикет, статусы, журнал |
| `skills/pf-replan` | Изменение курса: трассировка «спека → тикеты → коммиты», классы влияния A/B/C, точечный откат |
| `skills/pf-retro` | Ретро по журналам всех проектов; шкала доверия автоматизаций L1 → L2 → L3 |
| `skills/pf-auto` | Автопилот: волны заданий субагентами, гейт-ревью на каждой вехе, фикс-циклы ≤3 с эскалацией, параллель ≤2, стопы на опасных границах. Без инструмента субагентов `council.sh run` коммитит работу агента после секрет-скана — нужен gitleaks ≥ 8.19 в PATH (команда `gitleaks git`; macOS — `brew install gitleaks`, Ubuntu/Debian — бинарник с GitHub Releases: apt даёт старую 8.16) |
| `agents/` | pf-architect (спека+нарезка), pf-executor (один тикет, Sonnet), pf-reviewer (приёмка с доказательствами) |
| `hooks/wait-guard.sh` | Хук `Stop` Claude Code: ход не заканчивается прозой, пока в реестре этой сессии есть запущенная задача (I-029). Соседствует с чужими Stop-хуками (Orca, stop-review-gate плагина Codex): Claude Code запускает все зарегистрированные Stop-хуки по порядку в настройках хуков, каждый решает сам — блок любого останавливает ход, наш exit 0 чужой вердикт не перекрывает; наш читает только stdin и транскрипт, ничего не пишет, печатает одну строку причины и при любом сомнении уступает |
| `hooks/pf-session-id.sh` | Хук `SessionStart` Claude Code: печатает `Сессия: <8 знаков> — это значение поля session_id в HANDOFF/реестре` — значение, которое нужно полю `session_id:` реестра, чтобы `wait-guard.sh` его узнал. Молчит, если ту же строку уже печатает хук старта pf-handoff, и в агентах, запущенных `council.sh` |
| `docs/rules-sections.ru.md` | Готовые разделы §7–§12 для вашего глобального AGENTS.md/CLAUDE.md, написанные для вашей машины (без путей среды автора) — [EN](docs/rules-sections.en.md) |
| `docs/PROCESS.ru.md` | Полное описание процесса от идеи до ретро ([EN](docs/PROCESS.en.md)) |

Непрерывность сессий (живая шпаргалка состояния, пороги окна 40/60/75 %, выживание при компакте) — **отдельный инструмент-компаньон [pf-handoff](https://github.com/turvodnik/pf-handoff)**: скиллы pf-handoff/pf-resume, хуки и раздел правил §13. Два инструмента работают в связке, но ставятся и развиваются независимо.

## Ключевые принципы

1. **Файлы — единственная шина между агентами.** Тикеты, журнал, шпаргалки — обычный Markdown в git; работает у любого CLI-агента, читается человеком.
2. **Свежее окно на тикет.** Исполнитель видит только тикет + правила проекта — дёшево по лимитам и точнее по качеству.
3. **Коммит на тикет.** Хеши фиксируются в тикете → откат любой идеи = revert двух коммитов, а не «весь проект назад».
4. **Доказательства до «готово».** Заявить успех можно только со свежим выводом команды-проверки.
5. **Доверие автоматизациям — по лестнице L1 (отчёт) → L2 (с подтверждением) → L3 (сам, со стоп-краном).** Повышение после 2 чистых прогонов.

## Установка

```bash
git clone https://github.com/turvodnik/pf-workflow.git && cd pf-workflow
bash install.sh          # копии скиллов в ~/.claude/skills (+ .codex/.gemini, если эти CLI есть) и агентов в ~/.claude/agents
# bash install.sh --update  # обновить существующие копии после git pull
# bash install.sh --link    # режим симлинков вместо копий (клон тогда не перемещать)
# затем вставьте docs/rules-sections.ru.md (или .en.md) в свой глобальный AGENTS.md/CLAUDE.md
# рекомендуемый компаньон: github.com/turvodnik/pf-handoff (непрерывность сессий)
```

Установщик также регистрирует `hooks/wait-guard.sh` как хук Claude Code `Stop` и `hooks/pf-session-id.sh` как хук `SessionStart` в `~/.claude/settings.json`. Каждый раз, когда он меняет файл, он сначала копирует прежнее содержимое в `settings.json.bak-pf-workflow` рядом с ним (перезаписывая прошлую копию; если менять нечего, ничего не пишется), поэтому нужный оригинал сохраните сами; чужие хуки `Stop` (например, Orca) он не трогает. Запись указывает в этот клон, поэтому клон не перемещайте — или запустите `bash install.sh --sync` из нового места.

Если регистрация того же хука уже указывает на существующий файл вне этого клона (другая копия, чекпоинт мастерской автора), установщик оставляет её как есть и печатает по строке на запись:

```
KEPT: Stop → <путь> (registered elsewhere; re-run with --force to point it at this clone)
```

KEPT — не ошибка: это значит «чужая регистрация уже стоит». Если нужно, чтобы хук запускался из этого клона, выполните `bash install.sh --force` (работает с любым режимом). Регистрация на файл, которого уже нет, чинится без `--force`.

**Где хранить `SOLUTIONS.md`.** Если `~/.config/pf-handoff/config.json` уже есть (его записал pf-handoff), установщик не спрашивает. Иначе он задаёт тот же вопрос, что и pf-handoff (`1` — свой репозиторий GitHub, `2` — локально, по умолчанию; без терминала молча «локально»), либо берёт `PF_HANDOFF_SOLUTIONS=local|github:<url>`, и пишет тот же файл — с полем `solutions_path`, файлом SOLUTIONS, куда агент дописывает строку (в старый файл поле дописывается; для GitHub клонируйте репозиторий напечатанной командой `git clone`).

### Обновление

```bash
cd <ваш клон> && git pull && bash install.sh --update
```

Запись хука указывает в клон, поэтому `git pull` уже обновляет хук; скиллы и агенты — копии, их обновляет `--update`. pf-workflow самодостаточен: он ставится и обновляется отдельно от [pf-handoff](https://github.com/turvodnik/pf-handoff), у которого свой `git pull && bash install.sh`. Тихий режим дочерних CLI (`PF_COUNCIL_RUN=1`, его ставит `council.sh`) работает с pf-handoff ≥ 2.0.0; с более старым pf-handoff ребёнок получит подсказку хука старта «прочитай HANDOFF и продолжи» — обновите оба.

`.claude-plugin/plugin.json` нужен только для `claude plugin validate`/`eval` — поле `hooks` в нём не объявлено, поэтому установка репозитория как плагина не навешивает `hooks/wait-guard.sh` второй раз; путь установки выше (`install.sh`, запись в `~/.claude/settings.json`) не меняется.

### Удаление

Снять только то, что записал этот установщик, сохранив остальные настройки (восстановление старого бэкапа откатило бы всё, что записано после него). Запускать из клона:

```bash
f=~/.claude/settings.json
if [ -f "$f" ]; then cp "$f" "$f.bak-before-uninstall" && python3 - "$f" "$PWD/hooks/" <<'EOF'
import json, sys
path, ours = sys.argv[1], sys.argv[2]
d = json.load(open(path, encoding="utf-8"))
mine = lambda c: ours in str(c or "").replace("'\\''", "'")
hooks = d.get("hooks") or {}
for evt in list(hooks):
    for g in hooks[evt]:
        g["hooks"] = [h for h in g.get("hooks", []) if not mine(h.get("command"))]
    hooks[evt] = [g for g in hooks[evt] if g.get("hooks")]
    if not hooks[evt]:
        del hooks[evt]
json.dump(d, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
EOF
fi
for d in skills/*/; do n=$(basename "$d"); for s in ~/.claude/skills ~/.codex/skills ~/.gemini/skills; do
  { [ "$(readlink "$s/$n")" = "$PWD/skills/$n" ] || grep -q "^name: $n\$" "$s/$n/SKILL.md" 2>/dev/null; } && rm -rf "$s/$n"; done; done
for a in agents/*.md; do n=$(basename "$a" .md); t=~/.claude/agents/$n.md
  { [ "$(readlink "$t")" = "$PWD/agents/$n.md" ] || grep -q "^name: $n\$" "$t" 2>/dev/null; } && rm -f "$t"; done
```

Команда снимает наши записи `Stop` и `SessionStart` (те, что указывают в `hooks/` этого клона) и копии или ссылки скиллов и агентов с нашими именами; чужое остаётся. `~/.config/pf-handoff/config.json` (выбор хранилища SOLUTIONS) общий с pf-handoff: удаляйте `~/.config/pf-handoff`, только если pf-handoff не установлен, и сначала перенесите свой `SOLUTIONS.md`, если храните его там. В конце уберите разделы правил, которые вы вставили в свой `AGENTS.md`/`CLAUDE.md`.

## Для вашего ИИ-агента

Короткие шаги, которые агент (Claude Code, Codex, Gemini) может выполнить буквально. Команды — в терминале на машине пользователя; среда автора не нужна.

1. **Установка.**
   ```bash
   git clone https://github.com/turvodnik/pf-workflow.git ~/pf-workflow
   cd ~/pf-workflow && bash install.sh
   ```
   Ожидаемо: строки `OK: …` для 6 скиллов и 3 агентов, строка `install.sh: hooks in …/settings.json — registered: …` и `Done (mode: copy)`.
2. **Проверка.**
   ```bash
   ls ~/.claude/skills/pf-do/SKILL.md ~/.claude/agents/pf-executor.md
   grep -c -e 'wait-guard.sh' -e 'pf-session-id.sh' ~/.claude/settings.json   # 2 или больше
   gitleaks git --help >/dev/null 2>&1 || echo "нет gitleaks или он старше 8.19 — нужен для council.sh run и delegate --audit (macOS: brew install gitleaks; Ubuntu/Debian: бинарник с GitHub Releases, apt даёт 8.16)"
   ```
3. **Что установлено.** Скиллы `pf-spec`, `pf-tickets`, `pf-do`, `pf-replan`, `pf-retro`, `pf-auto` (в `~/.claude/skills`, а также в `~/.codex/skills` / `~/.gemini/skills`, если эти папки есть); роли `pf-architect`, `pf-executor`, `pf-reviewer` (в `~/.claude/agents`); два хука Claude Code в `~/.claude/settings.json` — `Stop` → `hooks/wait-guard.sh` (ход не заканчивается, пока в реестре этой сессии есть запущенная задача) и `SessionStart` → `hooks/pf-session-id.sh` (печатает `Сессия: <8 знаков> — это значение поля session_id в HANDOFF/реестре`; эти 8 знаков агент переписывает в поле `session_id:` реестра); `skills/pf-do/scripts/council.sh` — запускает исполнителя или ревьюера отдельным CLI, когда нет инструмента субагентов. `council.sh run` коммитит только после секрет-скана, поэтому ему нужен gitleaks ≥ 8.19 в `PATH` (команда `gitleaks git`). Свои файлы (`.claude/worktrees/`, `.agents/runtime/council*`) он прописывает в локальный `.git/info/exclude` репозитория, а не в `.gitignore`.
4. **Правила.** Покажите пользователю `docs/rules-sections.ru.md` (или `.en.md`) и после его «ок» вставьте в его глобальный `~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md`. Это его файл правил — без спроса не править.
5. **Как начать работу.** Фразы, которые говорит пользователь (или вы): «сделай спеку» (`pf-spec`, для большой задачи) → «разбей на задачи» (`pf-tickets`) → в свежем чате «выполни пакет T-001» (`pf-do`) → `/pf-auto` — весь конвейер на автопилоте, только по явной команде пользователя.
6. **Если видите `KEPT: …`.** Тот же хук уже зарегистрирован из другой копии на этой машине. Оставьте как есть или выполните `bash install.sh --force` из этого клона, чтобы хук запускался отсюда. Это не ошибка.
7. **Обновление.**
   ```bash
   cd ~/pf-workflow && git pull && bash install.sh --update
   ```
8. **Клон не перемещайте**: записи хуков указывают в него. Если переместили — `bash install.sh --sync` из нового места.

## Использование — шпаргалка

- `/pf-spec` — «сделай спеку» перед большой задачей; `/pf-tickets` — нарезка после «ок».
- Новое окно чата → «выполни тикет T-003» — исполнение по контракту pf-do.
- «Передумал» → `/pf-replan`. Раз в 2 недели → `/pf-retro`.
- Пауза или окно заканчивается → `/pf-handoff`, продолжить в новом чате → `/pf-resume` (команды компаньона pf-handoff).

## Разработка и релизы

Канон живёт в рабочей среде автора (`_tools/skill-library`); сюда изменения приходят релизами: `bash sync-from-tools.sh` → `CHANGELOG.md` → commit → tag `vX.Y.Z` → push. Доработки ведутся в ветке `dev`, в `main` — только отрелизенные состояния. Родственный отдельный дистрибутив подсистемы контекста: [pf-handoff](https://github.com/turvodnik/pf-handoff).

Прогнать тесты локально: `bash tests/run.sh` (bash 3.2+, coreutils, git, `jq`, `python3` и YAML-парсер для `python3` — PyYAML либо, за неимением, `ruby`. `jq` и `python3` обязательны по-настоящему: без любого из них набор становится красным, а не честно пропускается. ShellCheck и `actionlint` — единственные по-настоящему опциональные инструменты, пропускаются с указанием причины при отсутствии). Та же команда — в CI на каждый push и pull request ([`.github/workflows/tests.yml`](.github/workflows/tests.yml)). Настоящий Codex CLI не вызывается никогда и сеть не используется — вместо `codex` везде фикстура. [`tests/known-failures-T017.txt`](tests/known-failures-T017.txt) — список случаев, где несинкованная с каноном копия в этом репозитории осознанно красная; сейчас пуст, релиз только что синкан.

Инструкции скиллов и агентов — на английском (дешевле по токенам). Разделы правил — на русском и английском ([docs/rules-sections.ru.md](docs/rules-sections.ru.md), [docs/rules-sections.en.md](docs/rules-sections.en.md)). Шаблоны артефактов (SPEC, task-пакеты, реестры) — русские, язык рабочей среды автора; скиллы отвечают на языке пользователя.

---

**Pifagor Studio** — Владимир ([@turvodnik](https://github.com/turvodnik)) · Лицензия [MIT](LICENSE)
