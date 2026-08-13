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
f09_case() {
  local mode="$1" expect="$2" desc="$3"
  local repo; repo="$(new_repo)"
  consent_file "$repo" '{"enabled": true}'
  echo "x=1" > "$repo/change.sh"
  local out rc
  out="$( cd "$repo" && sut_run 10 "$MP_JQ" "FAKE_CODEX_MODE=$mode" -- --scope uncommitted 2>&1 )"
  rc=$?
  local got=""
  if printf '%s' "$out" | grep -qE '^FAIL:.*not reviewed'; then got="fail-not-reviewed"
  elif printf '%s' "$out" | grep -qE '^OK:.*'; then got="ok"
  fi
  if [ "$got" = "$expect" ]; then
    pass "$desc -> $got (rc=$rc)"
  else
    fail "$desc -> got '$got', expected '$expect' (rc=$rc)" "stdout: $(printf '%s' "$out" | head -4 | tr '\n' '|')"
  fi
  rm -rf "$repo"
}

f09_case error-rc0 fail-not-reviewed "stdout 'authentication failed...' + exit 0"
f09_case clean ok "genuine 'no problems found' text (must NOT become a false FAIL)"
f09_case success ok "genuine findings present (baseline)"
f09_case empty fail-not-reviewed "empty output + exit 0 (pre-existing contract)"
f09_case crash fail-not-reviewed "nonzero exit (pre-existing contract)"

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
  f10_case --base "$ref" native "native mode, --base with ref [$ref]"
  f10_case --commit "$ref" why "focused mode, --commit with ref [$ref]"
  f10_case --commit "$ref" native "native mode, --commit with ref [$ref]"
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
if [ -n "$gc_pid" ] && ! kill -0 "$gc_pid" 2>/dev/null; then
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
