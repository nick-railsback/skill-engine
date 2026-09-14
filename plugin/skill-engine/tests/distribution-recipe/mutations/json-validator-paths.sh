#!/usr/bin/env bash
# Control for: every manifest path the json validator walks that is present
# on disk parses as JSON. A scratch tree carries the validator plus each
# path it lists, at the same relative locations; one of those files is then
# replaced with a truncated object.
#
# The path list is read out of the validator itself rather than retyped, so
# a path added or removed there is picked up here without an edit.
#
# -e is intentionally omitted so both runs are reached and their exit codes
# read.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

script_copy="$work/ci-local.sh"
root="$work/root"
mkdir -p "$root"
cp "$REPO_ROOT/scripts/ci-local.sh" "$script_copy"

# Mirrors the extraction the suite beside this one uses: the array the
# validator iterates, one entry per line.
listed="$(awk '
  /^run_json\(\)/ { inf = 1 }
  inf && /paths=\(/ { cap = 1; next }
  cap && /^[[:space:]]*\)[[:space:]]*$/ { exit }
  cap {
    line = $0
    sub(/^[[:space:]]*"/, "", line)
    sub(/"[[:space:]]*$/, "", line)
    if (line != "") print line
  }
' "$script_copy")"

if [ -z "$listed" ]; then
  echo "pristine copy is already red"
  exit 0
fi

first_present=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$REPO_ROOT/$rel" ] || continue
  mkdir -p "$root/$(dirname "$rel")"
  cp "$REPO_ROOT/$rel" "$root/$rel"
  [ -n "$first_present" ] || first_present="$rel"
done <<< "$listed"

if [ -z "$first_present" ]; then
  echo "pristine copy is already red"
  exit 0
fi

if ! CI_LOCAL_SH="$script_copy" JSON_ROOT="$root" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

printf '{\n' > "$root/$first_present"

if CI_LOCAL_SH="$script_copy" JSON_ROOT="$root" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "an unparseable listed manifest was accepted"
  exit 0
fi
echo "an unparseable listed manifest was rejected"
exit 1
