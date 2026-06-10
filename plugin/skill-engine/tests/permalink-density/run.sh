#!/usr/bin/env bash
# Feature-scoped test runner for permalink_density.py (SELF-AUDIT Check 7).
# Each case builds a synthetic references/ tree in a tempdir, invokes the
# lint, and asserts exit code + a substring in stdout.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LINT="$PLUGIN_ROOT/tests/permalink_density.py"

pass_count=0
fail_count=0

cleanup_tmp() {
  rm -rf "${TMPDIR:-/tmp}"/skill-engine-permalink-density.* 2>/dev/null || true
}
trap cleanup_tmp EXIT

# Args: 1=case-name, 2=expected-rc, 3=expected-substring, 4=fixture-builder-fn
run_case() {
  local name="$1" exp_rc="$2" exp_substr="$3" builder="$4"
  local ctx_root
  ctx_root="$(mktemp -d -t skill-engine-permalink-density.XXXXXX)"
  mkdir -p "$ctx_root/references"

  "$builder" "$ctx_root/references"

  local out rc
  out="$(python3 "$LINT" "$ctx_root/references" --threshold 0.80 --min-paragraphs 5 2>&1)" && rc=0 || rc=$?

  if [ "$rc" -eq "$exp_rc" ] && printf '%s' "$out" | grep -qF -- "$exp_substr"; then
    printf '  PASS  %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %s\n        expected rc=%d substr=%q\n        got rc=%d:\n%s\n' \
      "$name" "$exp_rc" "$exp_substr" "$rc" "$out"
    fail_count=$((fail_count + 1))
  fi
  rm -rf "$ctx_root"
}

SHA="0123456789abcdef0123456789abcdef01234567"
PERMALINK="https://github.com/foo/bar/blob/${SHA}/path/to/file.md"
TAG_PERMALINK="https://github.com/foo/bar/blob/v1.2.3/path/to/file.md"
MAIN_URL="https://github.com/foo/bar/blob/main/path/to/file.md"

# (j) empty references dir → N/A exit 0.
fx_empty() {
  : # no files written
}
run_case "empty-dir is N/A" 0 "no references emitted yet" fx_empty

# (k) fewer than 5 in-scope paragraphs → N/A exit 0.
fx_tiny() {
  local dir="$1"
  cat > "$dir/a.md" <<EOF
A single short prose paragraph with a permalink.
${PERMALINK}
EOF
}
run_case "<5 paragraphs is N/A" 0 "need ≥5 for a meaningful ratio" fx_tiny

# PASS: every paragraph has a near permalink.
fx_pass() {
  local dir="$1" i
  for i in 1 2 3 4 5 6; do
    cat > "$dir/p${i}.md" <<EOF
Paragraph ${i} body line one.
Paragraph ${i} body line two.

${PERMALINK}
EOF
  done
}
run_case "all-covered PASS" 0 "[PASS] permalink-density" fx_pass

# FAIL: 6 paragraphs, only 1 covered.
fx_fail() {
  local dir="$1" i
  cat > "$dir/covered.md" <<EOF
Covered paragraph here.
${PERMALINK}
EOF
  for i in 1 2 3 4 5; do
    cat > "$dir/u${i}.md" <<EOF
Uncovered paragraph ${i} without any permalink nearby.
Just narrative prose.
EOF
  done
}
run_case "low-coverage FAIL" 1 "[FAIL] permalink-density" fx_fail

# Coverage rules across files. (a) covered by same-line permalink; (b)
# covered by permalink 4 lines after end of paragraph; (c) uncovered:
# permalink 6 lines after end (outside window); (d) uncovered: only an
# unpinned blob/main URL nearby; (e) covered by tag-pinned URL.
fx_windowing() {
  local dir="$1"
  cat > "$dir/a-same-line.md" <<EOF
Paragraph A body, with ${PERMALINK} on the same line.
EOF
  cat > "$dir/b-within-window.md" <<EOF
Paragraph B body line one.
Paragraph B body line two.



${PERMALINK}
EOF
  cat > "$dir/c-outside-window.md" <<EOF
Paragraph C body line one.






${PERMALINK}
EOF
  cat > "$dir/d-main-only.md" <<EOF
Paragraph D body line one.

${MAIN_URL}
EOF
  cat > "$dir/e-tag-pinned.md" <<EOF
Paragraph E body line one.
${TAG_PERMALINK}
EOF
}
# 5 paragraphs A-E. A/B/E covered (3); C/D uncovered (2). 3/5 = 60% → FAIL.
run_case "windowing rules FAIL" 1 "[FAIL] permalink-density" fx_windowing

