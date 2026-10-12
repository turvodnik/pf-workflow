---
type: regex
pattern: "^hello world\\n?$"
target: { source: file, path: hello.txt }
---

The change itself landed (the consumer sees `hello world`).
