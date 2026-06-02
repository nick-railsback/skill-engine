#!/usr/bin/env bash
# Feature-scoped test runner for verify.sh Check 4 (catalog ↔ references
# bijection) — the largest and most edge-case-dense check in the stamped
# verify.sh, and previously the least covered.
#
# Each case builds a synthetic contextualizer tree in a tempdir (a minimal
# valid source-paths.json with empty sources so Checks 1/2/5.5/6/7/8 pass or
# skip, isolating Check 4), runs the stamped verify.sh against it via
# CTX_ROOT, and asserts exit code + a diagnostic substring.
#
# The `inline-comment-after-row` case is a regression test for the sed
# range bug where a same-line `<!-- ... -->` on a catalog row caused
# `sed '/<!--/,/-->/d'` to delete every row after it (to EOF), producing
# false "orphan reference" failures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY_SH="$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh"

pass_count=0
fail_count=0
created_dirs=()

cleanup_tmp() {
  local d
  for d in "${created_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup_tmp EXIT

# Minimal valid source-paths.json (empty sources) so only Check 4 can fail.
seed_ctx() {
  local ctx="$1"
  mkdir -p "$ctx/research" "$ctx/references"
  printf '{"schema_version": 1, "sources": []}\n' > "$ctx/research/source-paths.json"
}

write_nav() {
  # $1 = ctx root, $2... = catalog body lines (already markdown table rows)
  local ctx="$1"; shift
  {
    printf -- '---\n'
    printf 'name: test-context\n'
    printf 'description: Fixture navigator for bijection tests.\n'
    printf -- '---\n\n'
    printf '# Context navigator\n\n## Catalog\n\n'
    printf '| Reference | Description |\n|---|---|\n'
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$ctx/SKILL.md"
}

write_ref() {
  # $1 = ctx root, $2 = slug ; body has no YAML frontmatter (Check 5)
  printf '# %s\n\nReference body for %s.\n' "$2" "$2" > "$1/references/$2.md"
}

# Args: 1=name 2=expected-rc 3=expected-substring 4=builder-fn
run_case() {
  local name="$1" exp_rc="$2" exp_substr="$3" builder="$4"
  local ctx
  ctx="$(mktemp -d -t skill-engine-bijection.XXXXXX)"
  created_dirs+=("$ctx")
  seed_ctx "$ctx"
  "$builder" "$ctx"

  local out rc
  out="$(CTX_ROOT="$ctx" bash "$VERIFY_SH" 2>&1)" && rc=0 || rc=$?

  if [ "$rc" -eq "$exp_rc" ] && printf '%s' "$out" | grep -qF -- "$exp_substr"; then
    printf '  PASS  %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %s\n        expected rc=%d substr=%q\n        got rc=%d:\n%s\n' \
      "$name" "$exp_rc" "$exp_substr" "$rc" "$out"
    fail_count=$((fail_count + 1))
  fi
}

# ── Cases ────────────────────────────────────────────────────────────────

build_valid() {
  local ctx="$1"
  write_ref "$ctx" foo
  write_ref "$ctx" bar
  write_nav "$ctx" \
    '| [foo](references/foo.md) | Foo. |' \
    '| [bar](references/bar.md) | Bar. |'
}

# Regression: a same-line HTML comment on the FIRST row must not swallow the
# SECOND row. With the bug present, `bar` is reported orphan and rc=1.
build_inline_comment_after_row() {
  local ctx="$1"
  write_ref "$ctx" foo
  write_ref "$ctx" bar
  write_nav "$ctx" \
    '| [foo](references/foo.md) | Foo with an eval() mention. |  | <!-- nosemgrep: skill-content-eval -->' \
    '| [bar](references/bar.md) | Bar. |'
}

build_orphan() {
  local ctx="$1"
  write_ref "$ctx" foo
  write_ref "$ctx" bar
  write_nav "$ctx" \
    '| [foo](references/foo.md) | Foo. |'
}

build_phantom() {
  local ctx="$1"
  write_ref "$ctx" foo
  write_nav "$ctx" \
    '| [foo](references/foo.md) | Foo. |' \
    '| [bar](references/bar.md) | Bar (no file). |'
}

build_duplicate_form() {
  local ctx="$1"
  write_ref "$ctx" foo
  mkdir -p "$ctx/references/foo"
  printf '# foo\n\nDir-form primary.\n' > "$ctx/references/foo/foo.md"
  write_nav "$ctx" \
    '| [foo](references/foo.md) | Foo. |'
}

run_case "valid-bijection"            0 "bijection valid"               build_valid
run_case "inline-comment-after-row"   0 "bijection valid"               build_inline_comment_after_row
run_case "orphan-reference"           1 "no catalog row points at it"   build_orphan
run_case "phantom-row"                1 "no matching reference exists"  build_phantom
run_case "duplicate-form"             1 "duplicate primary"             build_duplicate_form

# ── Summary ──────────────────────────────────────────────────────────────
printf '\nverify-bijection: %d passed, %d failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
