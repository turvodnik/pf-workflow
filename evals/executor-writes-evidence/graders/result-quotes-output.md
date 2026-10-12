---
type: regex
pattern: "## Результат[\\s\\S]*hello world"
target: { source: file, path: .agents/runtime/tasks/T-001-hello-lowercase.md }
---

«Результат» carries the actual `cmd:` output (`hello world`). Anchored after the
«## Результат» heading: the criterion's own `expect: hello world` line above it
must not satisfy this grader (an untouched packet would pass otherwise).