# Non-prose lines must be excluded from paragraph counts. Build a file
# whose only "prose" sections are unambiguous so we can predict the count.
fx_exclusions() {
  local dir="$1"
  cat > "$dir/excl.md" <<EOF
# Heading line

\`\`\`
code in a fence
multiple lines
\`\`\`

| col1 | col2 |
| --- | --- |
| a | b |

- bullet item one
- bullet item two
  continuation of bullet two

> blockquote line one
> blockquote line two

<!-- HTML comment line -->

Real prose paragraph one.
${PERMALINK}

Real prose paragraph two.
${PERMALINK}

Real prose paragraph three.
${PERMALINK}

Real prose paragraph four.
${PERMALINK}

Real prose paragraph five.
${PERMALINK}
EOF
}
run_case "exclusions handled, all covered PASS" 0 "[PASS] permalink-density" fx_exclusions

# HTML comments (single-line and multi-line) are excluded from paragraph
# detection by contract. If the script counted them, this fixture's 5 prose
# paragraphs would be inflated and might still PASS — the key signal is
# that the count stays at 5 and all 5 are covered.
fx_html_comments() {
  local dir="$1"
  cat > "$dir/html-comments.md" <<EOF
<!-- single-line html comment that should be skipped -->

Real prose paragraph one.
${PERMALINK}

<!--
multi-line html comment
spanning several lines
that all need to be skipped
-->

Real prose paragraph two.
${PERMALINK}

Real prose paragraph three.
${PERMALINK}

Real prose paragraph four.
${PERMALINK}

Real prose paragraph five.
${PERMALINK}
EOF
}
run_case "html comments excluded PASS" 0 "[PASS] permalink-density" fx_html_comments

# Leading frontmatter block (--- ... ---) is excluded from paragraph
# detection by contract. Same signal as the HTML-comment case: count of
# in-scope paragraphs should be exactly 5 and all covered.
fx_frontmatter() {
  local dir="$1"
  cat > "$dir/frontmatter.md" <<EOF
---
name: example
description: example reference with frontmatter
key: value
---

Real prose paragraph one.
${PERMALINK}

Real prose paragraph two.
${PERMALINK}

Real prose paragraph three.
${PERMALINK}

Real prose paragraph four.
${PERMALINK}

Real prose paragraph five.
${PERMALINK}
EOF
}
run_case "frontmatter excluded PASS" 0 "[PASS] permalink-density" fx_frontmatter

# Directory-form references (per 02-artifact-contract.md § "Optional
# directory form for multimodal references") live one level deeper
# under references/. The lint must walk recursively via rglob; a flat
# glob would silently skip them.
fx_recursive() {
  local dir="$1"
  mkdir -p "$dir/dir-form"
  cat > "$dir/dir-form/primary.md" <<EOF
Primary reference paragraph one.
${PERMALINK}

Primary reference paragraph two.
${PERMALINK}

Primary reference paragraph three.
${PERMALINK}
EOF
  cat > "$dir/dir-form/sidecar.md" <<EOF
Sidecar reference paragraph one.
${PERMALINK}

Sidecar reference paragraph two.
${PERMALINK}
EOF
}
run_case "recursive walk under references/ PASS" 0 "[PASS] permalink-density" fx_recursive

# A line that is ONLY a bare permalink is a citation, not prose. It must not
# count as its own self-covering paragraph nor pad the denominator. Here 5
# link-less prose paragraphs plus 1 isolated bare-permalink line (>5 lines
# from any prose): true coverage is 0/5. The pre-fix code reported 1/6 (the
# link line self-covering). Assert the corrected 0/5.
fx_bare_permalink_not_prose() {
  local dir="$1"
  cat > "$dir/bare.md" <<EOF
Narrative paragraph one with no link.

Narrative paragraph two with no link.

Narrative paragraph three with no link.

Narrative paragraph four with no link.

Narrative paragraph five with no link.







${PERMALINK}
EOF
}
run_case "bare-permalink line is not a covered paragraph" 1 "(0/5 paragraphs)" fx_bare_permalink_not_prose

# A code fence whose opener is preceded by an inline HTML comment on the same
# line ("<!-- note --> \`\`\`python"). After the comment is stripped the fence
# is left indented by one space; the pre-fix ^-anchored FENCE_RE missed it and
# counted the code body as uncovered prose (FAIL). With leading-whitespace
# tolerance the fence is detected, the body is skipped, and the 5 covered prose
# paragraphs PASS.
fx_inline_comment_then_fence() {
  local dir="$1"
  cat > "$dir/fence.md" <<EOF
Real prose paragraph one.
${PERMALINK}

Real prose paragraph two.
${PERMALINK}

Real prose paragraph three.
${PERMALINK}

Real prose paragraph four.
${PERMALINK}

Real prose paragraph five.
${PERMALINK}

<!-- example --> \`\`\`python
this_is_code = "not prose"
more_code()
\`\`\`
EOF
}
run_case "inline-comment-then-fence is skipped" 0 "[PASS] permalink-density" fx_inline_comment_then_fence

# A comment that closes and re-opens on one line ("end --> <!-- start"). The
# re-opened comment body must stay skipped; the pre-fix code dropped comment
# state at the first --> and scanned the rest as prose (uncovered → FAIL).
fx_close_then_reopen_comment() {
  local dir="$1"
  cat > "$dir/reopen.md" <<EOF
Real prose paragraph one.
${PERMALINK}

Real prose paragraph two.
${PERMALINK}

Real prose paragraph three.
${PERMALINK}

Real prose paragraph four.
${PERMALINK}

Real prose paragraph five.
${PERMALINK}

<!--
commented line A
end first --> <!-- start second
commented line B that must stay skipped
-->
EOF
}
run_case "close-then-reopen comment stays skipped" 0 "[PASS] permalink-density" fx_close_then_reopen_comment

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
