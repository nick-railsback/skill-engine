#!/usr/bin/env bash
# Frontmatter-ceiling sweep: report every tracked, hand-authored Markdown
# document that tells its reader navigator frontmatter is limited to `name`
# and `description`. The artifact contract admits `paths:` as an optional
# third field, so any such statement is drift.
#
# Usage: bash sweep.sh <repo-root>
#
#   <repo-root> must be the top level of a git work tree.
#
# Output: one line per hit, `<repo-relative path>: <matched phrase>`, where
# the phrase is shown as it reads after normalization (below). Each phrase
# is counted on its own, so two different phrases on one line are two hits.
#
# Exit: 0 no hits, 1 at least one hit, 2 the sweep could not run (not a
# work-tree top level, the listing failed, or it named no file at all — an
# empty set is a broken listing, never a clean tree).
#
# THE FILE SET is derived, never enumerated: every `*.md` and
# `*.md.template` that `git ls-files` names — tracked files only, so a file
# present on disk but never added is not read — minus exactly two
# exclusions:
#   CHANGELOG.md                 the top-level changelog. It records what was
#                                true when each entry was written, and an
#                                entry may name a retired phrase to say it
#                                was retired. Only that one file: a
#                                `docs/CHANGELOG-notes.md` is still read.
#   */<x>-context/references/*   references a contextualizer's refresh
#                                generates. Only a `-context/references/`
#                                segment pair: a hand-authored
#                                `skills/<x>/references/` file is still read.
# Exclusions are matched against the repo-relative path `ls-files` prints,
# never an absolute one, so the directory a checkout happens to live in can
# never exclude anything.
#
# THE MATCH is a phrase family, not an understanding of prose. A paraphrase
# outside the family passes; that limit is deliberate and is left to review.
# Each file is normalized before matching:
#   - hard-wraps are joined, so a phrase split across lines still matches;
#   - `*` and backticks are deleted, so emphasis or a code span inside the
#     phrase cannot split it;
#   - runs of blanks collapse to one space;
#   - text is lowercased.
# The family is deliberately narrow: "name and description are required",
# "the two required frontmatter fields" and a bare "two fields" are correct
# or unrelated statements and must not match.

set -uo pipefail
LC_ALL=C
export LC_ALL

# One extended regex per line, matched against normalized text.
PHRASES=(
  'two-field frontmatter'
  'two-field navigator'
  'name: and description: only'
  'only name and description'
  'exactly two fields'
  'only (the )?two (standard |required )?(frontmatter )?fields'
)

root="${1:-}"
if [ -z "$root" ] || [ ! -d "$root" ]; then
  echo "sweep: usage: sweep.sh <repo-root>" >&2
  exit 2
fi

prefix="$(git -C "$root" rev-parse --show-prefix 2>/dev/null)" || {
  echo "sweep: not a git work tree: $root" >&2
  exit 2
}
if [ -n "$prefix" ]; then
  echo "sweep: not the top level of its work tree: $root" >&2
  exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# list_files — NUL-separated repo-relative paths of the candidate set.
list_files() {
  git -C "$root" ls-files -z -- '*.md' '*.md.template'
}

# is_excluded <repo-relative path>
is_excluded() {
  case "$1" in
    CHANGELOG.md) return 0 ;;
  esac
  case "$1" in
    *-context/references/*) return 0 ;;
  esac
  return 1
}

# normalize <file> — the file as one lowercased, marker-free line.
normalize() {
  tr '\r\n' '  ' < "$1" |
    tr -d '*`' |
    tr -s ' \t' '  ' |
    tr '[:upper:]' '[:lower:]'
}

if ! list_files > "$work/list"; then
  echo "sweep: git ls-files failed under $root" >&2
  exit 2
fi

scanned=0
hits=0
while IFS= read -r -d '' rel; do
  is_excluded "$rel" && continue
  [ -f "$root/$rel" ] || continue
  scanned=$((scanned + 1))
  normalize "$root/$rel" > "$work/norm"
  for phrase in "${PHRASES[@]}"; do
    # grep -o per phrase: one phrase's match can never consume another's.
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      printf '%s: %s\n' "$rel" "$m"
      hits=$((hits + 1))
    done < <(grep -oaE -- "$phrase" "$work/norm")
  done
done < "$work/list"

if [ "$scanned" -eq 0 ]; then
  echo "sweep: the listing named no file to scan under $root" >&2
  exit 2
fi

[ "$hits" -eq 0 ] || exit 1
exit 0
