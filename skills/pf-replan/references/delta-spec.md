# The delta record: why three markers beat a rewritten spec

A spec is edited in place. Once the edit lands, the previous wording exists
nowhere — not in the file, and not in a form anyone will reconstruct from a git
diff of two long Russian texts at the moment they need it. The delta is the
record that survives: three or four lines saying what moved, so the executor who
took a packet on the old edition reads those lines instead of the spec again.

The idea is borrowed from OpenSpec (`ADDED` / `MODIFIED` / `REMOVED` per file)
and costs nothing to adopt: it is a form of record, not a tool.

## The live sample

In the origin system, `optimize/SPEC-workflow-upgrade.md` carries three real
deltas written during one wave (2026-09-04). The 16:30 one, verbatim:

```
**Дельта 2026-09-04 16:30** (по находкам прогона G3, тикет T-073):
- ADDED п. 14 (T-084, синк дистрибутивов) и п. 15 (T-085, проводка experience) —
  оба пакета родились посреди волны и до этой дельты висели без требования;
  помечены «найдено в волне, вне исходной спеки», чтобы отличать их от
  исходного объёма.
- ADDED п. 16 (T-086) — у критерия «финальное сквозное ревью» не было пакета.
- MODIFIED таблица «Декомпозиция» и строка волн: приведены к фактическому
  составу (17 пакетов, порядок волн от 15:05).
- Число пакетов: было 14, стало 17 (T-070…T-086).
```

What each part paid for:

- **the dated header with a trigger** — «по находкам прогона G3» tells the next
  reader that the spec changed because a gate found something, not because
  someone changed their mind. Class A/B/C (step 3) goes here when it is not
  obvious;
- **the ticket id next to the point** — rollback runs ticket → «Результат» →
  commits. Without the id, «п. 14» is a paragraph nobody can undo;
- **the last line, «было 14, стало 17»** — a countable before/after. Cheap, and
  it is what makes a silently drifted decomposition table visible;
- **the reason on the same line** — the delta is read on retro, where «what
  changed» without «why» is noise.

## Where the orphan-packet marker goes

A packet with no requirement, doing real work, is closed by gate G3 of
pf-tickets: add its spec point by delta and mark it «найдено в волне, вне
исходной спеки: <причина>, <дата>». Two places, not one — and both are in the
sample:

- the **new point itself** carries the marker beside the ticket id, so a reader
  arriving at it a month later sees that it was not in the original scope:
  `### 14. Синк дистрибутивов и push канона (T-084; найдено в волне, вне
  исходной спеки)`. The `<причина>` is the point's own «Причина:» line;
- the **delta line** carries the `<дата>` — its header is dated, so the date is
  not repeated on the point.

Use G3's wording, not a synonym: the two skills describe one seam, and a second
rendering of the same rule is how they start diverging
(`pf-tickets/references/gate-g3.md`, the four-outcomes table).

## Sub-changes are prose, not more markers

The earliest delta in the sample (13:50) nests markers inside markers —
`MODIFIED п. 11 (свод): УДАЛЕНО «разметка …»`. It reads as two verdicts on one
line: the outer marker says the point was modified, the inner one says something
was dropped, and the reader has to work out which is the change.

When the nested token is the English one, counting breaks too. A later delta in
the same file carries `- MODIFIED п. 15: … ; ADDED пакет T-087 (…)`, and on
2026-09-04 `grep -c ADDED` over that spec returned 5 for three actual
additions — the two extras being that nested token and a line that merely
MENTIONS the markers. The grep is an index into the deltas, not a metric, and
one marker per line at line start is what keeps it one. Everything inside the
line is a sentence.

## What the delta does NOT change

Cancellation of tickets, impact classes A/B/C and the rollback path are the
procedure and stay as they are (steps 2–4). The delta only records the SPEC
edit that the procedure already prescribes — and it goes IN the spec, never
into a second file: a separate «changes» log becomes a second source of truth
within a week (§2).
