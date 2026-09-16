#!/usr/bin/env bash
# No shipped Markdown document tells its reader that navigator frontmatter is
# limited to `name` and `description`. The artifact contract admits `paths:`
# as an optional third field; this suite holds the rest of the doc tree to
# that.
#
#   ceiling sweep                — across every tracked, hand-authored
#                                  Markdown file (derived from git, never
#                                  listed here), zero statements of the
#                                  retired two-field ceiling. See sweep.sh
#                                  beside this file for the file set, the
#                                  exclusions and the phrase family.
#   walkthrough frontmatter note — the walkthrough's description of the
#                                  example navigator's frontmatter names
#                                  `paths:` as optional, rather than
#                                  presenting the example's two fields as the
#                                  rule.
#   contract conventions table   — the contract's "Why these conventions
#                                  exist" table names the frontmatter
#                                  convention as the contract's field set,
#                                  `paths:` included, and its rationale
#                                  marks `paths:` as Claude Code-scoped
#                                  rather than as part of what keeps
#                                  loading cross-platform.
#   contract paths: paragraph    — § Frontmatter fields states what Check 3
#                                  reads as no entry and what it fails
#                                  outright: a trailing comment, a YAML
#                                  null, a flow sequence that never closes,
#                                  a repeated key.
#
# Every assertion here is a fact still owed. The sweep's own precision and
# reach already hold, so they live in `preserved.sh` beside this file, each
# with a mutation control, and are never run from here.
#
# SWEEP_SH points the run at another copy of the sweep.
#
# -e is intentionally omitted: every assertion runs and reports, rather than
# the run aborting at the first failure.

set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
SWEEP_SH="${SWEEP_SH:-$SCRIPT_DIR/sweep.sh}"

WALKTHROUGH_DOC="$PLUGIN_ROOT/docs/11-walkthrough.md"
CONTRACT_DOC="$PLUGIN_ROOT/docs/02-artifact-contract.md"

pass_count=0
fail_count=0

pass() {
  printf '  PASS  %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail() {
  local label="$1"
  shift
  printf '  FAIL  %s\n' "$label"
  if [ "$#" -gt 0 ]; then
    printf '        %s\n' "$@"
  fi
  fail_count=$((fail_count + 1))
}

# flatten — one lowercased line with `*` and backticks deleted and blanks
# collapsed, so neither a hard-wrap nor emphasis can flip a result.
flatten() {
  tr '\r\n' '  ' | tr -d '*`' | tr -s ' \t' '  ' | tr '[:upper:]' '[:lower:]'
}

# prose_units — Markdown on stdin, one prose unit per output line, flattened
# as `flatten` does. A unit is a list item (with its hard-wrapped
# continuation lines), a paragraph, a heading, or a single line inside a
# fenced block. Units rather than character windows: two adjacent bullets
# can each mention frontmatter, and a window wide enough to hold one
# bullet's whole sentence reaches into the next, so a statement made in the
# wrong bullet would count for the right one. No bounded regex repetition
# either: BSD grep refuses a `{0,N}` above 255 and reports that as a
# non-match.
prose_units() {
  awk '
    function flush() { if (unit != "") print unit; unit = "" }
    /^[[:space:]]*(```|~~~)/ { flush(); infence = !infence; next }
    infence { flush(); print; next }
    /^[[:space:]]*$/ { flush(); next }
    /^#/ { flush(); print; next }
    /^[[:space:]]*([*+-]|[0-9]+[.)])[[:space:]]/ { flush(); unit = $0; next }
    { unit = (unit == "" ? $0 : unit " " $0) }
    END { flush() }
  ' | tr -d '\r*`' | tr -s ' \t' '  ' | tr '[:upper:]' '[:lower:]'
}

# section_from <heading-line-regex> <file> — from the first line matching the
# regex through the next `## ` heading (exclusive), or end of file.
section_from() {
  awk -v want="$1" '
    found && /^## / { exit }
    !found && $0 ~ want { found = 1 }
    found { print }
  ' "$2"
}

# has_word <text> <word> — <word> present with no letter on either side.
has_word() {
  printf '%s\n' "$1" | grep -qE "(^|[^a-z])$2([^a-z]|\$)"
}

# ════════════════════════════════════════════════════════════════════════
# ceiling sweep
# ════════════════════════════════════════════════════════════════════════

echo
echo "── ceiling sweep: tracked Markdown carries no two-field ceiling ──"

label="ceiling sweep: no tracked hand-authored Markdown file states the two-field frontmatter ceiling"
if [ ! -f "$SWEEP_SH" ]; then
  fail "$label" "no sweep at $SWEEP_SH"
else
  sweep_err="$(mktemp)"
  sweep_out="$(bash "$SWEEP_SH" "$REPO_ROOT" 2>"$sweep_err")"
  sweep_rc=$?
  sweep_msg="$(cat "$sweep_err")"
  rm -f "$sweep_err"
  if [ "$sweep_rc" -eq 0 ]; then
    pass "$label"
  elif [ "$sweep_rc" -eq 1 ]; then
    hit_lines=()
    while IFS= read -r line; do
      hit_lines+=( "hit: $line" )
    done <<< "$sweep_out"
    fail "$label" ${hit_lines[@]+"${hit_lines[@]}"}
  else
    fail "$label" "sweep could not run (exit $sweep_rc): $sweep_msg"
  fi
fi

# ════════════════════════════════════════════════════════════════════════
# walkthrough frontmatter note
# ════════════════════════════════════════════════════════════════════════

echo
echo "── walkthrough frontmatter note: paths: named as optional ──"

# The anchor is a unit (bullet or paragraph) that mentions `frontmatter` AND
# names `name` and `description` — the navigator-frontmatter bullet. The
# references' "no YAML frontmatter" bullet names neither field, so it is
# never the anchor, and a `paths:` stated there does not count. Every
# anchor unit is tested; at least one must carry `paths:` WITH its colon
# (the section already has a bare `paths` token inside `source-paths.json`)
# and `optional`.
label="walkthrough frontmatter note: the example navigator's frontmatter note names paths: as optional"
wt_units="$(section_from '^## Working with the example' "$WALKTHROUGH_DOC" 2>/dev/null | prose_units)"
if [ -z "$wt_units" ]; then
  fail "$label" "no '## Working with the example' section in ${WALKTHROUGH_DOC#"$REPO_ROOT"/}"
else
  anchors=()
  anchor_count=0
  satisfied=0
  while IFS= read -r unit; do
    case "$unit" in
      *frontmatter*) ;;
      *) continue ;;
    esac
    has_word "$unit" 'name' || continue
    has_word "$unit" 'description' || continue
    anchors+=( "anchor: $unit" )
    anchor_count=$((anchor_count + 1))
    case "$unit" in
      *paths:*) ;;
      *) continue ;;
    esac
    case "$unit" in
      *optional*) ;;
      *) continue ;;
    esac
    satisfied=$((satisfied + 1))
  done <<< "$wt_units"
  if [ "$satisfied" -gt 0 ]; then
    pass "$label"
  elif [ "$anchor_count" -eq 0 ]; then
    fail "$label" "no unit in the section mentions frontmatter together with name and description"
  else
    fail "$label" "no navigator-frontmatter unit names both 'paths:' and 'optional'" ${anchors[@]+"${anchors[@]}"}
  fi
