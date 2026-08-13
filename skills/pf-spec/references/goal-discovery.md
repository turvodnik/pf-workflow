# Goal discovery — a palette, not a script

Phase 0 helps the human find words for a problem they can feel but not yet
name. The Boris principle holds: the human OWNS "what and why" — owning means
CONFIRMING the final wording, not producing it alone. You dig together; they
sign.

## The palette (pick 1–2 that unlock the most; never run all of them)

| Theme | The move | What it yields |
|---|---|---|
| Symptom as a fact | «Расскажи последний конкретный случай, когда это разозлило / отняло время» — a story, not an abstraction | the raw material; real examples become the proof behind the wording |
| Five whys | follow the symptom down: «а почему это так?» ×N until the answer stops changing | the actual problem, often 2–3 layers below the stated one |
| Cost of doing nothing | «Что будет через месяц, если не трогать?» | the value of solving it, in the human's own terms |
| "Done looks like…" | «Представь, проблема исчезла: что ты завтра утром видишь/делаешь иначе?» | acceptance criteria in embryo — observable, checkable |
| Boundaries from fears | «Чего боишься сломать? Что точно нельзя?» | the "Что НЕ делаем" section |
| Prior art | check the journal/code/site YOURSELF for earlier attempts and half-solutions | questions you no longer need to ask |

## Anti-questionnaire rules

1. **One question, then listen.** Follow the answer, not the list. The next
   question comes from what they just said, or from the palette — whichever
   digs deeper.
2. **Draft early.** After 2–3 answers, mirror a draft: «Проблема: … (твой
   случай X). Цель: … Проверим так: …». Reacting to a wrong draft is easier
   than answering a right question. Expect to be corrected — that is the
   mechanism working, not failing.
3. **Propose the verification yourself.** The human often cannot name the
   checks — that is normal. Derive them from "done looks like…" and offer:
   «проверкой будет: <команда/наблюдение>. Годится?» They approve; they do
   not invent.
4. **Convergence, not completeness, ends the phase.** Stop when the human
   says «да, это оно» to the mirrored wording. Two exchanges can be enough.
   If it drags past ~10, park the fuzziest part as an explicit assumption
   and move — the spec's «Допущения» exists for this.
5. **Complication test.** Before asking one more question: does the answer
   change what we build? If not — assumption, not question.
6. **Every claim keeps its receipt.** In the final «Проблема»/цель, tie each
   statement to the concrete fact it came from («вчера 40 минут руками…»).
   That is what makes the wording provable rather than invented.

## Worked micro-example (shape, not content)

> Human: «SEO как-то буксует, не знаю, с чего начать.»
> Agent: «Расскажи последний случай, когда это стало заметно.»
> Human: «Вчера собирал отчёт по трём сайтам руками, 40 минут.»
> Agent: «А почему руками?» → «Скрипт есть, но верю ему наполовину.»
> Agent (draft): «Проблема: отчётам нельзя верить без ручной сверки (случай:
> 40 минут вчера). Цель: отчёт, которому веришь без сверки. Проверка: месяц
> без ручных правок отчёта. Это оно?»
> Human: «Почти — ещё цифры Метрики расходятся.» → draft v2 → «да, это оно».

Two themes used, three exchanges, confirmed wording with receipts. Then the
normal pf-spec interview continues — skipping goal/motivation, already done.
