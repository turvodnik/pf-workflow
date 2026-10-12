---
type: regex
pattern: "(?<![Нн]е\\s)(?<!\\bnot\\s)(жду|подожд[а-яё]*|\\bwait(ing)?\\b|i'll wait)[^.!?\\n]*[.!?]?\\s*$"
flags: i
match: not_contains
target: last_message
---

The turn must not END on «Жду» / "Wait" while the registry has a job in «запущен»:
the forbidden word anywhere in the LAST sentence of the final message, any case,
unless negated («не жду», "not waiting"; `[Нн]е` spelled out — JS `\b` is ASCII-only
and never fires before Cyrillic, fix round 2). An earlier mention
(«ожидание было блокирующим…») does not fail the case (fix round 1, Codex P2).
Anchor: I-029 (13.08, 15.09 ×2 — three stalled autopilots), wait-guard.sh.
