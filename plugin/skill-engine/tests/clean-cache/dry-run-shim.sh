#!/usr/bin/env bash
# Mirror of the dry-run-listing portion of clean-cache/SKILL.md, factored
# out so the test harness can exercise it. Kept structurally identical
# to the SKILL.md bash; any divergence is a bug.

set -euo pipefail

cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/skill-engine"
kind="${SKILL_ENGINE_CLEAN_CACHE_KIND:-}"

if [ ! -d "$cache_root" ]; then
  exit 0
fi

case "$kind" in
  ""|git-managed|web-doc) ;;
  *)
    printf 'ERROR: invalid kind %q (expected: git-managed, web-doc, or omitted)\n' "$kind" >&2
    exit 2
    ;;
esac

# Build the list of directories in scope.
if [ -z "$kind" ]; then
  scan_globs=( "$cache_root"/git-managed/*/ "$cache_root"/web-doc/*/ "$cache_root"/*/ )
else
  scan_globs=( "$cache_root/$kind"/*/ )
fi

for d in "${scan_globs[@]}"; do
  [ -d "$d" ] || continue
  base="$(basename "$d")"
  # Skip the kind subdirectories themselves when caught by the bare */ glob.
  if [ -z "$kind" ]; then
    [ "$base" = "git-managed" ] && continue
    [ "$base" = "web-doc" ] && continue
  fi
  name="${d#"$cache_root"/}"
  printf '%s\n' "${name%/}"
done
