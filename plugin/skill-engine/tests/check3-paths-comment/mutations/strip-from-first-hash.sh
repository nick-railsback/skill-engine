#!/usr/bin/env bash
# Control for: a `#` not preceded by whitespace is part of the glob. A
# scratch copy of the checker strips every frontmatter line from its first
# `#`, whatever precedes it, before either the same-line or the block-list
# branch reads the key.
#
# Applied ahead of both branches, the strip still handles every genuine
# trailing comment the way the right rule does, so only the hash-inside-glob
# cells can turn it red. `docs/#-anchors/**` cannot: stripped, it is still
# `docs/`, one non-blank field. A quoted glob that opens with `#` can:
# stripped, it is a lone quote, and quotes are not counted.
#
# -e is intentionally omitted so both runs are reached and their exit codes
# read.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
TEMPLATES_DIR="$PLUGIN_ROOT/engine-bootstrap-templates"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

copy="$work/verify.sh"
cp "$TEMPLATES_DIR/verify.sh" "$copy"
cp "$copy" "$work/pristine.sh"
chmod +x "$copy"

if ! VERIFY_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "pristine copy is already red"
  exit 0
fi

# Inserted after the admitted-key loop, which is the last reader of the
# frontmatter before the `paths:` logic.
printf '%s\n' \
  'fm="$(printf '"'"'%s\n'"'"' "$fm" | sed '"'"'s/#.*$//'"'"')"' \
  > "$work/inject.txt"
sed '/done < <(printf .* grep -oE /r '"$work/inject.txt" "$copy" > "$copy.mutated" \
  && mv "$copy.mutated" "$copy"
chmod +x "$copy"

if cmp -s "$work/pristine.sh" "$copy"; then
  echo "injection did not apply"
  exit 0
fi

if VERIFY_SH="$copy" bash "$SUITE_DIR/preserved.sh" >/dev/null 2>&1; then
  echo "a comment strip that begins at the first hash was accepted"
  exit 0
fi
echo "a comment strip that begins at the first hash was rejected"
exit 1
