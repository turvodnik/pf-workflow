---
type: regex
pattern: "\\nstatus: review\\n"
target: { source: file, path: .agents/runtime/tasks/T-001-hello-lowercase.md }
---

The executor sets `status: review`, never `done` (pf-do step 6).
