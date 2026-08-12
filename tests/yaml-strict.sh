#!/usr/bin/env bash
# yaml-strict.sh — strict YAML-frontmatter check for the skill-library canon.
#
# Walks every skills/**/SKILL.md and every agents/*.md file and strict-parses
# the YAML frontmatter block (between the first two `---` lines) with a real
# YAML loader (Python's yaml.safe_load, or Ruby's Psych if Python/pyyaml is
# not available). A hand-rolled line scanner would happily accept frontmatter
# that breaks real parsers (e.g. an unquoted description containing ": ",
# which YAML reads as a nested mapping key) — this script only trusts an
# actual loader.
#
# Exit 0 and print a summary when every file parses to a mapping.
# Exit 1 and print the list of offending files (with the loader's error)
# when at least one file fails.
# Exit 2 when no YAML-capable interpreter is available at all — that is
# "not verified", not "clean".
#
# Usage: bash yaml-strict.sh
# Must run under bash 3.2 (macOS system /bin/bash) — no associative arrays,
# no ${var,,}, no $BASHPID.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- pick an interpreter that can actually strict-parse YAML ---------------

INTERPRETER=""
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
  INTERPRETER="python3"
elif command -v ruby >/dev/null 2>&1 && ruby -e "require 'yaml'" >/dev/null 2>&1; then
  INTERPRETER="ruby"
else
  echo "yaml-strict: NOT VERIFIED — no YAML-capable interpreter found" >&2
  echo "yaml-strict: need python3 with the 'yaml' module (pyyaml), or ruby with stdlib Psych" >&2
  exit 2
fi

# --- collect target files ---------------------------------------------------

# Portable form: GNU mktemp (Linux, incl. ubuntu-latest) rejects a bare
# `-t <prefix>` ("too few X's in template"); BSD mktemp (macOS) accepts it.
# An explicit template with X's works identically on both (verified T-016).
FILES_LIST="$(mktemp "${TMPDIR:-/tmp}/yaml-strict-files.XXXXXXXX")"
trap 'rm -f "$FILES_LIST"' EXIT

find "$ROOT/skills" -name 'SKILL.md' -print > "$FILES_LIST"
find "$ROOT/agents" -maxdepth 1 -name '*.md' -print >> "$FILES_LIST"

TOTAL=$(wc -l < "$FILES_LIST" | tr -d ' ')
if [ "$TOTAL" -eq 0 ]; then
  echo "yaml-strict: NOT VERIFIED — found zero SKILL.md/agents/*.md files under $ROOT" >&2
  exit 2
fi

# --- run the strict parse ---------------------------------------------------

PY_CHECK='
import sys, re, io

def check(path):
    with io.open(path, encoding="utf-8") as fh:
        text = fh.read()
    m = re.match(r"^---\n(.*?\n)---\n", text, re.S)
    if not m:
        return "no frontmatter block found (must start with \"---\" on line 1)"
    import yaml
    try:
        data = yaml.safe_load(m.group(1))
    except Exception as e:
        return str(e).replace("\n", " | ")
    if not isinstance(data, dict):
        return "frontmatter did not parse to a mapping (got %s)" % type(data).__name__
    return None

failed = False
with io.open(sys.argv[1], encoding="utf-8") as lst:
    paths = [l.rstrip("\n") for l in lst if l.strip()]
for path in paths:
    err = check(path)
    if err is not None:
        failed = True
        print("FAIL: %s" % path)
        print("    %s" % err)
sys.exit(1 if failed else 0)
'

RB_CHECK='
require "yaml"
require "date"

def check(path)
  text = File.read(path, encoding: "utf-8")
  m = /\A---\n(.*?\n)---\n/m.match(text)
  return "no frontmatter block found (must start with \"---\" on line 1)" unless m
  begin
    data = YAML.safe_load(m[1], permitted_classes: [Date, Time], aliases: false)
  rescue StandardError => e
    return e.message.gsub("\n", " | ")
  end
  return "frontmatter did not parse to a mapping (got #{data.class})" unless data.is_a?(Hash)
  nil
end

failed = false
paths = File.readlines(ARGV[0]).map(&:chomp).reject(&:empty?)
paths.each do |path|
  err = check(path)
  if err
    failed = true
    puts "FAIL: #{path}"
    puts "    #{err}"
  end
end
exit(failed ? 1 : 0)
'

set +e
if [ "$INTERPRETER" = "python3" ]; then
  OUTPUT="$(python3 -c "$PY_CHECK" "$FILES_LIST" 2>&1)"
  RC=$?
else
  OUTPUT="$(ruby -e "$RB_CHECK" "$FILES_LIST" 2>&1)"
  RC=$?
fi
set -e

if [ -n "$OUTPUT" ]; then
  echo "$OUTPUT"
fi

echo
echo "yaml-strict: checked $TOTAL files with $INTERPRETER"
if [ "$RC" -ne 0 ]; then
  FAIL_COUNT=$(printf '%s\n' "$OUTPUT" | grep -c '^FAIL: ' || true)
  echo "yaml-strict: $FAIL_COUNT file(s) FAILED strict frontmatter parse (see FAIL lines above)"
  exit 1
fi
echo "yaml-strict: all $TOTAL files PASS"
exit 0
