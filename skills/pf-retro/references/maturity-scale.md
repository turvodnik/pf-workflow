# Automation maturity scale (L0–L3)

Inspired by the loop engineering methodology (github.com/cobusgreyling/loop-engineering, MIT); wording original.

- **L0 — described.** The cycle is written down; nothing runs.
- **L1 — reports.** The cycle runs (manually or on schedule) but only reports; changes nothing.
- **L2 — with confirmation.** The cycle prepares changes; a human confirms every application.
- **L3 — autonomous.** Applies without confirmation. Allowed only with ALL of: an explicit denylist, a spending budget, a kill switch (one action turns it off), an escalation path to a human, a run log.

Movement rules:
- Up — after 2 consecutive clean runs at the current level.
- Down — immediately on an incident or a cost spike.

Before any automation answer: what does the cycle remember between runs (state)? who checks the result (a second agent or a human)? when must it stop and call a human?
