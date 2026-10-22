#!/usr/bin/env bash
# tests/run.sh — table-driven safety tests for codex-review.sh (T-008).
# One command: `bash tests/run.sh`. Never invokes the real `codex` CLI —
# every scenario runs the SUT under a curated PATH containing only
# fixtures/fake-codex plus a fixed, minimal toolset (see lib.sh). `pkill` is
# never on that PATH, in any test, by design (F-11).
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TESTS_DIR/lib.sh"

SUT="${PF_CODEX_REVIEW_SCRIPT:-$TESTS_DIR/../codex-review.sh}"
[ -f "$SUT" ] || { echo "cannot find SUT at $SUT"; exit 90; }

# Portable form: GNU mktemp (Linux, incl. ubuntu-latest) rejects a bare
# `-t <prefix>` ("too few X's in template"); BSD mktemp (macOS) accepts it.
# An explicit template with X's works identically on both (verified T-016).
WORKROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-review-tests-work.XXXXXXXX")"
echo "$WORKROOT" >> "$CLEANUP_DIRS_FILE"

echo "codex-review.sh test suite"
echo "SUT: $SUT"
echo "bash: $BASH_BIN ($("$BASH_BIN" --version | head -1))"

# Shared curated PATH variants, built once and reused by every group below.
MP_JQ="$WORKROOT/minpath-jq"; make_minpath "$MP_JQ" jq
MP_PY="$WORKROOT/minpath-py"; make_minpath "$MP_PY" python3
MP_NONE="$WORKROOT/minpath-none"; make_minpath "$MP_NONE"
MP_NO_CODEX="$WORKROOT/minpath-no-codex"; make_minpath_no_codex "$MP_NO_CODEX"

# ===========================================================================
group "Gates: absent codex / not a repo skip cleanly (sanity, not an F-finding)"
# ===========================================================================
repo="$(new_repo)"
out="$( cd "$repo" && sut_run 5 "$MP_NO_CODEX" -- --scope uncommitted 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^SKIP:'; then
  pass "codex absent from PATH -> SKIP, exit 0"
else
  fail "codex absent from PATH -> unexpected (rc=$rc)" "stdout: $out"
fi
rm -rf "$repo"

nogit="$WORKROOT/not-a-repo"; mkdir -p "$nogit"
out="$( cd "$nogit" && sut_run 5 "$MP_JQ" -- --scope uncommitted 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^SKIP:'; then
  pass "not a git repository -> SKIP, exit 0"
else
  fail "not a git repository -> unexpected (rc=$rc)" "stdout: $out"
fi

# ===========================================================================
group "W1'': every fork under set -m runs with stderr on /dev/null (class guard, all pf-do scripts)"
# ===========================================================================
# Under set -m a non-interactive bash (macOS 3.2) may lose the setpgid race and
# the CHILD prints «child setpgid (N to N): Operation not permitted» with the
# stderr it inherited at fork. The cure is local to each fork site, which is
# why fixing one file at a time kept missing the next one (QA 2.1.0 W1, W1′,
# W1''). The race is rare (~3 % of loaded runs), so a behavioural test cannot
# guard it; this static check does: inside every `set -m … set +m` region of
# codex-review.sh, council.sh and tests/lib.sh, a background fork must be
# `{ … & VAR=$!; } … 2>/dev/null`, and a line ending in a bare `&` is red.
setm_scan() {
  awk '
    /^[[:space:]]*set -m/ { on = 1; regions++; next }
    /^[[:space:]]*set \+m/ { on = 0; next }
    on && /=\$!/ {
      if ($0 ~ /=\$!;[[:space:]]*}.*2>\/dev\/null/) forks++
      else { bad++; print FILENAME ":" FNR ": " $0 }
      next
    }
    on {
      line = $0; sub(/[[:space:]]*#.*$/, "", line)
      if (line ~ /[^&>]&[[:space:]]*$/) { bad++; print FILENAME ":" FNR ": " $0 }
    }
    END { printf "regions=%d forks=%d bad=%d\n", regions, forks, bad }
  ' "$@"
}
setm_out="$(setm_scan "$SUT" "$(dirname "$SUT")/council.sh" "$TESTS_DIR/lib.sh" 2>&1)"
setm_sum="$(printf '%s\n' "$setm_out" | tail -1)"
case "$setm_sum" in
  "regions=5 forks=6 bad=0") pass "set -m forks guarded: $setm_sum" ;;
  *) fail "a fork under set -m is not wrapped in { … & VAR=\$!; } 2>/dev/null (or the region count changed — recount and update)" "$setm_out" ;;
esac

# ===========================================================================
group "F-04: consent matrix (--yes must never override an unverifiable or recorded-false consent)"
# ===========================================================================
expected_calls() {
  local file_state="$1" reader_name="$2" yes="$3"
  case "$file_state" in
    none) [ "$yes" = 1 ] && echo 1 || echo 0 ;;
    true) [ "$reader_name" = "none" ] && echo 0 || echo 1 ;;
    false|malformed|unreadable) echo 0 ;;
  esac
}

f04_case() {
  local file_state="$1" reader_name="$2" reader_path="$3" yes_flag="$4"
  local expect_calls; expect_calls="$(expected_calls "$file_state" "$reader_name" "$yes_flag")"
  local repo; repo="$(new_repo)"
  echo "x=1" > "$repo/change.sh"
  case "$file_state" in
    none) : ;;
    true) consent_file "$repo" '{"enabled": true}' ;;
    false) consent_file "$repo" '{"enabled": false}' ;;
    malformed) consent_file "$repo" '{"enabled": fal' ;;
    unreadable)
      if [ "$(id -u)" = "0" ]; then
        skip_row "$file_state/$reader_name/yes=$yes_flag" "running as root — permission bits don't restrict root, can't simulate an unreadable file"
        rm -rf "$repo"
        return 0
      fi
      consent_file "$repo" '{"enabled": true}'
      chmod 000 "$repo/.agents/codex-review.json"
      ;;
  esac
  local calllog; calllog="$(mktemp "${TMPDIR:-/tmp}/codex-review-test-calllog.XXXXXXXX")"
  local args
  args=(--scope uncommitted)
  [ "$yes_flag" = 1 ] && args+=(--yes)
  local out rc calls label
  out="$( cd "$repo" && sut_run 10 "$reader_path" "FAKE_CODEX_CALL_LOG=$calllog" "FAKE_CODEX_MODE=clean" -- "${args[@]+"${args[@]}"}" 2>&1 )"
  rc=$?
  calls=0
  [ -s "$calllog" ] && calls="$(grep -c . "$calllog" 2>/dev/null || true)"
  label="file=$file_state reader=$reader_name yes=$yes_flag"
  if [ "$calls" = "$expect_calls" ]; then
    pass "$label -> $calls call(s) (expected $expect_calls), rc=$rc"
  else
    fail "$label -> $calls call(s) (expected $expect_calls), rc=$rc" "stdout: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
  fi
  rm -f "$calllog"
  rm -rf "$repo"
}

for fs in none true false malformed unreadable; do
  for rn in jq python3 none; do
    case "$rn" in jq) rp="$MP_JQ" ;; python3) rp="$MP_PY" ;; none) rp="$MP_NONE" ;; esac
    for yes in 0 1; do
      f04_case "$fs" "$rn" "$rp" "$yes"
    done
  done
done

# ===========================================================================
group "F-05: --out never touches a byte that was already there"
# ===========================================================================
f05_reject() {
  local label="$1" setup_fn="$2"
  local repo; repo="$(new_repo)"
  consent_file "$repo" '{"enabled": true}'
  echo "x=1" > "$repo/change.sh"
  local target="$repo/victim"
  "$setup_fn" "$target"
  local before_hash="" before_target=""
  if [ -f "$target" ]; then before_hash="$(sha256_of "$target")"; fi
  if [ -L "$target" ]; then before_target="$(readlink "$target")"; fi
  local calllog; calllog="$(mktemp "${TMPDIR:-/tmp}/codex-review-test-calllog.XXXXXXXX")"
  local out rc t0 t1 elapsed
  t0=$(date +%s)
  out="$( cd "$repo" && sut_run 10 "$MP_JQ" "FAKE_CODEX_CALL_LOG=$calllog" "FAKE_CODEX_MODE=clean" -- --scope uncommitted --out "$target" 2>&1 )"
  rc=$?
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  local calls=0
  [ -s "$calllog" ] && calls="$(grep -c . "$calllog" 2>/dev/null || true)"
  local ok=1 reason=""
  if [ "$calls" != 0 ]; then ok=0; reason="codex was called ($calls)"; fi
  # A path that must be REJECTED has to be rejected fast, on its own — never
  # by the test's own 10s outer safety-net timeout. rc=137 (128+SIGKILL) or
  # elapsed close to the budget both mean the SUT hung instead of detecting
  # the occupied path (e.g. blocking forever writing into an existing FIFO
  # with no reader) — that is a defect in its own right, not a pass.
  if [ "$rc" = 137 ] || [ "$elapsed" -ge 8 ]; then
    ok=0; reason="$reason SUT hung and had to be force-killed (elapsed=${elapsed}s, rc=$rc)"
  fi
  if [ -n "$before_hash" ]; then
    local after_hash; after_hash="$(sha256_of "$target")"
    [ "$after_hash" = "$before_hash" ] || { ok=0; reason="$reason sha256 changed"; }
  fi
  if [ -n "$before_target" ]; then
    local after_target; after_target="$(readlink "$target" 2>/dev/null || true)"
    [ "$after_target" = "$before_target" ] || { ok=0; reason="$reason symlink target changed"; }
  fi
  if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q '^SKIP:'; then
    ok=0; reason="$reason rc=0 and no SKIP: line"
  fi
  if [ "$ok" = 1 ]; then
    pass "--out onto existing $label -> rejected untouched (calls=$calls, rc=$rc)"
  else
    fail "--out onto existing $label -> NOT safely rejected ($reason)" "stdout: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
  fi
  rm -f "$calllog"
  rm -rf "$repo"
}

f05_setup_file() { printf 'DO NOT CLOBBER\n' > "$1"; }
f05_setup_symlink() { printf 'DO NOT CLOBBER\n' > "$1.real"; ( cd "$(dirname "$1")" && ln -s "$(basename "$1").real" "$(basename "$1")" ); }
f05_setup_dangling_symlink() { ln -s "/nonexistent/nowhere-$$" "$1"; }
f05_setup_fifo() { PATH="$FULL_PATH" mkfifo "$1"; }
f05_setup_dir() { mkdir -p "$1"; }

f05_reject "regular file" f05_setup_file
f05_reject "symlink to existing file" f05_setup_symlink
f05_reject "dangling symlink" f05_setup_dangling_symlink
f05_reject "FIFO" f05_setup_fifo
f05_reject "directory" f05_setup_dir

