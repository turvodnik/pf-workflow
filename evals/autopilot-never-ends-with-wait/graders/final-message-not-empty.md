---
type: regex
pattern: "\\S"
target: last_message
---

Negative control for the grader above: a run that hit the turn cap or timed out
ends with an empty final message, and `not_contains` would pass for free.
