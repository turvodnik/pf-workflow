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
i033_note_case findings-no-marker ok "marker missing but two well-formed finding lines -> accepted on structure, with a loud NOTE"

# Emergency relief valve: the marker stops being the verdict, the second
# echelon decides again — loudly, and at the stated price.
i033_note_case clean-no-marker ok "PF_CODEX_SENTINEL_OPTIONAL=1: clean review without a marker -> OK again, with a loud NOTE" "PF_CODEX_SENTINEL_OPTIONAL=1"
i033_note_case error-rc0 fail-not-reviewed "PF_CODEX_SENTINEL_OPTIONAL=1: a known failure shape is still caught by the second echelon" "PF_CODEX_SENTINEL_OPTIONAL=1"

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
# A review WITH findings stays green on purpose: the backup proof of report
# structure is doing its job, and this row documents that boundary rather than
# leaving it as an unstated soft spot.
i033_note_case success ok "negative control boundary: a review WITH findings survives on structure alone, with a loud NOTE"
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

finish