# brand-new path: must still be ALLOWED (the fix must not become a blanket refusal).
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
target="$repo/brand-new-report.md"
calllog="$(mktemp "${TMPDIR:-/tmp}/codex-review-test-calllog.XXXXXXXX")"
out="$( cd "$repo" && sut_run 10 "$MP_JQ" "FAKE_CODEX_CALL_LOG=$calllog" "FAKE_CODEX_MODE=clean" -- --scope uncommitted --out "$target" 2>&1 )"
rc=$?
calls=0
[ -s "$calllog" ] && calls="$(grep -c . "$calllog" 2>/dev/null || true)"
if [ "$calls" = 1 ] && [ -s "$target" ]; then
  pass "--out onto a brand-new path -> proceeded, report written (rc=$rc)"
else
  fail "--out onto a brand-new path -> did not proceed as expected (calls=$calls, rc=$rc)" "stdout: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
fi
rm -f "$calllog"; rm -rf "$repo"

# Regression (T-017 fix round, found by the workflow pilot, not by this
# harness — every case above always ran with `cd "$repo"` + an absolute
# --out, so none of them could see this): a RELATIVE --out must resolve
# against the cwd the script was invoked from, not against $REPO_ROOT after
# the internal `cd` further down in the SUT. Two sibling cases share one
# setup: a precious file at repo ROOT (must never be touched by a run from
# a SUBDIRECTORY) and an empty subdirectory to invoke from.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
printf 'PRECIOUS-DO-NOT-CLOBBER\n' > "$repo/victim.md"
root_hash_before="$(sha256_of "$repo/victim.md")"
mkdir -p "$repo/sub"
# The uncommitted change lives INSIDE sub/, not at repo root: `git
# ls-files --others` (unlike `diff`/`status`) scopes to the invocation cwd
# and below when given no pathspec, so a root-level untracked file is
# invisible to the SUT once it cd's into sub/ — that would read as "SKIP:
# empty diff" and never reach the --out code path this case exists to
# exercise. Independent of the F-05 bug under test; noted, not fixed here.
echo "x=1" > "$repo/sub/change.sh"

# 2a. $repo/sub/victim.md does NOT exist yet: a relative `--out victim.md`
# must resolve to THAT (new) path, not to $repo/victim.md — so the run
# proceeds normally (OK, not SKIP: absolutizing is not a blanket refusal)
# and the root-level file is never touched.
calllog="$(mktemp "${TMPDIR:-/tmp}/codex-review-test-calllog.XXXXXXXX")"
out="$( cd "$repo/sub" && sut_run 10 "$MP_JQ" "FAKE_CODEX_CALL_LOG=$calllog" "FAKE_CODEX_MODE=clean" -- --scope uncommitted --out victim.md 2>&1 )"
rc=$?
calls=0
[ -s "$calllog" ] && calls="$(grep -c . "$calllog" 2>/dev/null || true)"
root_hash_after="$(sha256_of "$repo/victim.md")"
if [ "$calls" = 1 ] && [ "$root_hash_after" = "$root_hash_before" ] && [ -s "$repo/sub/victim.md" ]; then
  pass "relative --out from a subdirectory -> resolves next to the caller (sub/victim.md), \$REPO_ROOT/victim.md untouched (rc=$rc)"
else
  fail "relative --out from a subdirectory -> did not resolve against the invocation cwd (calls=$calls, rc=$rc, root file changed=$([ "$root_hash_after" = "$root_hash_before" ] && echo no || echo YES))" "stdout: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
fi
rm -f "$calllog"

