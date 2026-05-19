#!/usr/bin/env bash
# Mirror of refresh/SKILL.md pre-flight step 1.5's flat-layout detector.
# Allow-list: a directory at the cache root with a .git/HEAD file inside
# is a flat-layout git-managed clone. Everything else is left alone.

set -euo pipefail

cache_root="${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}"
[ -d "$cache_root" ] || exit 0

for d in "$cache_root"/*/; do
  [ -d "$d" ] || continue
  [ -f "$d/.git/HEAD" ] || continue
  base="$(basename "$d")"
  printf '%s\n' "$base"
done
