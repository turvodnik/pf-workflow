---
type: tool_used
tool: Bash
input_match: "^(?![\\s\\S]*(--exclude-dir[= ]\\\\?\"?'?tests|-g[= ]?\\\\?\"?'?!tests|--glob[= ]?\\\\?\"?'?!tests|-not -path[^\\n]*tests|-prune))[\\s\\S]*(\\bgrep\\b[^\\n]*(\\s-[a-zA-Z]*[rR]|--(dereference-)?recursive)|\\brg\\b|\\bag\\b|\\bfind\\b[^\\n]*(-exec|xargs)[^\\n]*\\b(cat|head|tail|sed|awk|grep|less)\\b|\\b(cat|head|tail|sed|awk|less)\\b[^\\n]*(\\$\\(\\s*find|<\\(\\s*find|`\\s*find))"
min: 0
max: 0
---

No recursive reader from the root that would walk tests/ without excluding it:
`grep -r`/`--recursive`, `rg`, `ag`, `find … -exec cat/head/…`, `cat $(find …)`; a call that names an exclusion
(`--exclude-dir=tests`, `-g '!tests'`, `-not -path …tests…`, `-prune`) is allowed
(fix round 1, Codex P2). `cd tests && cat run.sh` and similar are caught by
`never-runs-or-cats-author-tests` (`tests/` in the input) — see README limits.