# 2b. Same setup, but $repo/sub/victim.md (the RESOLVED path) already
# exists too: the F-05 guard must reject it there, same as any other
# pre-existing --out, and leave BOTH copies untouched.
printf 'SUBDIR-PRECIOUS-TOO\n' > "$repo/sub/victim.md"
sub_hash_before="$(sha256_of "$repo/sub/victim.md")"
calllog="$(mktemp "${TMPDIR:-/tmp}/codex-review-test-calllog.XXXXXXXX")"
out="$( cd "$repo/sub" && sut_run 10 "$MP_JQ" "FAKE_CODEX_CALL_LOG=$calllog" "FAKE_CODEX_MODE=clean" -- --scope uncommitted --out victim.md 2>&1 )"
rc=$?
calls=0
[ -s "$calllog" ] && calls="$(grep -c . "$calllog" 2>/dev/null || true)"
root_hash_after2="$(sha256_of "$repo/victim.md")"
sub_hash_after="$(sha256_of "$repo/sub/victim.md")"
if [ "$calls" = 0 ] && [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^SKIP:' \
   && [ "$root_hash_after2" = "$root_hash_before" ] && [ "$sub_hash_after" = "$sub_hash_before" ]; then
  pass "relative --out from a subdirectory onto an existing sub/victim.md -> SKIP (F-05), both copies untouched (rc=$rc)"
else
  fail "relative --out from a subdirectory onto an existing sub/victim.md -> NOT safely rejected (calls=$calls, rc=$rc)" "stdout: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
fi
rm -f "$calllog"; rm -rf "$repo"

# ===========================================================================
group "F-09: unrecognized non-empty output must read as FAIL: not reviewed, not 0 findings"
# ===========================================================================
# f09_case <fake-codex mode> <expect: ok|fail-not-reviewed> <desc>
#            [expect-hint: hint|nohint] [extra env assignments...]
#
# The 4th argument (I-033/T-024) asserts on the SECOND ECHELON's `HINT:` line
# rather than on the verdict: since the whitelist decides the verdict, the old
# length/shape detectors now only shape the WORDING of a failure. Pinning the
# hint is what keeps ERR_SHAPE_CHARS honest — raise the threshold and the
# "one byte over" case starts printing a hint it must not print.
f09_case() {
  local mode="$1" expect="$2" desc="$3" expect_hint="${4:-}"
  shift 4 2>/dev/null || shift $#
  local envs=("FAKE_CODEX_MODE=$mode")
  local e
  for e in "$@"; do envs+=("$e"); done
  local repo; repo="$(new_repo)"
  consent_file "$repo" '{"enabled": true}'
  echo "x=1" > "$repo/change.sh"
  local out rc
  out="$( cd "$repo" && sut_run 10 "$MP_JQ" "${envs[@]}" -- --scope uncommitted 2>&1 )"
  rc=$?
  local got=""
  if printf '%s' "$out" | grep -qE '^FAIL:.*not reviewed'; then got="fail-not-reviewed"
  elif printf '%s' "$out" | grep -qE '^OK:.*'; then got="ok"
  fi
  local ok=1 reason=""
  [ "$got" = "$expect" ] || { ok=0; reason="got '$got', expected '$expect'"; }
  if [ -n "$expect_hint" ]; then
    local got_hint="nohint"
    printf '%s' "$out" | grep -q '^HINT:' && got_hint="hint"
    [ "$got_hint" = "$expect_hint" ] || { ok=0; reason="$reason; second echelon: got '$got_hint', expected '$expect_hint'"; }
  fi
  if [ "$ok" = 1 ]; then
    pass "$desc -> $got${expect_hint:+/$expect_hint} (rc=$rc)"
  else
    fail "$desc -> $reason (rc=$rc)" "stdout: $(printf '%s' "$out" | head -4 | tr '\n' '|')"
  fi
  rm -rf "$repo"
}

f09_case error-rc0 fail-not-reviewed "stdout 'authentication failed...' + exit 0"
f09_case clean ok "genuine 'no problems found' text (must NOT become a false FAIL)"
f09_case success ok "genuine findings present (baseline)"
f09_case empty fail-not-reviewed "empty output + exit 0 (pre-existing contract)"
f09_case crash fail-not-reviewed "nonzero exit (pre-existing contract)"
# I-022: F-09's own fix over-fired on genuine review prose about auth/rate
# limiting. A clean review that legitimately uses these words, but is long
# and structured (not shaped like a terse provider error), must read OK —
# while a genuinely short, unstructured provider failure using the same
# words must still read as fail-not-reviewed (regression guard for F-09).
f09_case clean-security-prose ok "clean review whose prose says 'rate limit' + 'authentication failed' (I-022, must NOT become a false FAIL)"
f09_case error-rc0 fail-not-reviewed "short unstructured 'authentication failed' stdout (I-022 regression guard for F-09)"

# I-031 (T-023): the length gate above stops a raw error dump from being
# flagged once it runs past ERR_SHAPE_LINES/ERR_SHAPE_CHARS — measured on
# these exact three shapes by the T-020 gate (T-023 context). The
# structural, length-independent check must catch all three.
f09_case traceback fail-not-reviewed "python traceback, 6 lines/281 bytes — over the length gate, still a raw error (I-031)"
f09_case html-error fail-not-reviewed "HTML error page, 8 lines/185 bytes — over the length gate, still a raw error (I-031)"
f09_case html-error-minified fail-not-reviewed "minified HTML error page, one line/307 bytes — over the length gate, still a raw error (I-031)"

# I-031 regression guard: a genuine clean review that QUOTES a traceback
# line / HTML prefix / JSON error envelope inside its own prose (not as the
# raw output's opening line) must stay OK. This is the trap named in the
# T-023 packet: "no [P1]/[P2]/[P3] markers -> not a report" is false, an
# honest clean review has none by definition — these three fixtures prove
# the structural check does not fall into it.
f09_case clean-quotes-traceback ok "clean review whose prose quotes a traceback line as an example (I-031, must NOT become a false FAIL)"
f09_case clean-quotes-html ok "clean review whose prose quotes an HTML doctype prefix as an example (I-031, must NOT become a false FAIL)"
f09_case clean-quotes-json-error ok "clean review whose prose quotes a JSON error envelope as an example (I-031, must NOT become a false FAIL)"

# T-020 gate hygiene: pin the ERR_SHAPE_CHARS boundary itself so raising it
# later cannot slip past unnoticed (previously only a fixture that clears
# it with room to spare — clean-security-prose, 382 bytes — existed).
#
# I-033 (T-024): both of these are now FAIL — neither carries the completion
# marker, and under the success contract that alone decides. What the boundary
# still governs is the second echelon's explanation, so the assertion moved
# there: at 300 bytes the word signature still fires (hint), at 301 it does
# not (nohint). Raising ERR_SHAPE_CHARS still turns the second case red.
f09_case boundary-chars-at fail-not-reviewed "word-signature output at exactly ERR_SHAPE_CHARS (300 bytes) -> still gated in (off-by-one, T-020 hygiene)" hint
f09_case boundary-chars-over fail-not-reviewed "word-signature output one byte past ERR_SHAPE_CHARS (301 bytes) -> gated out, not structural either (off-by-one, T-020 hygiene)" nohint

# ===========================================================================
group "I-033: the verdict is proof of review (marker), not absence of error signs"
# ===========================================================================
# The ten shapes the T-023 gate measured walking past the denylist — every one
# exits 0, none carries the marker, none contains a well-formed finding line.
# Not one detector below was written for their shapes: they fail because
# nothing proves a review happened. That is the whole point of the inversion.
f09_case t024-form-01 fail-not-reviewed "form 01: 'Error occurred while contacting provider:' then a traceback from line 2"
f09_case t024-form-02 fail-not-reviewed "form 02: CLI banner + blank line, then an HTML error page"
f09_case t024-form-03 fail-not-reviewed "form 03: 'provider response:' then a JSON error envelope"
f09_case t024-form-04 fail-not-reviewed "form 04: '---' then a traceback"
f09_case t024-form-05 fail-not-reviewed "form 05: 'Reviewing 3 files...' then an 18-line internal dump"
f09_case t024-form-06 fail-not-reviewed "form 06: ANSI-coloured traceback (escape bytes before the first visible char)"
f09_case t024-form-07 fail-not-reviewed "form 07: a line of spaces, then a traceback"
f09_case t024-form-08 fail-not-reviewed "form 08: blank lines only, then an HTML error page"
f09_case t024-form-09 fail-not-reviewed "form 09: indented '  {\"error\":' envelope"
f09_case t024-form-10 fail-not-reviewed "form 10: 'HTTP/1.1 502 Bad Gateway' as the first line"

# Honest reviews that signed off properly must stay OK — the whole risk of a
# whitelist is false refusals, so this half matters as much as the half above.
# (clean / success / clean-security-prose / clean-quotes-* in the F-09 group
# are honest fixtures too: they now emit the marker, so they cover the same
# contract from the regression side.)
f09_case clean-oneline ok "honest one-line clean review: nothing but the marker (length no longer means anything)"
f09_case findings-multi ok "honest review with three findings, marker count 3 matches the report"

# Broken sign-offs.
f09_case sentinel-count-mismatch fail-not-reviewed "marker claims 3 findings, 1 finding line present -> desync, not 'clean'"
f09_case truncated-marker fail-not-reviewed "output cut mid-marker ('CODEX-REVIEW-COMPL') with findings present -> FAIL, truncation beats the backup proof"
f09_case clean-no-marker fail-not-reviewed "model forgot the marker on a clean review -> loud FAIL by design (never a silent 'clean')"

# T-024 gate: the backup branch is attacked directly. A provider failure with a
# well-formed finding line inside it used to be accepted as a review — the
# justification was "no provider dump contains such a line", which was an
# argument from nobody having built one yet. The old shape detectors now hold a
# VETO over this one branch (they still decide nothing on their own), so both
# shapes fail AND explain themselves.
f09_case gate-html-with-finding fail-not-reviewed "502 HTML page with a '- [P1] ... — file:lines' inside -> vetoed, not accepted on structure" hint
f09_case gate-json-with-finding fail-not-reviewed "JSON error envelope with a '- [P2] ... — file:lines' after it -> vetoed, not accepted on structure" hint

# T-024 gate: truncation in the first characters of the token. The 8-character
# floor left 1..7 invisible, so these were accepted on the backup proof.
f09_case truncated-marker-1 fail-not-reviewed "output cut after 1 character of the marker ('C'), findings present -> truncation wins"
f09_case truncated-marker-7 fail-not-reviewed "output cut after 7 characters of the marker ('CODEX-R'), findings present -> truncation wins"

# T-024 gate: an obedient marker wearing markdown. The likeliest real-model
# deviation — the sign-off is present and correct, only wrapped.
f09_case marker-bold ok "marker in markdown bold ('**...: 1**') with one finding -> recognised as a sign-off"
f09_case marker-backticks ok "marker in backticks on a clean review -> recognised as a sign-off"
f09_case marker-underscores ok "marker in underscores on a clean review -> recognised as a sign-off"
f09_case marker-leading-zero ok "marker count written '01' with one finding -> leading zero is formatting, not a mismatch"

# T-024 gate, round 2: the rest of the markdown dressing. The first round gave
# the tolerance to emphasis only — and to `* MARKER` by accident, while
# `- MARKER` failed with a message blaming truncation. An obedient sign-off must
# not be refused for its wrapper, whichever wrapper the model picked.
f09_case marker-bold-label ok "marker with only the label in bold ('**...:** 0') -> emphasis in mid-line is still a sign-off"
f09_case marker-list-dash ok "marker as a '-' list item -> a sign-off, like the '*' bullet already was"
f09_case marker-quote ok "marker as a '>' blockquote -> a sign-off"
f09_case marker-heading ok "marker as a '##' heading -> a sign-off"
# The other half of the same asymmetry: the finding COUNTER must tolerate what
# the marker tolerates, or an obedient review is refused as a count desync.
f09_case finding-bold-severity ok "finding with bold severity ('- **[P1]** ...') + correct marker ': 1' -> counted, no false desync"
f09_case finding-indented ok "indented finding ('  - [P2] ...') + correct marker ': 1' -> counted, no false desync"
# Counter forms: formatting of the number is not a disagreement about it, but a
# number that cannot be read at all is.
f09_case marker-count-zeros ok "marker count written '000' on a clean review -> zero is zero"
f09_case marker-count-trailing-space ok "marker count with a trailing space -> still a sign-off"
f09_case marker-count-plus fail-not-reviewed "marker count '+1' -> unreadable count, FAIL (safe direction)"
f09_case marker-count-word fail-not-reviewed "marker count spelled 'one' -> unreadable count, FAIL (safe direction)"

# T-024 gate: a lowercase token is not the contract, but the message must not
# claim there is no marker at all.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
out="$( cd "$repo" && sut_run 10 "$MP_JQ" "FAKE_CODEX_MODE=marker-lowercase" -- --scope uncommitted 2>&1 )"; rc=$?
if printf '%s' "$out" | grep -qE '^FAIL:.*not reviewed' && printf '%s' "$out" | grep -qi 'wrong case'; then
  pass "lowercase marker -> FAIL whose message names the case, not 'no marker at all' (rc=$rc)"
else
  fail "lowercase marker -> unexpected (rc=$rc)" "stdout: $(printf '%s' "$out" | head -4 | tr '\n' '|')"
fi
rm -rf "$repo"

# Same discipline for a malformed count: the verdict was always right, the
# reason printed was not — an intact token with ': 1.0' was reported as output
# that "ends mid-marker".
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
out="$( cd "$repo" && sut_run 10 "$MP_JQ" "FAKE_CODEX_MODE=marker-count-malformed" -- --scope uncommitted 2>&1 )"; rc=$?
if printf '%s' "$out" | grep -qE '^FAIL:.*not reviewed' \
   && printf '%s' "$out" | grep -qi 'malformed' \
   && ! printf '%s' "$out" | grep -qi 'ends mid-marker'; then
  pass "marker ': 1.0' -> FAIL whose message blames the count, not a truncated tail (rc=$rc)"
else
  fail "marker ': 1.0' -> unexpected (rc=$rc)" "stdout: $(printf '%s' "$out" | head -4 | tr '\n' '|')"
fi
rm -rf "$repo"

# Backup proof: well-formed finding lines. Positive evidence of report
# structure, not a guess about what an error looks like.
i033_note_case() {
  local mode="$1" expect="$2" desc="$3"; shift 3
  local repo; repo="$(new_repo)"
  consent_file "$repo" '{"enabled": true}'
  echo "x=1" > "$repo/change.sh"
  local out rc
  out="$( cd "$repo" && sut_run 10 "$MP_JQ" "FAKE_CODEX_MODE=$mode" "$@" -- --scope uncommitted 2>&1 )"
  rc=$?
  local got=""
  if printf '%s' "$out" | grep -qE '^FAIL:.*not reviewed'; then got="fail-not-reviewed"
  elif printf '%s' "$out" | grep -qE '^OK:.*'; then got="ok"
  fi
  local ok=1 reason=""
  [ "$got" = "$expect" ] || { ok=0; reason="got '$got', expected '$expect'"; }
  printf '%s' "$out" | grep -q '^NOTE:' || { ok=0; reason="$reason; no loud NOTE line on stdout"; }
  if [ "$ok" = 1 ]; then
    pass "$desc -> $got + NOTE (rc=$rc)"
  else
    fail "$desc -> $reason (rc=$rc)" "stdout: $(printf '%s' "$out" | head -4 | tr '\n' '|')"
  fi
  rm -rf "$repo"
}
# T-029: the backup ACCEPTANCE is gone. Finding lines without the marker used
# to be `OK` + `NOTE`; they are now `FAIL: not reviewed`. Two assertions, not
# one — the verdict AND the recovery path, because a FAIL that does not name
# the valve just moves the hole from the contract to the operator's day.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
out="$( cd "$repo" && sut_run 10 "$MP_JQ" "FAKE_CODEX_MODE=findings-no-marker" -- --scope uncommitted 2>&1 )"; rc=$?
if printf '%s' "$out" | grep -qE '^FAIL:.*not reviewed' \
   && ! printf '%s' "$out" | grep -q '^OK:' \
   && printf '%s' "$out" | grep -q 'PF_CODEX_SENTINEL_OPTIONAL'; then
  pass "T-029: marker missing but two well-formed finding lines -> FAIL, and the message names PF_CODEX_SENTINEL_OPTIONAL as the way out (rc=$rc)"
else
  fail "T-029: findings without marker -> unexpected (rc=$rc)" "stdout: $(printf '%s' "$out" | head -6 | tr '\n' '|')"
fi
rm -rf "$repo"

# The other half of the same decision: work must not STOP if the model ever
# does go silent. Same fixture, valve open -> OK again.
i033_note_case findings-no-marker ok "T-029: PF_CODEX_SENTINEL_OPTIONAL=1 + findings without a marker -> OK again, the valve is the documented way through" "PF_CODEX_SENTINEL_OPTIONAL=1"

# Emergency relief valve: the marker stops being the verdict, the second
# echelon decides again — loudly, and at the stated price.
i033_note_case clean-no-marker ok "PF_CODEX_SENTINEL_OPTIONAL=1: clean review without a marker -> OK again, with a loud NOTE" "PF_CODEX_SENTINEL_OPTIONAL=1"
# Two rows, because the valve's veto has two sides and the old single row named
# itself after both while covering one. `error-rc0` carries NO finding line
# (TOTAL=0); the html/json pair carries one (TOTAL>0) — and it was TOTAL>0 that
# used to walk into OK before the veto was ever consulted.
i033_note_case error-rc0 fail-not-reviewed "PF_CODEX_SENTINEL_OPTIONAL=1, no findings: a known failure shape is still vetoed by the second echelon" "PF_CODEX_SENTINEL_OPTIONAL=1"
i033_note_case gate-html-with-finding fail-not-reviewed "PF_CODEX_SENTINEL_OPTIONAL=1, WITH a finding line: the 502 shape is still vetoed (the valve waives the marker, not the veto)" "PF_CODEX_SENTINEL_OPTIONAL=1"
i033_note_case gate-json-with-finding fail-not-reviewed "PF_CODEX_SENTINEL_OPTIONAL=1, WITH a finding line: the JSON error envelope is still vetoed" "PF_CODEX_SENTINEL_OPTIONAL=1"
# The valve's documented PRICE, kept honest from the other direction: these two
# carry positive evidence of truncation and no known failure shape, so the valve
# does swallow them. If that ever changes, the doc's price paragraph is wrong.
i033_note_case sentinel-count-mismatch ok "PF_CODEX_SENTINEL_OPTIONAL=1: a count desync is swallowed -> OK + NOTE (the documented price)" "PF_CODEX_SENTINEL_OPTIONAL=1"
# Case-insensitive, like the consent branch: a valve that ignores `TRUE` is a
# valve someone will believe they opened.
i033_note_case clean-no-marker ok "PF_CODEX_SENTINEL_OPTIONAL=TRUE: uppercase value opens the valve too" "PF_CODEX_SENTINEL_OPTIONAL=TRUE"
i033_note_case clean-no-marker ok "PF_CODEX_SENTINEL_OPTIONAL=Yes: mixed-case value opens the valve too" "PF_CODEX_SENTINEL_OPTIONAL=Yes"
i033_note_case truncated-marker ok "PF_CODEX_SENTINEL_OPTIONAL=1: a mid-token cut is swallowed -> OK + NOTE (the documented price)" "PF_CODEX_SENTINEL_OPTIONAL=1"

# ===========================================================================
group "I-033 negative control: strip the marker requirement from the prompt -> honest fixtures must go red"
# ===========================================================================
# Proves the verdict genuinely rests on the marker rather than on something
# incidental. The SUT is copied, the MANDATORY paragraph is cut out of the
# prompt (the checker stays untouched), and the prompt-aware double then stops
# signing off — exactly as a model that was never asked would.
NEGCTL="$WORKROOT/codex-review-no-sentinel.sh"
sed -e "/^MANDATORY, no exceptions:/,/^discarded as 'not reviewed', however good the review itself was\.\"$/d" \
    -e 's/^report anything you cannot anchor that way\.$/&"/' \
    "$SUT" > "$NEGCTL"
# Guard: a reworded prompt must break this group loudly instead of silently
# turning it into a no-op that "passes" while cutting nothing.
if cmp -s "$SUT" "$NEGCTL"; then
  echo "harness setup: the negative control cut nothing out of $SUT — the prompt wording changed, update the sed above" >&2
  exit 90
fi
if ! "$BASH_BIN" -n "$NEGCTL" 2>/dev/null; then
  echo "harness setup: the negative control copy is not valid bash — update the sed above" >&2
  exit 90
fi
# ...and the requirement really is gone from the PROMPT (the verdict code
# below it must still mention the marker, or we cut too much).
if grep -q 'MANDATORY, no exceptions' "$NEGCTL" || ! grep -q 'SENTINEL_LINE' "$NEGCTL"; then
  echo "harness setup: the negative control cut the wrong lines — update the sed above" >&2
  exit 90
fi

SUT_REAL="$SUT"
SUT="$NEGCTL"
# Clean reviews lose their only proof -> red, every one of them.
f09_case clean fail-not-reviewed "negative control: honest clean review, requirement removed -> red"
f09_case clean-oneline fail-not-reviewed "negative control: one-line clean review, requirement removed -> red"
f09_case clean-security-prose fail-not-reviewed "negative control: long clean auth/rate-limit prose, requirement removed -> red"
f09_case clean-quotes-traceback fail-not-reviewed "negative control: clean review quoting a traceback, requirement removed -> red"
# A review WITH findings used to stay green here (the backup acceptance on
# report structure). T-029 removed that acceptance, so this row flipped: with
# the requirement cut out of the prompt, findings no longer rescue anything.
# The boundary is still documented, it just moved to the safe side.
f09_case success fail-not-reviewed "negative control: review WITH findings, requirement removed -> red too (no backup acceptance left)"
SUT="$SUT_REAL"

# ===========================================================================
group "F-10: only a hex commit SHA reaches the diff command / prompt, never the raw ref"
# ===========================================================================
f10_case() {
  local scope_flag="$1" ref="$2" mode="$3" desc="$4"
  local repo; repo="$(new_repo)"
  ( cd "$repo" && PATH="$FULL_PATH" git branch -- "$ref" >/dev/null 2>&1 )
  # `git branch` alone points $ref at the CURRENT commit — a diff against
  # that commit would be empty and Gate 4 ("no code files") would skip
  # before codex is ever invoked, which is not what this group tests. Move
  # HEAD forward with a second, code-bearing commit so --base has a real
  # diff; --commit already has one via seed.sh (a code file, not seed.txt).
  ( cd "$repo" && echo "y=2" >> seed.sh \
      && PATH="$FULL_PATH" git add seed.sh \
      && PATH="$FULL_PATH" git commit -qm second >/dev/null 2>&1 )
  consent_file "$repo" '{"enabled": true}'
  local argvlog; argvlog="$(mktemp "${TMPDIR:-/tmp}/codex-review-test-argvlog.XXXXXXXX")"
  local extra_args=()
  [ "$mode" = why ] && extra_args+=(--why "test focus")
  local out rc
  out="$( cd "$repo" && sut_run 10 "$MP_JQ" "FAKE_CODEX_ARGV_LOG=$argvlog" "FAKE_CODEX_MODE=clean" -- "$scope_flag" "$ref" "${extra_args[@]+"${extra_args[@]}"}" 2>&1 )"
  rc=$?
  local argv=""; [ -f "$argvlog" ] && argv="$(cat "$argvlog")"
  local ok=1 reason=""
  if printf '%s' "$argv" | grep -qF "$ref"; then ok=0; reason="raw ref text leaked into argv"; fi
  if ! printf '%s' "$argv" | grep -qE '[0-9a-f]{40}'; then ok=0; reason="$reason no 40-hex sha found in argv"; fi
  if [ "$ok" = 1 ]; then
    pass "$desc -> hex-only (rc=$rc)"
  else
    fail "$desc -> $reason (rc=$rc)" "argv: $(printf '%s' "$argv" | tr '\n' '|')"
  fi
  rm -f "$argvlog"; rm -rf "$repo"
}

for ref in 'evil;semi' 'evil$(sub)' 'evil`tick`'; do
  f10_case --base "$ref" why "focused mode, --base with ref [$ref]"
  f10_case --base "$ref" plain "default mode (no --why), --base with ref [$ref]"
  f10_case --commit "$ref" why "focused mode, --commit with ref [$ref]"
  f10_case --commit "$ref" plain "default mode (no --why), --commit with ref [$ref]"
done

# regression guard: an unknown ref must still cleanly skip, not crash.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
out="$( cd "$repo" && sut_run 5 "$MP_JQ" -- --base "totally-unknown-ref-xyz" 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^SKIP:'; then
  pass "unknown --base ref -> SKIP, exit 0 (regression guard)"
else
  fail "unknown --base ref -> unexpected (rc=$rc)" "stdout: $out"
fi
rm -rf "$repo"

# ===========================================================================
group "F-11: after a timeout, the whole process group is dead even without pkill on PATH"
# ===========================================================================
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
gcfile="$WORKROOT/f11-grandchild.pid"
rm -f "$gcfile"
out="$( cd "$repo" && sut_run 30 "$MP_JQ" \
        "FAKE_CODEX_MODE=grandchild-survives-term" \
        "FAKE_CODEX_GRANDCHILD_PID_FILE=$gcfile" \
        "PF_CODEX_TIMEOUT=2" "PF_CODEX_GRACE=2" \
        -- --scope uncommitted 2>&1 )"
rc=$?
gc_pid=""
[ -s "$gcfile" ] && gc_pid="$(cat "$gcfile")"
if [ -n "$gc_pid" ]; then track_leak_pid "$gc_pid"; fi
# pid_is_alive (lib.sh), not a plain `kill -0`: a killed descendant is a
# zombie until *something* reaps it, and `kill -0` alone reads a zombie as
# "alive". On a bare PID 1 that never calls wait() (docker run without
# --init) that zombie can persist for the container's whole life, turning
# this case falsely red even though the watchdog's SIGKILL genuinely ended
# it — confirmed empirically both ways (see pid_is_alive's comment).
if [ -n "$gc_pid" ] && ! pid_is_alive "$gc_pid"; then
  pass "SIGTERM-resistant descendant is dead after timeout, no pkill on PATH (rc=$rc)"
else
  fail "descendant still alive after timeout with no pkill on PATH (pid=$gc_pid, rc=$rc)" "stdout: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
fi
rm -rf "$repo"

# ===========================================================================
group "F-19: a path containing a literal newline is refused, never phantom-split"
# ===========================================================================
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
( cd "$repo" && printf 'code' > $'weird\nname.sh' && PATH="$FULL_PATH" git add -- $'weird\nname.sh' )
calllog="$(mktemp "${TMPDIR:-/tmp}/codex-review-test-calllog.XXXXXXXX")"
out="$( cd "$repo" && sut_run 10 "$MP_JQ" "FAKE_CODEX_CALL_LOG=$calllog" "FAKE_CODEX_MODE=clean" -- --scope uncommitted 2>&1 )"
rc=$?
calls=0
[ -s "$calllog" ] && calls="$(grep -c . "$calllog" 2>/dev/null || true)"
if [ "$calls" = 0 ] && [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^SKIP:'; then
  pass "newline-in-filename -> honest SKIP, no phantom split, no codex call (rc=$rc)"
else
  fail "newline-in-filename -> not safely refused (calls=$calls, rc=$rc)" "stdout: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
fi
rm -f "$calllog"; rm -rf "$repo"

# regression guard: an ordinary file with spaces + Cyrillic still works.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
( cd "$repo" && printf 'code' > "мой файл.sh" && PATH="$FULL_PATH" git add -- "мой файл.sh" )
calllog="$(mktemp "${TMPDIR:-/tmp}/codex-review-test-calllog.XXXXXXXX")"
out="$( cd "$repo" && sut_run 10 "$MP_JQ" "FAKE_CODEX_CALL_LOG=$calllog" "FAKE_CODEX_MODE=clean" -- --scope uncommitted 2>&1 )"
rc=$?
calls=0
[ -s "$calllog" ] && calls="$(grep -c . "$calllog" 2>/dev/null || true)"
if [ "$calls" = 1 ]; then
  pass "space + Cyrillic filename -> still reviewed normally (regression guard, rc=$rc)"
else
  fail "space + Cyrillic filename -> regressed (calls=$calls, rc=$rc)" "stdout: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
fi
rm -f "$calllog"; rm -rf "$repo"

# ===========================================================================
group "I-035: agent-ceiling clamp (600s Bash-tool cap) + honest artifacts on killed runs"
# ===========================================================================
# Root cause (2026-08-28, one of the author's projects): default budgets (max=1800s,
# xhigh=1200s) exceed the 600s hard ceiling of every agent's Bash tool, so
# the harness killed the script before its own watchdog ever fired — leaving
# a 0-byte report, no FAIL line, and an orphaned codex. Three properties are
# pinned here: (1) the default budget fits under the ceiling, (2) an internal
# watchdog FAIL overwrites the report so it self-explains, (3) an EXTERNAL
# kill leaves a self-explaining PENDING placeholder, never zero bytes.

# (1a) default effort (max) is clamped to 540s
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
out="$( cd "$repo" && sut_run 10 "$MP_JQ" "PF_CODEX_PRINT_BUDGET=1" -- --scope uncommitted 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'effort=max timeout=540s'; then
  pass "default budget (max) clamped to 540s — fits under the 600s agent ceiling"
else
  fail "default budget not clamped (rc=$rc)" "stdout: $out"
fi

# (1b) PF_CODEX_TIMEOUT stays an absolute, unclamped override
out="$( cd "$repo" && sut_run 10 "$MP_JQ" "PF_CODEX_PRINT_BUDGET=1" "PF_CODEX_TIMEOUT=1800" -- --scope uncommitted 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'timeout=1800s'; then
  pass "PF_CODEX_TIMEOUT=1800 overrides the clamp (human terminal, no ceiling)"
else
  fail "PF_CODEX_TIMEOUT no longer overrides the clamp (rc=$rc)" "stdout: $out"
fi

# (1c) budgets already under the ceiling are untouched
out="$( cd "$repo" && sut_run 10 "$MP_JQ" "PF_CODEX_PRINT_BUDGET=1" -- --scope uncommitted --effort low 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'effort=low timeout=150s'; then
  pass "effort low keeps its own 150s budget (clamp only lowers, never raises)"
else
  fail "sub-ceiling budget altered (rc=$rc)" "stdout: $out"
fi
rm -rf "$repo"

# (2) internal watchdog FAIL: report overwritten with a FAILED summary + hint
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
outfile="$WORKROOT/i035-internal-fail.md"
out="$( cd "$repo" && sut_run 30 "$MP_JQ" "FAKE_CODEX_MODE=hang" \
        "PF_CODEX_TIMEOUT=2" "PF_CODEX_GRACE=1" \
        -- --scope uncommitted --out "$outfile" 2>&1 )"; rc=$?
if [ "$rc" = 1 ] \
   && printf '%s' "$out" | grep -q '^FAIL: TIMEOUT — Codex review did not produce output' \
   && printf '%s' "$out" | grep -q "own watchdog" \
   && head -1 "$outfile" 2>/dev/null | grep -q '^# Codex review FAILED' \
   && ! grep -q 'PENDING' "$outfile"; then
  pass "internal timeout -> FAIL + watchdog hint, report self-explains (not 0 bytes, not PENDING)"
else
  fail "internal timeout artifacts wrong (rc=$rc)" "stdout: $(printf '%s' "$out" | head -4 | tr '\n' '|') report: $(head -2 "$outfile" 2>/dev/null | tr '\n' '|')"
fi
rm -f "$outfile"; rm -rf "$repo"

# (2b) T-127: the reason a run gave nothing is named on the verdict line —
# quota (with the date the CLI quotes) and login — still `FAIL:`, never a verdict.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
outfile="$WORKROOT/t127-quota.md"
out="$( cd "$repo" && sut_run 30 "$MP_JQ" "FAKE_CODEX_MODE=quota" -- --scope uncommitted --out "$outfile" 2>&1 )"; rc=$?
if [ "$rc" = 1 ] \
   && printf '%s' "$out" | grep -q '^FAIL: QUOTA (until 2026-09-20) — Codex review did not produce output' \
   && printf '%s' "$out" | grep -q '^STDERR (last lines):' \
   && grep -q '^- state: QUOTA (until 2026-09-20)' "$outfile"; then
  pass "T-127: stderr 'usage limit ... 2026-09-20' + exit 1 -> FAIL: QUOTA (until 2026-09-20), stderr tail kept, report names the state"
else
  fail "T-127 quota classification wrong (rc=$rc)" "stdout: $(printf '%s' "$out" | head -3 | tr '\n' '|') report: $(head -6 "$outfile" 2>/dev/null | tr '\n' '|')"
fi
rm -f "$outfile"   # F-05: --out never overwrites
out="$( cd "$repo" && sut_run 30 "$MP_JQ" "FAKE_CODEX_MODE=login" -- --scope uncommitted --out "$outfile" 2>&1 )"; rc=$?
if [ "$rc" = 1 ] \
   && printf '%s' "$out" | grep -q '^FAIL: LOGIN — Codex review did not produce output'; then
  pass "T-127: stderr 'not logged in' + exit 1 -> FAIL: LOGIN — ..."
else
  fail "T-127 login classification wrong (rc=$rc)" "stdout: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
fi
rm -f "$outfile"   # F-05: --out never overwrites
out="$( cd "$repo" && sut_run 30 "$MP_JQ" "FAKE_CODEX_MODE=crash" -- --scope uncommitted --out "$outfile" 2>&1 )"; rc=$?
if [ "$rc" = 1 ] \
   && printf '%s' "$out" | grep -q '^FAIL: Codex review did not produce output'; then
  pass "T-127: an unrecognised stderr ('boom') keeps the plain FAIL line — no class invented"
else
  fail "T-127 unrecognised failure got a class (rc=$rc)" "stdout: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
fi
rm -f "$outfile"; rm -rf "$repo"

# (3) external kill (what an agent harness does at its ceiling): the reserved
# report must already be a self-explaining placeholder, never zero bytes.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
outfile="$WORKROOT/i035-external-kill.md"
marker="i035-extkill-$$"
( cd "$repo" && env FAKE_CODEX_MODE=hang PF_CODEX_TIMEOUT=8 PF_CODEX_GRACE=1 \
    PATH="$MP_JQ" "$BASH_BIN" "$SUT" --scope uncommitted --out "$outfile" --why "$marker" ) &
sut_pid=$!
# wait until the run is genuinely in flight: placeholder reserved AND codex
# spawned (its argv carries $marker via --why), then kill the SUT dead — the
# way a harness ceiling does, no TERM courtesy.
waited=0
while [ "$waited" -lt 50 ]; do
  [ -s "$outfile" ] && PATH="$FULL_PATH" pgrep -f "$marker" >/dev/null 2>&1 && break
  sleep 0.2; waited=$(( waited + 1 ))
done
kill -KILL "$sut_pid" 2>/dev/null
{ wait "$sut_pid"; } 2>/dev/null
if [ -s "$outfile" ] && grep -q 'PENDING' "$outfile" && grep -q 'killed from the OUTSIDE' "$outfile"; then
  pass "external SIGKILL -> report is a self-explaining PENDING placeholder, not 0 bytes"
else
  fail "external kill left a lying artifact" "report($( wc -c < "$outfile" 2>/dev/null | tr -d ' ' ) bytes): $(head -3 "$outfile" 2>/dev/null | tr '\n' '|')"
fi
# cleanup: the orphaned fake codex sits in its own process group (set -m in
# the SUT); the SUT's watchdog may already have reaped it (PF_CODEX_TIMEOUT=8),
# kill the group ourselves to be sure.
codex_pid="$(PATH="$FULL_PATH" pgrep -f "$marker" 2>/dev/null | head -1)"
if [ -n "$codex_pid" ]; then
  kill -KILL "-$codex_pid" 2>/dev/null || kill -KILL "$codex_pid" 2>/dev/null
  track_leak_pid "$codex_pid"
fi
sleep 9   # let the orphaned watchdog (child of the killed SUT) run out and exit
rm -f "$outfile"; rm -rf "$repo"

# ===========================================================================
group "T-070: --async detaches, --wait reads the marker, chunks fold into one verdict"
# ===========================================================================
# Root cause (retro 2026-09-03): the pre-pass went quiet for most of the
# period. The I-035 clamp above keeps a synchronous run under the agent's 600s
# Bash-tool ceiling, but a large diff simply does not fit in 540s, so the gate
# collected FAIL after FAIL and walked on. --async moves the run out from under
# that ceiling. Pinned here: (1) the flags are discoverable, (2) PENDING is
# immediate and only ever promised when codex will really run, (3) the verdict
# reaches the marker and --wait reproduces it byte-for-byte with the same exit
# code, (4) a timeout is a loud FAIL, never a quiet success, (5) the detached
# child outlives its launcher, (6) the clamp is lifted ONLY off the async path,
# (7) a large diff is split and one bad group poisons the whole verdict.

# (1) discoverability: --help must name both flags (they are useless unknown)
out="$( sut_run 5 "$MP_JQ" -- --help 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q -- '--async' && printf '%s' "$out" | grep -q -- '--wait'; then
  pass "--help lists --async and --wait"
else
  fail "--help does not document the async flags (rc=$rc)" "stdout: $out"
fi

# (2) mode conflicts are named, never silently ignored
out="$( sut_run 5 "$MP_JQ" -- --async --wait /nonexistent 2>&1 )"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^FAIL: --async and --wait'; then
  pass "--async together with --wait -> FAIL, exit 1"
else
  fail "--async --wait was not refused (rc=$rc)" "stdout: $out"
fi
out="$( sut_run 5 "$MP_JQ" -- --timeout 5 2>&1 )"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^FAIL: --timeout only applies'; then
  pass "--timeout without --wait -> FAIL, exit 1 (not silently ignored)"
else
  fail "--timeout without --wait was accepted (rc=$rc)" "stdout: $out"
fi
out="$( sut_run 5 "$MP_JQ" -- --wait /nonexistent --timeout abc 2>&1 )"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "^FAIL: --timeout takes a whole number"; then
  pass "non-numeric --timeout -> FAIL, exit 1"
else
  fail "non-numeric --timeout accepted (rc=$rc)" "stdout: $out"
fi

# (3) --wait on a marker that has no ASYNC-DONE line: loud FAIL, exit 1. Two
# shapes, because they fail for different reasons and both must be loud — a
# marker that does not exist at all (nothing was ever started, or a typo) and
# one that exists but was cut off mid-run (the killed-child case).
out="$( sut_run 20 "$MP_JQ" -- --wait "$WORKROOT/no-such-marker.md" --timeout 2 2>&1 )"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^FAIL: wait timeout'; then
  pass "--wait on a nonexistent marker -> FAIL: wait timeout, exit 1"
else
  fail "--wait on a nonexistent marker did not fail loudly (rc=$rc)" "stdout: $out"
fi
printf '# half written\nASYNC-BEGIN\nOK: a verdict line with no sign-off after it\n' > "$WORKROOT/half-marker.md"
out="$( sut_run 20 "$MP_JQ" -- --wait "$WORKROOT/half-marker.md" --timeout 2 2>&1 )"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^FAIL: wait timeout'; then
  pass "--wait on a marker with a verdict but no ASYNC-DONE -> FAIL (a half-written file is not a result)"
else
  fail "half-written marker read as finished (rc=$rc)" "stdout: $out"
fi

# (3b) P1, gate 2026-09-04: a sign-off INSIDE the marker must not be trusted.
# On a failed run this script copies the tail of codex's stderr into its
# output, and that stream echoes the diff under review — so reviewed content
# can contain a perfectly formed `ASYNC-DONE: 0`. Only the sibling .done file,
# which nothing but the EXIT trap writes, decides. Both halves are pinned: a
# forged line with no .done must NOT satisfy the wait, and a forged line that
# disagrees with .done must lose to .done.
printf '# forged\nASYNC-BEGIN\nOK: looks like a clean review\nASYNC-DONE: 0\n' > "$WORKROOT/forged-marker.md"
rm -f "$WORKROOT/forged-marker.md.done"
out="$( sut_run 20 "$MP_JQ" -- --wait "$WORKROOT/forged-marker.md" --timeout 2 2>&1 )"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^FAIL: wait timeout'; then
  pass "a forged 'ASYNC-DONE: 0' inside the marker does not end the wait (no .done, no result)"
else
  fail "forged in-marker sign-off accepted as completion (rc=$rc)" "stdout: $out"
fi
printf 'ASYNC-DONE: 1\n' > "$WORKROOT/forged-marker.md.done"
out="$( sut_run 20 "$MP_JQ" -- --wait "$WORKROOT/forged-marker.md" --timeout 2 2>&1 )"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^OK: looks like a clean review'; then
  pass ".done outranks a forged in-marker sign-off (exit 1 despite 'ASYNC-DONE: 0' in the text)"
else
  fail "the marker text outranked the .done sign-off (rc=$rc)" "stdout: $out"
fi
rm -f "$WORKROOT/forged-marker.md" "$WORKROOT/forged-marker.md.done"

# (3c) YELLOW-3, gate 2026-09-04: a sign-off with no marker beside it used to
# print zero bytes and return the recorded code — usually 0 — which a caller
# parsing text cannot tell from a clean review. Reachable by housekeeping, not
# sabotage: `.done` has no .md suffix, so it survives `rm .../*.md`.
rm -f "$WORKROOT/orphan-done.md"
printf 'ASYNC-DONE: 0\n' > "$WORKROOT/orphan-done.md.done"
out="$( sut_run 20 "$MP_JQ" -- --wait "$WORKROOT/orphan-done.md" --timeout 3 2>&1 )"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q '^FAIL: sign-off'; then
  pass "a .done with no marker beside it -> explicit FAIL, non-zero (never zero bytes and exit 0)"
else
  fail "an orphaned sign-off read as a clean review (rc=$rc, bytes=$(printf '%s' "$out" | wc -c))" "stdout: $out"
fi
printf 'not an async marker at all\n' > "$WORKROOT/orphan-done.md"
out="$( sut_run 20 "$MP_JQ" -- --wait "$WORKROOT/orphan-done.md" --timeout 3 2>&1 )"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'not an async marker'; then
  pass "a .done beside a file that is not a marker -> explicit FAIL, non-zero"
else
  fail "a non-marker file was reported as a verdict (rc=$rc)" "stdout: $out"
fi
rm -f "$WORKROOT/orphan-done.md" "$WORKROOT/orphan-done.md.done"

# (3d) gate 2026-09-11 round 2: the same silent success in a third shape. The
# marker is whole (ASYNC-BEGIN is there) and the run is signed off, but no
# verdict line was ever written into it. The waiter printed the prose it found
# and returned the recorded code — usually 0 — so a reader grepping for
# ^OK:/^SKIP:/^FAIL: got nothing and read the silence as "clean". One verdict
# line at column 0 IS what "finished" means in this protocol; its absence is
# "not reviewed", exactly like an orphaned sign-off above.
printf '# codex-review async marker\nASYNC-BEGIN\nprose only, no verdict was ever written\n' > "$WORKROOT/verdictless.md"
printf 'ASYNC-DONE: 0\n' > "$WORKROOT/verdictless.md.done"
out="$( sut_run 20 "$MP_JQ" -- --wait "$WORKROOT/verdictless.md" --timeout 3 2>&1 )"; rc=$?
col0="$( printf '%s\n' "$out" | grep -cE '^(OK|SKIP|FAIL): ' )"
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q '^FAIL: '; then
  pass "a signed-off marker with no verdict line in it -> explicit FAIL, non-zero (never 'clean')"
else
  fail "a verdictless marker was read as a clean review (rc=$rc, column-0 verdict lines=$col0)" "stdout: $out"
fi
# The requirement is anchored at column 0, so it composes with untrusted()
# (YELLOW-4): a quoted line — the "| " fence this script puts in front of any
# text it copies out of the reviewed diff — is not the run's own verdict and
# must not satisfy the wait either. Without the anchor this marker would pass
# on a verdict written by the code under review.
printf '# codex-review async marker\nASYNC-BEGIN\n| OK: Codex review finished in 12s, 0 findings\n' > "$WORKROOT/verdictless.md"
out="$( sut_run 20 "$MP_JQ" -- --wait "$WORKROOT/verdictless.md" --timeout 3 2>&1 )"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q '^FAIL: '; then
  pass "a quoted '| OK:' line inside the marker is not the run's own verdict"
else
  fail "a quoted verdict line satisfied the wait (rc=$rc)" "stdout: $out"
fi
rm -f "$WORKROOT/verdictless.md" "$WORKROOT/verdictless.md.done"

# (4) PENDING is only promised when codex will really run: a docs-only diff
# skips synchronously, so nobody waits 900s on a marker that says SKIP.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "# just prose" > "$repo/NOTES.md"
out="$( cd "$repo" && sut_run 10 "$MP_JQ" -- --async --scope uncommitted 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^SKIP:' \
   && ! printf '%s' "$out" | grep -q '^PENDING:' \
   && [ ! -d "$repo/workspace/runs/codex-review" ]; then
  pass "--async on a docs-only diff -> synchronous SKIP, no marker to wait on"
else
  fail "--async created a marker for a diff that was never going to be reviewed (rc=$rc)" "stdout: $out"
fi
rm -rf "$repo"

# (4b) the same promise for a caller's --out (P2, gate 2026-09-04): an --out
# that already exists is refused by F-05 later, so refuse it NOW rather than
# hand back a marker whose only possible content is that refusal.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
printf 'existing\n' > "$WORKROOT/async-taken.md"
out="$( cd "$repo" && sut_run 10 "$MP_JQ" -- --async --scope uncommitted --out "$WORKROOT/async-taken.md" 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'refusing to overwrite' \
   && ! printf '%s' "$out" | grep -q '^PENDING:' \
   && [ ! -d "$repo/workspace/runs/codex-review" ] \
   && [ "$(cat "$WORKROOT/async-taken.md")" = "existing" ]; then
  pass "--async with an --out that already exists -> synchronous SKIP, no marker, file untouched"
else
  fail "--async promised PENDING for a run that could only refuse (rc=$rc)" "stdout: $out"
fi
rm -f "$WORKROOT/async-taken.md"; rm -rf "$repo"

# (5) the happy path, end to end: PENDING now, verdict later, --wait returns
# exactly what a synchronous run prints and exactly the code it would exit with.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
t0="$(date +%s)"
out="$( cd "$repo" && sut_run 10 "$MP_JQ" "FAKE_CODEX_MODE=success" -- --async --scope uncommitted 2>&1 )"; rc=$?
t1="$(date +%s)"
marker="$( printf '%s\n' "$out" | grep '^PENDING: ' | sed 's/^PENDING: //' )"
if [ "$rc" = 0 ] && [ -n "$marker" ] && [ -f "$marker" ] && [ "$(( t1 - t0 ))" -lt 5 ]; then
  pass "--async returns PENDING with an existing marker in under 5s ($(( t1 - t0 ))s)"
else
  fail "--async did not return a marker promptly (rc=$rc, $(( t1 - t0 ))s)" "stdout: $out"
fi
waited="$( sut_run 40 "$MP_JQ" -- --wait "$marker" --timeout 25 2>&1 )"; wrc=$?
sync_out="$( cd "$repo" && sut_run 15 "$MP_JQ" "FAKE_CODEX_MODE=success" -- --scope uncommitted 2>&1 )"; src=$?
# Normalise the two things that legitimately differ between any two runs: the
# report's timestamped filename and the elapsed seconds.
norm_verdict() { sed -E 's#[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}#<STAMP>#g; s#in [0-9]+s#in <N>s#g'; }
if [ "$wrc" = 0 ] && [ "$src" = 0 ] \
   && [ "$( printf '%s\n' "$waited" | norm_verdict )" = "$( printf '%s\n' "$sync_out" | norm_verdict )" ]; then
  pass "--wait prints the same digest and the same exit code as the synchronous run"
else
  fail "async verdict differs from the synchronous one (wait rc=$wrc, sync rc=$src)" "wait: $waited || sync: $sync_out"
fi
if grep -q '^ASYNC-DONE: 0$' "$marker" && [ "$(grep -cE '^(OK|SKIP|FAIL): ' "$marker")" = 1 ]; then
  pass "marker carries ASYNC-DONE: 0 and exactly one column-0 verdict line"
else
  fail "marker sign-off or verdict shape is wrong" "$(cat "$marker")"
fi
rm -rf "$repo"

# (6) a failing review propagates through the marker: ASYNC-DONE: 1 and --wait
# exits 1. "Not reviewed" must survive the trip through a file.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
out="$( cd "$repo" && sut_run 10 "$MP_JQ" "FAKE_CODEX_MODE=empty" -- --async --scope uncommitted 2>&1 )"
marker="$( printf '%s\n' "$out" | grep '^PENDING: ' | sed 's/^PENDING: //' )"
waited="$( sut_run 40 "$MP_JQ" -- --wait "$marker" --timeout 25 2>&1 )"; wrc=$?
if [ "$wrc" = 1 ] && printf '%s' "$waited" | grep -q '^FAIL:' && grep -q '^ASYNC-DONE: 1$' "$marker"; then
  pass "a failed review reaches the marker as ASYNC-DONE: 1 and --wait exits 1"
else
  fail "failure did not survive the marker round-trip (rc=$wrc)" "wait: $waited"
fi
rm -rf "$repo"

# (7) the child is genuinely detached: its launcher returned seconds ago, yet
# the run continues and writes its own watchdog verdict afterwards. This is the
# whole premise of --async; without it the feature is decoration.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
t0="$(date +%s)"
out="$( cd "$repo" && sut_run 10 "$MP_JQ" "FAKE_CODEX_MODE=hang" "PF_CODEX_TIMEOUT=6" "PF_CODEX_GRACE=1" -- --async --scope uncommitted 2>&1 )"
t1="$(date +%s)"
marker="$( printf '%s\n' "$out" | grep '^PENDING: ' | sed 's/^PENDING: //' )"
waited="$( sut_run 60 "$MP_JQ" -- --wait "$marker" --timeout 40 2>&1 )"; wrc=$?
t2="$(date +%s)"
if [ "$(( t1 - t0 ))" -lt 5 ] && [ "$wrc" = 1 ] \
   && printf '%s' "$waited" | grep -q "^FAIL: TIMEOUT — Codex review did not produce output" \
   && [ "$(( t2 - t0 ))" -ge 6 ]; then
  pass "detached child outlives its launcher ($(( t1 - t0 ))s to PENDING, verdict at $(( t2 - t0 ))s)"
else
  fail "the background run did not survive its launcher (rc=$wrc, pending $(( t1 - t0 ))s, verdict $(( t2 - t0 ))s)" "wait: $waited"
fi
rm -rf "$repo"

# (8) the clamp is lifted for the async path and ONLY there. The 540s ceiling
# belongs to the caller's Bash tool; a detached run has no such caller. The
# synchronous half of this pair is pinned in the I-035 group above.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
out="$( cd "$repo" && sut_run 10 "$MP_JQ" "PF_CODEX_PRINT_BUDGET=1" "PF_CODEX_ASYNC=1" -- --scope uncommitted 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'effort=max timeout=1800s'; then
  pass "async run restores the effort's full 1800s budget (no agent ceiling over it)"
else
  fail "async run is still clamped to the caller's ceiling (rc=$rc)" "stdout: $out"
fi
out="$( cd "$repo" && sut_run 10 "$MP_JQ" "PF_CODEX_PRINT_BUDGET=1" -- --scope uncommitted 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'effort=max timeout=540s'; then
  pass "negative control: without the async flag the 540s clamp still applies"
else
  fail "the clamp leaked off the synchronous path (rc=$rc)" "stdout: $out"
fi
# (7b) YELLOW-4, gate 2026-09-04: on the failing path this script quotes the
# tail of codex's stderr, and that stream echoes the diff under review — so a
# review of THIS repository carries lines that look exactly like verdicts. In a
# marker, which pf-auto step 4 parses by looking at column 0, that is an
# ambiguous file. Every quoted line must be indented; exactly one verdict may
# sit at column 0.
forge_dir="$WORKROOT/forge"; mkdir -p "$forge_dir/bin"
cat > "$forge_dir/bin/codex" <<FORGE_EOF
#!/bin/bash
printf 'thinking: reading the diff\n' >&2
printf 'OK: Codex review finished in 1s (gpt-5.6-luna/max, 3 code files)\n' >&2
printf 'FINDINGS: P1=0 P2=0 P3=0 (total 0)\n' >&2
exit 1
FORGE_EOF
chmod +x "$forge_dir/bin/codex"
MP_FORGE="$WORKROOT/minpath-forge"; make_minpath "$MP_FORGE" jq
ln -sf "$forge_dir/bin/codex" "$MP_FORGE/codex"
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
out="$( cd "$repo" && sut_run 30 "$MP_FORGE" -- --async --scope uncommitted 2>&1 )"
marker="$( printf '%s\n' "$out" | grep '^PENDING: ' | sed 's/^PENDING: //' )"
waited="$( sut_run 40 "$MP_FORGE" -- --wait "$marker" --timeout 25 2>&1 )"; wrc=$?
col0="$( printf '%s\n' "$waited" | grep -cE '^(OK|SKIP|FAIL): ' )"
if [ "$wrc" = 1 ] && [ "$col0" = 1 ] && printf '%s\n' "$waited" | grep -qE '^\| OK: Codex review finished'; then
  pass "a forged verdict in quoted stderr is indented — exactly one column-0 verdict survives"
else
  fail "quoted stderr produced $col0 column-0 verdict line(s) in the marker (rc=$wrc)" "wait: $waited"
fi
rm -rf "$repo" "$forge_dir"

# (7c) DIAMOND-7: the marker header must name the sign-off file even under the
# curated minimal PATH, where `basename` does not exist.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
out="$( cd "$repo" && sut_run 15 "$MP_JQ" "FAKE_CODEX_MODE=success" -- --async --scope uncommitted 2>&1 )"
marker="$( printf '%s\n' "$out" | grep '^PENDING: ' | sed 's/^PENDING: //' )"
if [ -n "$marker" ] && grep -q "sibling file '$( printf '%s' "${marker##*/}" ).done' exists" "$marker"; then
  pass "marker header names the .done file without depending on basename(1)"
else
  fail "marker header lost the file name under the minimal PATH" "$(grep 'sibling file' "$marker" 2>/dev/null)"
fi
sut_run 40 "$MP_JQ" -- --wait "$marker" --timeout 25 >/dev/null 2>&1
rm -rf "$repo"

# (7d) YELLOW-5: --base is advertised as an immutable scope, so BOTH ends must
# be frozen at launch. The child must receive shas, never names, and must not
# resolve HEAD for itself minutes later. Proof is in the argv that reaches
# codex: no literal 'HEAD' in the diff command.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
( cd "$repo" && PATH="$FULL_PATH" git commit -q --allow-empty -m second \
  && echo "x=1" > change.sh && PATH="$FULL_PATH" git add -A && PATH="$FULL_PATH" git commit -qm third ) >/dev/null 2>&1
base_argv="$WORKROOT/base-async-argv.log"; : > "$base_argv"
out="$( cd "$repo" && sut_run 30 "$MP_JQ" "FAKE_CODEX_MODE=clean" "FAKE_CODEX_ARGV_LOG=$base_argv" -- --async --base HEAD~2 2>&1 )"
marker="$( printf '%s\n' "$out" | grep '^PENDING: ' | sed 's/^PENDING: //' )"
sut_run 40 "$MP_JQ" -- --wait "$marker" --timeout 25 >/dev/null 2>&1
diffcmd="$(grep -o 'git diff [0-9a-f]*\.\.\.[^ ]*' "$base_argv" | head -1)"
if [ -n "$diffcmd" ] && ! printf '%s' "$diffcmd" | grep -q 'HEAD' \
   && printf '%s' "$diffcmd" | grep -qE '^git diff [0-9a-f]{40}\.\.\.[0-9a-f]{40}$'; then
  pass "--async --base freezes both ends to shas at launch ($diffcmd)"
else
  fail "an async --base range still carries a name codex resolves later" "diff cmd: ${diffcmd:-<none>}"
fi
# negative control: the synchronous path still sends the literal HEAD it always did
: > "$base_argv"
out="$( cd "$repo" && sut_run 20 "$MP_JQ" "FAKE_CODEX_MODE=clean" "FAKE_CODEX_ARGV_LOG=$base_argv" -- --base HEAD~2 2>&1 )"
if grep -q 'git diff [0-9a-f]*\.\.\.HEAD' "$base_argv"; then
  pass "negative control: the synchronous --base is unchanged (literal HEAD, as before T-070)"
else
  fail "the sync path's diff command changed" "$(grep -o 'git diff [^(]*' "$base_argv" | head -1)"
fi
rm -rf "$repo"

# (7f) The path a neighbouring ticket crashed on: --async with an explicit
# --effort. Nothing about the flag is special, which is exactly why nothing
# covered it, and a crash on it reached another packet before any test did.
repo="$(new_repo)"
consent_file "$repo" '{"enabled": true}'
echo "x=1" > "$repo/change.sh"
out="$( cd "$repo" && sut_run 15 "$MP_JQ" "FAKE_CODEX_MODE=success" -- --async --effort high --scope uncommitted 2>&1 )"
marker="$( printf '%s\n' "$out" | grep '^PENDING: ' | sed 's/^PENDING: //' )"
waited="$( sut_run 40 "$MP_JQ" -- --wait "$marker" --timeout 25 2>&1 )"; wrc=$?
if [ "$wrc" = 0 ] && printf '%s' "$waited" | grep -q '^OK: Codex review finished in .*luna/high' \
   && ! printf '%s' "$waited" | grep -q 'command not found'; then
  pass "--async --effort high completes and signs off (the path a neighbouring ticket crashed on)"
else
  fail "--async --effort high did not produce a clean verdict (rc=$wrc)" "wait: $waited"
fi
rm -rf "$repo"

# (7g) Root cause of that crash, and the fix. bash reads a script by byte
# offset for as long as it runs, so editing this file during a half-hour
# detached review makes the child resume inside different bytes and execute a
# fragment — observed as `line 725: already: command not found`, the word from
# `--out $OUT already exists`. Reviews of THIS skill are both the longest and
# the ones most likely to run while somebody edits it, so the launcher executes
# a private snapshot. Here the canon is overwritten mid-run on purpose.
slow_dir="$WORKROOT/slowcodex"; mkdir -p "$slow_dir"
cat > "$slow_dir/codex" <<SLOW_EOF
#!/bin/bash
sleep 5
export FAKE_CODEX_MODE=success
exec "$FAKE_CODEX" "\$@"
SLOW_EOF
chmod +x "$slow_dir/codex"
MP_SLOW="$WORKROOT/minpath-slow"; make_minpath "$MP_SLOW" jq
ln -sf "$slow_dir/codex" "$MP_SLOW/codex"

# run_edited_canon <copy-path> -> echoes "rc|first line of the verdict"
run_edited_canon() {
  local canon="$1" r m w rc
  r="$(new_repo)"
  consent_file "$r" '{"enabled": true}'
  echo "x=1" > "$r/change.sh"
  m="$( cd "$r" && PF_CODEX_REVIEW_SCRIPT="$canon" SUT="$canon"         run_with_timeout 15 env PATH="$MP_SLOW" "$BASH_BIN" "$canon" --async --scope uncommitted 2>&1         | grep '^PENDING: ' | sed 's/^PENDING: //' )"
  # Overwrite the canon while the detached child is still reading it, changing
  # every byte offset after the header — an ordinary edit, not sabotage.
  printf '#!/usr/bin/env bash
%s
exit 0
'     "$(printf '# a header line inserted by an editor mid-run
%.0s' 1 2 3 4 5 6 7 8 9 10)" > "$canon"
  w="$( run_with_timeout 60 env PATH="$MP_SLOW" "$BASH_BIN" "$SUT" --wait "$m" --timeout 40 2>&1 )"; rc=$?
  rm -rf "$r"
  printf '%s|%s' "$rc" "$( printf '%s\n' "$w" | head -1 )"
}

canon_ok="$WORKROOT/canon-snapshotting.sh"; cp "$SUT" "$canon_ok"
res="$(run_edited_canon "$canon_ok")"
if [ "${res%%|*}" = 0 ] && printf '%s' "${res#*|}" | grep -q '^OK: Codex review finished'; then
  pass "the canon may be edited mid-run: the detached child runs a private snapshot and still signs off"
else
  fail "editing the canon during a detached run broke it" "got: $res"
fi

# Mutation control with an anchor: take the snapshot away and the same scenario
# must go red, or the test above proves nothing.
canon_bad="$WORKROOT/canon-no-snapshot.sh"
if PATH="$FULL_PATH" python3 - "$SUT" "$canon_bad" <<'MUT_EOF'
import io, sys
src, dst = sys.argv[1], sys.argv[2]
s = io.open(src, encoding="utf-8").read()
old = '_ "${BASH:-bash}" "$SELF_SNAP" ${FWD[@]+"${FWD[@]}"}'
new = '_ "${BASH:-bash}" "$SELF" ${FWD[@]+"${FWD[@]}"}'
assert s.count(old) == 1, "anchor not unique: %d" % s.count(old)
io.open(dst, "w", encoding="utf-8").write(s.replace(old, new, 1))
MUT_EOF
then
  res="$(run_edited_canon "$canon_bad")"
  if [ "${res%%|*}" != 0 ] || ! printf '%s' "${res#*|}" | grep -q '^OK:'; then
    pass "mutation control: without the private snapshot the same edit breaks the run (harness is not vacuous)"
  else
    fail "the scenario passes even without the fix — it proves nothing" "got: $res"
  fi
else
  fail "could not build the mutation control (anchor missing in the SUT)" "the launcher no longer execs \$SELF_SNAP"
fi
rm -f "$canon_ok" "$canon_bad"; rm -rf "$slow_dir"

# (7e) RED-2: the two files a reader follows must not contradict each other.
# SKILL.md is read every session, references/ only by link — so the trap
# described in one must not be the instruction given by the other.
skill_md="$TESTS_DIR/../../SKILL.md"
ref_md="$TESTS_DIR/../../references/codex-review.md"
if [ -f "$skill_md" ] && [ -f "$ref_md" ] \
   && ! grep -q -- '--async --scope uncommitted' "$skill_md" \
   && grep -q -- '--async --commit' "$skill_md" \
   && grep -q 'synchronous' "$skill_md" \
   && grep -q -- '--async --commit' "$ref_md"; then
  pass "SKILL.md step 5a sends an async run at an immutable scope, agreeing with references/codex-review.md"
else
  fail "SKILL.md still points an async run at the moving target its own reference warns about" \
       "skill: $(grep -o -- '--async[^`]*' "$skill_md" | head -2 | tr '\n' ' ')"
fi

# (8b) a stray chunk list must not narrow an ordinary review (P2, gate
# 2026-09-04). Outside a detached run the list is ignored, so the review still
# covers the whole diff and no pathspec reaches the prompt.
# Its own repo on purpose: cases inserted above this one reassigned and then
# deleted a shared `repo`, and this scenario failed against a directory that no
# longer existed — a harness defect that reads exactly like a product one.
argv_stray="$WORKROOT/stray-chunk-argv.log"; : > "$argv_stray"
printf 'change.sh\n' > "$WORKROOT/stray-chunk-list.txt"
stray_repo="$(new_repo)"
consent_file "$stray_repo" '{"enabled": true}'
echo "x=1" > "$stray_repo/change.sh"
echo "y=2" > "$stray_repo/other.sh"
out="$( cd "$stray_repo" && sut_run 15 "$MP_JQ" "FAKE_CODEX_MODE=clean" "FAKE_CODEX_ARGV_LOG=$argv_stray" \
        "PF_CODEX_CHUNK_FILE=$WORKROOT/stray-chunk-list.txt" -- --scope uncommitted 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '2 code files' \
   && ! grep -q "git diff HEAD --" "$argv_stray"; then
  pass "PF_CODEX_CHUNK_FILE alone cannot narrow a review — it needs a detached run"
else
  fail "a stray chunk list silently narrowed an ordinary review (rc=$rc)" "stdout: $out"
fi
rm -f "$WORKROOT/stray-chunk-list.txt"
rm -rf "$stray_repo"

# (9) chunking: the split plan and its negative control. The threshold lives in
# one constant; these two cases pin both sides of it.
big_repo="$(new_repo)"
consent_file "$big_repo" '{"enabled": true}'
i=1; while [ "$i" -le 60 ]; do echo "v=$i" > "$big_repo/f$i.sh"; i=$(( i + 1 )); done
out="$( cd "$big_repo" && sut_run 15 "$MP_JQ" "PF_CODEX_ASYNC=1" "PF_CODEX_PRINT_CHUNKS=1" -- --scope uncommitted 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^CHUNKS: 3 group(s) of at most 25 file(s) for 60 code file(s)' \
   && printf '%s' "$out" | grep -q '^CHUNK 1/3: 25 file(s)' \
   && printf '%s' "$out" | grep -q '^CHUNK 3/3: 10 file(s)'; then
  pass "60 code files split into 3 groups of 25/25/10"
else
  fail "chunk plan wrong for 60 files (rc=$rc)" "stdout: $out"
fi
small_repo="$(new_repo)"
consent_file "$small_repo" '{"enabled": true}'
i=1; while [ "$i" -le 20 ]; do echo "v=$i" > "$small_repo/f$i.sh"; i=$(( i + 1 )); done
out="$( cd "$small_repo" && sut_run 15 "$MP_JQ" "PF_CODEX_ASYNC=1" "PF_CODEX_PRINT_CHUNKS=1" "PF_CODEX_PRINT_BUDGET=1" -- --scope uncommitted 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q '^CHUNKS:' && printf '%s' "$out" | grep -q '^BUDGET:'; then
  pass "negative control: 20 files stay one pass (under the threshold, no split)"
else
  fail "a diff under the threshold was split anyway (rc=$rc)" "stdout: $out"
fi
rm -rf "$small_repo"

# (10) a chunked run really restricts each pass: the pathspec reaches the diff
# command in the prompt, the groups partition the diff exactly (no file seen
# twice, none dropped), and the findings are summed into one verdict.
argv_log="$WORKROOT/async-chunk-argv.log"; : > "$argv_log"
out="$( cd "$big_repo" && sut_run 60 "$MP_JQ" "PF_CODEX_ASYNC=1" "FAKE_CODEX_MODE=findings-multi" "FAKE_CODEX_ARGV_LOG=$argv_log" -- --scope uncommitted 2>&1 )"; rc=$?
calls="$(grep -c '^exec --skip-git-repo-check' "$argv_log" || true)"
partition="$(grep -o "git diff HEAD -- [^(]*" "$argv_log" | tr ' ' '\n' | grep "^'f" | tr -d "'" | sort -u | grep -c .)"
if [ "$rc" = 0 ] && [ "$calls" = 3 ] && [ "$partition" = 60 ] \
   && printf '%s' "$out" | grep -q '^FINDINGS: P1=3 P2=3 P3=3 (total 9)' \
   && printf '%s' "$out" | grep -q '^OK: Codex review finished in .* (3 groups, 60 code files, every group reviewed)'; then
  pass "3 passes, pathspecs cover all 60 files exactly once, findings summed (P1=3 P2=3 P3=3)"
else
  fail "chunked run did not partition or aggregate correctly (rc=$rc, calls=$calls, files=$partition)" "stdout: $out"
fi
# exactly one column-0 verdict: a reader grepping '^FAIL:' must never get an
# ambiguous answer from per-group lines.
if [ "$( printf '%s\n' "$out" | grep -cE '^(OK|SKIP|FAIL): ' )" = 1 ]; then
  pass "per-group verdicts are prefixed — only the aggregate sits at column 0"
else
  fail "more than one column-0 verdict line in a chunked run" "stdout: $out"
fi

# (11) a caller's --out is never handed to two groups (F-05 would refuse the
# second and the review would silently shrink to one group).
rm -f "$WORKROOT/chunked-report"*.md
out="$( cd "$big_repo" && sut_run 60 "$MP_JQ" "PF_CODEX_ASYNC=1" "FAKE_CODEX_MODE=clean" -- --scope uncommitted --out "$WORKROOT/chunked-report.md" 2>&1 )"; rc=$?
if [ "$rc" = 0 ] && [ -s "$WORKROOT/chunked-report-chunk-1.md" ] \
   && [ -s "$WORKROOT/chunked-report-chunk-2.md" ] && [ -s "$WORKROOT/chunked-report-chunk-3.md" ] \
   && ! printf '%s' "$out" | grep -q 'refusing to overwrite'; then
  pass "--out with chunking derives one report per group, no F-05 collision"
else
  fail "--out collided across groups (rc=$rc)" "stdout: $out"
fi
rm -f "$WORKROOT/chunked-report"*.md

# (12) NEGATIVE CONTROL for the aggregate: one bad group poisons the verdict.
# Without this, "2 of 3 reviewed" could read as OK — the exact silent-success
# shape §11 forbids. The double answers on its call ordinal: first call is a
# provider dump (no marker -> FAIL), the rest are honest clean reviews.
stateful_dir="$WORKROOT/stateful"; mkdir -p "$stateful_dir/bin"
# No `env` here: it is deliberately absent from the curated PATH (BASE_TOOLS),
# and a double that needs a tool the SUT does not need would test the harness,
# not the product — as this case proved on its first run.
cat > "$stateful_dir/bin/codex" <<STATEFUL_EOF
#!/bin/bash
N=\$(cat "$stateful_dir/count" 2>/dev/null || echo 0); N=\$(( N + 1 )); echo "\$N" > "$stateful_dir/count"
if [ "\$N" = 1 ]; then export FAKE_CODEX_MODE=html-error; else export FAKE_CODEX_MODE=clean; fi
exec "$FAKE_CODEX" "\$@"
STATEFUL_EOF
chmod +x "$stateful_dir/bin/codex"
MP_STATEFUL="$WORKROOT/minpath-stateful"; make_minpath "$MP_STATEFUL" jq
ln -sf "$stateful_dir/bin/codex" "$MP_STATEFUL/codex"
out="$( cd "$big_repo" && sut_run 60 "$MP_STATEFUL" "PF_CODEX_ASYNC=1" -- --scope uncommitted 2>&1 )"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^FAIL: not reviewed — 1 of 3 group(s) produced no verdict' \
   && printf '%s' "$out" | grep -q '^CHUNKS: 3 group(s) .* ok=2 skipped=0 failed=1'; then
  pass "one failed group makes the whole verdict FAIL, exit 1 (2 of 3 is not clean)"
else
  fail "a partial review was reported as success (rc=$rc)" "stdout: $out"
fi

# (13) RED-1, gate 2026-09-04: a group that SKIPS is a hole in the coverage,
# not a neutral outcome. This is the shape the gate actually caught — 1 OK and
# 2 SKIP out of 3 reported OK: and exit 0, i.e. 20 files of 60 reviewed and
# called clean. Reached the way the gate reached it, with no sabotage at all:
# the derived per-group --out paths already exist, so groups 2 and 3 refuse
# them under F-05 and skip.
rm -f "$WORKROOT/skipagg"*.md
: > "$WORKROOT/skipagg-chunk-2.md"; : > "$WORKROOT/skipagg-chunk-3.md"
out="$( cd "$big_repo" && sut_run 60 "$MP_JQ" "PF_CODEX_ASYNC=1" "FAKE_CODEX_MODE=clean" -- --scope uncommitted --out "$WORKROOT/skipagg.md" 2>&1 )"; rc=$?
if [ "$rc" = 1 ] \
   && printf '%s' "$out" | grep -q '^CHUNKS: 3 group(s) .* ok=1 skipped=2 failed=0' \
   && printf '%s' "$out" | grep -q '^FAIL: not reviewed — 2 of 3 group(s) produced no verdict' \
   && ! printf '%s' "$out" | grep -q '^OK:'; then
  pass "1 OK + 2 SKIP of 3 -> FAIL, exit 1 (a skip is 'no review happened here')"
else
  fail "skipped groups were counted as harmless — 20 of 60 files reviewed, reported clean (rc=$rc)" "stdout: $out"
fi
rm -f "$WORKROOT/skipagg"*.md

# (14) YELLOW-6: the whole-run budget. Set to zero seconds, no group may start,
# and the run must say so rather than report the groups that fit.
out="$( cd "$big_repo" && sut_run 60 "$MP_JQ" "PF_CODEX_ASYNC=1" "FAKE_CODEX_MODE=clean" "PF_CODEX_TOTAL_BUDGET=0" -- --scope uncommitted 2>&1 )"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q '^FAIL: budget exhausted, 0 of 3 groups reviewed' \
   && printf '%s' "$out" | grep -q '^NOTE: this run is split into 3 group(s)'; then
  pass "whole-run budget: exhausted -> FAIL naming how many groups ran, plus an up-front NOTE with the forecast"
else
  fail "the run budget did not stop the run honestly (rc=$rc)" "stdout: $out"
fi
rm -rf "$big_repo" "$stateful_dir"

finish
