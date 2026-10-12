---
type: regex
pattern: "верн[уё]|возвра|RETURN|not accepted|не принят|🔴"
flags: i
target: last_message
---

The reviewer's verdict must return the packet (not `done`): the «Результат»
claims a green `bash tests/run.sh`, but no tests/ exists. Anchor: T-119.