fi

# ════════════════════════════════════════════════════════════════════════
# contract conventions table
# ════════════════════════════════════════════════════════════════════════

echo
echo "── contract conventions table: frontmatter row names paths ──"

# Two rows name frontmatter in their first cell: the navigator's, and the
# references' "no YAML frontmatter". Only the first can name `paths`, so the
# check is exactly one such row, never every frontmatter row.
label="contract conventions table: exactly one convention cell names both frontmatter and paths"
table="$(section_from '^## Why these conventions exist' "$CONTRACT_DOC" 2>/dev/null | grep -E '^[[:space:]]*\|')"
if [ -z "$table" ]; then
  fail "$label" "no table under '## Why these conventions exist' in ${CONTRACT_DOC#"$REPO_ROOT"/}"
else
  fm_cells=()
  both=0
  while IFS= read -r row; do
    cell="$(printf '%s\n' "$row" | awk -F'|' '{ print $2 }' | flatten)"
    case "$cell" in
      *frontmatter*) fm_cells+=( "frontmatter cell:$cell" ) ;;
      *) continue ;;
    esac
    case "$cell" in
      *paths*) both=$((both + 1)) ;;
    esac
  done <<< "$table"
  if [ "$both" -eq 1 ]; then
    pass "$label"
  else
    fail "$label" "cells naming both: $both" ${fm_cells[@]+"${fm_cells[@]}"}
  fi
fi

# The frontmatter row's rationale cell is about platforms that drop or
# reject unknown fields. `paths:` is a Claude Code field, so on such a
# platform it is the failure the cell describes; the cell must say so.
label="contract conventions table: the frontmatter row's rationale marks paths: as Claude Code-scoped"
if [ -z "$table" ]; then
  fail "$label" "no table under '## Why these conventions exist' in ${CONTRACT_DOC#"$REPO_ROOT"/}"
else
  scoped=0
  rationales=()
  while IFS= read -r row; do
    cell="$(printf '%s\n' "$row" | awk -F'|' '{ print $2 }' | flatten)"
    case "$cell" in
      *frontmatter*paths*) ;;
      *) continue ;;
    esac
    rationale="$(printf '%s\n' "$row" | awk -F'|' '{ print $3 }' | flatten)"
    rationales+=( "rationale:$rationale" )
    case "$rationale" in
      *paths*claude\ code*|*claude\ code*paths*) scoped=$((scoped + 1)) ;;
    esac
  done <<< "$table"
  if [ "$scoped" -eq 1 ]; then
    pass "$label"
  else
    fail "$label" ${rationales[@]+"${rationales[@]}"}
  fi
fi

# ════════════════════════════════════════════════════════════════════════
# contract paths: paragraph
# ════════════════════════════════════════════════════════════════════════

echo
echo "── contract paths: paragraph: states what Check 3 counts as no entry ──"

fm_unit="$(section_from '^### Frontmatter fields' "$CONTRACT_DOC" 2>/dev/null | prose_units | grep -F 'is admitted as an optional third' | head -1)"
for rule in 'comment' 'null' 'never closes' 'repeat'; do
  label="contract paths: paragraph: names the '$rule' rule"
  if [ -z "$fm_unit" ]; then
    fail "$label" "no paths: admission paragraph under '### Frontmatter fields' in ${CONTRACT_DOC#"$REPO_ROOT"/}"
  else
    case "$fm_unit" in
      *"$rule"*) pass "$label" ;;
      *) fail "$label" "paragraph: $fm_unit" ;;
    esac
  fi
done

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
