#!/usr/bin/env bash
# fake-codex-review.sh — stand-in for codex-review.sh next to a copied
# council.sh. Records argv; prints OK + REPORT (default) or the line found in
# $STUB_CTL/codex-review.mode (e.g. "SKIP: ..." / "FAIL: ...").
ctl="${STUB_CTL:?}"
printf '%s\n' "$@" > "$ctl/codex-review.args"
echo codex-review >> "$ctl/calls"
if [ -f "$ctl/codex-review.mode" ]; then cat "$ctl/codex-review.mode"; exit 1; fi
printf '# Codex review — test\n\n- [P3] example finding — a.sh:1\nCODEX-REVIEW-COMPLETE: 1\n' > "$ctl/codex-report.md"
echo "OK: Codex review finished in 1s (test)"
echo "REPORT: $ctl/codex-report.md"
exit 0
