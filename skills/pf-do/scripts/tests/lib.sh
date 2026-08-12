#!/usr/bin/env bash
# lib.sh — shared helpers for codex-review.sh's table-driven test suite.
# Sourced by run.sh. Never runs the real `codex`: every SUT invocation below
# goes through a curated PATH that only ever contains fixtures/fake-codex.
#
# Compatibility note: this whole suite (and the script it tests) must run
# under bash 3.2 — the system /bin/bash on macOS, and what `env bash`
# resolves to for anyone without a newer bash on PATH. No $BASHPID, no
# associative arrays, no ${var,,}.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$TESTS_DIR/fixtures"
FAKE_CODEX="$FIXTURES_DIR/fake-codex"
FULL_PATH="$PATH"          # the harness's own PATH, for setup work (git, chmod, ...)
BASH_BIN="$(command -v bash)"

PASS=0
FAIL=0
FAIL_LABELS=()
CURRENT_GROUP=""
GROUP_PASS=0
GROUP_FAIL=0
GROUP_SUMMARY=()

LEAK_PID_FILE="$(mktemp -t codex-review-tests-leaks)"
CLEANUP_DIRS_FILE="$(mktemp -t codex-review-tests-dirs)"

group() {
  # Close the previous group's tally before opening a new one.
  if [ -n "$CURRENT_GROUP" ]; then
    GROUP_SUMMARY+=("$CURRENT_GROUP: $GROUP_PASS/$((GROUP_PASS + GROUP_FAIL))")
  fi
  CURRENT_GROUP="$1"
  GROUP_PASS=0
  GROUP_FAIL=0
  echo
  echo "=== $1 ==="
}

pass() {
  PASS=$((PASS + 1)); GROUP_PASS=$((GROUP_PASS + 1))
  echo "PASS  $1"
}

fail() {
  FAIL=$((FAIL + 1)); GROUP_FAIL=$((GROUP_FAIL + 1))
  echo "FAIL  $1"
  [ -n "${2:-}" ] && echo "      $2"
  FAIL_LABELS+=("[$CURRENT_GROUP] $1")
}

skip_row() {
  echo "SKIP  $1 -- $2"
}

finish() {
  if [ -n "$CURRENT_GROUP" ]; then
    GROUP_SUMMARY+=("$CURRENT_GROUP: $GROUP_PASS/$((GROUP_PASS + GROUP_FAIL))")
  fi
  echo
  echo "=== SUMMARY ==="
  local line
  for line in "${GROUP_SUMMARY[@]+"${GROUP_SUMMARY[@]}"}"; do echo "$line"; done
  echo "TOTAL: $PASS/$((PASS + FAIL))"
  if [ "$FAIL" -gt 0 ]; then
    echo
    echo "Failed:"
    local l
    for l in "${FAIL_LABELS[@]+"${FAIL_LABELS[@]}"}"; do echo "  - $l"; done
  fi
  sweep_leaks
  if [ "$FAIL" -eq 0 ]; then
    echo "RESULT: GREEN"
    return 0
  else
    echo "RESULT: RED"
    return 1
  fi
}

# --- process-group timeout wrapper --------------------------------------
# macOS has no timeout(1). A hung SUT (by design in watchdog tests, or by
# accident if a fix is wrong) must not hang the whole suite. Mirrors the
# SUT's own leader/watchdog pattern: `set -m` gives the command its own
# process group so a stuck descendant dies with it, not just the leader.
run_with_timeout() {
  local secs="$1"; shift
  set -m 2>/dev/null || true
  "$@" &
  local cmd_pid=$!
  set +m 2>/dev/null || true
  # The killer needs its OWN process group too: killing only killer_pid
  # leaves ITS `sleep $secs` orphaned (a parent's death does not kill its
  # already-forked children — the exact F-11 mechanism this suite tests
  # for). That orphan inherits this subshell's stdout, so a caller doing
  # out="$(run_with_timeout ...)" keeps blocking for the rest of $secs
  # waiting for the pipe to close, even though every PID this function
  # directly tracks is already dead. Confirmed empirically: without this,
  # every call here pays the full timeout regardless of how fast $@ exits.
  set -m 2>/dev/null || true
  ( sleep "$secs"
    kill -0 "$cmd_pid" 2>/dev/null || exit 0
    kill -KILL -- "-$cmd_pid" 2>/dev/null ) &
  local killer_pid=$!
  set +m 2>/dev/null || true
  { wait "$cmd_pid"; } 2>/dev/null
  local rc=$?
  { kill -KILL -- "-$killer_pid"; } 2>/dev/null
  { wait "$killer_pid"; } 2>/dev/null
  return "$rc"
}

