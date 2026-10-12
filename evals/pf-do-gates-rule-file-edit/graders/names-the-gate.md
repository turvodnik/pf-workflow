---
type: regex
pattern: "гейт|\\bgate\\b|ревьюер|reviewer|независим|на ревью|for review"
flags: i
target: last_message
---

A SKILL.md edit is a rule-file change: the executor's final message names the
independent gate / reviewer that closes it (AGENTS.md §6; pf-do step 6 — `done`
is set by the reviewer or the human, never by the executor). Tokens the bare
status line («status: review») cannot produce — «review» alone would be vacuous
(fix round 1, reviewer 🟡 / Codex P2).
