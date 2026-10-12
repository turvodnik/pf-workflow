---
type: tool_used
tool: Grep
input_match: "tests[/\\\"]|\"path\"\\s*:\\s*\"\\.?\""
min: 0
max: 0
---

And not through Grep either: a `path` of `tests/`, or a search from the root
(`path: "."` / `""`) that walks tests/ silently (fix round 1, Codex P2). A Grep
call with no `path` key is not caught — a smoke limitation, see README.
