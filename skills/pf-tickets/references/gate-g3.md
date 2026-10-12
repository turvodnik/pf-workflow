# Gate G3: why both directions, and what to do with each divergence

Decomposition loses work in two opposite directions, and only one of them is
usually noticed. A requirement with no packet is felt at acceptance, when the
human asks for the thing nobody built. A packet with no requirement is quieter:
the work happens, it is even useful, and the spec silently stops describing the
project. Both are cheap to find before the work starts and dear to find after.

## Why both lists are printed even when empty

«No gaps» is a result; silence is not. A gate that prints nothing when it found
nothing is indistinguishable from a gate that did not run — the same output a
crashed script produces (§11: a check that could not run must be loud). The
printed empty list is the evidence that the reconciliation happened at all.

## Why an anchor is not a coverage proof

The mechanical form of G3 — read each packet's `spec:` field, resolve the
anchor, tick the box — reports green on two failures:

- the anchor points at a section that carries no requirements («Допущения»,
  «Риски», «Что НЕ делаем»): it resolves, but nothing there asks for the work;
- the anchor is borrowed from a section that belongs to a DIFFERENT packet.

The second one is the dangerous one, because a `grep` over anchors cannot see
it. Live case (workflow-upgrade wave, 2026-09-04): T-085 «проводка
experience-файлов» carried the anchor of section 2, which belongs to T-071 and
whose five delta lines require G4, the consistency reviewer, cross-voting and
the CREATION of an experience file — not the wiring that makes roles read it.
Mechanically green, substantively uncovered. Hence: open the section and check
that it actually asks for this packet's work.

## The four outcomes, and why one wording cannot serve two

A divergence is closed before work starts, and «вне объёма» is not a universal
answer: for an orphan packet it reads both as «cancel it» and as «keep it, it
was outside the original scope» — two opposite instructions in one phrase. So
the outcome is named explicitly:

| Divergence | Outcome |
|---|---|
| Requirement with no packet | Write the packet; or an explicit «вне объёма: <причина>» line in the spec |
| Packet with no requirement, doing real work | Add the spec point by delta, marked «найдено в волне, вне исходной спеки: <причина>, <дата>» |
| Packet with no requirement, not needed | `status: cancelled` with the reason in «Результат» |
| Packet with no requirement, waiting on a person | `⏳ человек: <что> · <дата>` (§10 debt form) |

The wave that produced this table had three orphan packets, and all three fell
into different rows: T-084 (sync of distributions — a wall found mid-wave, real
work), T-085 (wiring of experience files — a gate finding, real work), T-086
(the final end-to-end review — a spec acceptance criterion that had no packet).
Had «вне объёма» been the only wording available, all three would have read as
cancellations.

## Why G3 is re-run mid-wave

A packet born during execution — from a gate finding, from a wall in the
environment, from a human's aside — is precisely the packet no requirement asked
for, and by then nobody re-reads the spec. In the wave above, the spec's
«Декомпозиция» table listed 14 packets while 16 existed on disk, and the wave
line still named a pairing that the register had changed hours earlier. Both
were found by re-running G3, not by anyone re-reading the spec.
