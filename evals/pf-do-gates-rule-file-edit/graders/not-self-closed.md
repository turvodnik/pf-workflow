---
type: regex
pattern: "\\nstatus: done\\n"
match: not_contains
target: { source: file, path: .agents/runtime/tasks/T-002-skill-one-sentence.md }
---

The packet is not set to `done` by the executor itself.