# sut_run <timeout_secs> <restricted_path> [VAR=val ...] -- <sut-args...>
# Runs $BASH_BIN $SUT <sut-args...> with PATH replaced by <restricted_path>
# for that one process, via `env` (resolved from the harness's own full
# PATH — a bare `PATH=... run_with_timeout ...` would restrict the
# wrapper's own `sleep`/`kill` too, which is a harness bug, not a scenario).
# Caller must set $SUT before use.
sut_run() {
  local timeout="$1" rpath="$2"; shift 2
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  # bash 3.2 (this suite's floor — see header note) raises "unbound variable"
  # under `set -u` when a *named* array expands empty, even guarded by `||`
  # (the expansion itself aborts the script, `||` never gets a chance to
  # run) — fixed upstream only in bash 4.4. `"${envs[@]+"${envs[@]}"}"` is
  # the portable no-op-when-empty idiom; plain "$@" is unaffected.
  run_with_timeout "$timeout" env "${envs[@]+"${envs[@]}"}" PATH="$rpath" "$BASH_BIN" "$SUT" "$@"
}

# --- curated minimal PATH -------------------------------------------------
# make_minpath <dir> [extra tool]...
# Populates $dir with symlinks to a fixed, minimal toolset resolved from the
# harness's own full PATH, plus fixtures/fake-codex as `codex`. `pkill` is
# NEVER included by any caller in this suite (F-11: the fix must not need
# it). Extra readers (jq, python3) are opt-in per call for the F-04 matrix.
BASE_TOOLS="bash git printf tr grep date dirname mkdir sed cat rm mktemp sort wc head tail sleep"
make_minpath() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local tool src
  for tool in $BASE_TOOLS; do
    src="$(PATH="$FULL_PATH" command -v "$tool" 2>/dev/null)" || {
      echo "harness setup: required tool '$tool' not found on this machine" >&2
      exit 90
    }
    ln -sf "$src" "$dir/$tool"
  done
  for tool in "$@"; do
    src="$(PATH="$FULL_PATH" command -v "$tool" 2>/dev/null)" || {
      echo "harness setup: '$tool' not found on this machine, cannot build this PATH variant" >&2
      exit 90
    }
    ln -sf "$src" "$dir/$tool"
  done
  ln -sf "$FAKE_CODEX" "$dir/codex"
}

# make_minpath_no_codex <dir> — Gate 1 test only: codex itself absent.
make_minpath_no_codex() {
  local dir="$1"
  mkdir -p "$dir"
  local tool src
  for tool in $BASE_TOOLS; do
    src="$(PATH="$FULL_PATH" command -v "$tool" 2>/dev/null)" || exit 90
    ln -sf "$src" "$dir/$tool"
  done
}

# --- temp git repos --------------------------------------------------------
# new_repo — an isolated git repo with one commit, cwd left inside it.
new_repo() {
  local d
  d="$(mktemp -d -t codex-review-test-repo)"
  echo "$d" >> "$CLEANUP_DIRS_FILE"
  ( cd "$d" && PATH="$FULL_PATH" git init -q \
      && PATH="$FULL_PATH" git config user.email test@example.com \
      && PATH="$FULL_PATH" git config user.name "codex-review tests" \
      && echo "seed=1" > seed.sh \
      && PATH="$FULL_PATH" git add seed.sh \
      && PATH="$FULL_PATH" git commit -qm seed )
  printf '%s' "$d"
}

# consent_file <repo> <content>
consent_file() {
  mkdir -p "$1/.agents"
  printf '%s' "$2" > "$1/.agents/codex-review.json"
}

track_leak_pid() { printf '%s\n' "$1" >> "$LEAK_PID_FILE"; }

sweep_leaks() {
  local leaked=0
  if [ -s "$LEAK_PID_FILE" ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        leaked=$((leaked + 1))
      fi
    done < "$LEAK_PID_FILE"
  fi
  if [ "$leaked" -gt 0 ]; then
    echo "NOTE: swept $leaked leaked test process(es) at exit — see the group above for which scenario left them running."
  fi
  rm -f "$LEAK_PID_FILE"
  if [ -s "$CLEANUP_DIRS_FILE" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
    done < "$CLEANUP_DIRS_FILE"
  fi
  rm -f "$CLEANUP_DIRS_FILE"
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}
