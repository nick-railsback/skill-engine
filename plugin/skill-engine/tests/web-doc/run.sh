#!/usr/bin/env bash
# Feature-scoped test runner for the web-doc source kind.
# For each fixture, set up a minimal contextualizer skeleton, drop the
# fixture into it, run verify.sh, and assert pass/fail with the expected
# message substring (encoded in the invalid fixture's sidecar .expect file).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY_SH="$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

pass_count=0
fail_count=0

# Sweep tmpdirs on exit, in case any function-local cleanup didn't run
# (e.g., the runner aborted via 'set -e' mid-function).
cleanup_tmp() {
  rm -rf "${TMPDIR:-/tmp}"/skill-engine-{test,frontmatter,smoke,escape}.* 2>/dev/null || true
}
trap cleanup_tmp EXIT

# Build a temp contextualizer for one fixture and run verify.sh against it.
# Args: 1=fixture-path, 2=expect (pass|fail), 3=expected-substring (only for fail)
run_one() {
  local fixture="$1" expect="$2" expected_substr="${3:-}"
  local ctx_root
  ctx_root="$(mktemp -d -t skill-engine-test.XXXXXX)"

  mkdir -p "$ctx_root/research" "$ctx_root/references"
  cat > "$ctx_root/SKILL.md" <<'EOF'
---
name: test-context
description: When user asks for test-context. Test-only fixture.
---
# Test
EOF
  printf '{"schema_version": 1}\n' > "$ctx_root/research/.research-state.json"
  cp "$fixture" "$ctx_root/research/source-paths.json"

  local out rc
  out="$(CTX_ROOT="$ctx_root" bash "$VERIFY_SH" 2>&1)" && rc=0 || rc=$?

  if [ "$expect" = "pass" ]; then
    if [ "$rc" -eq 0 ]; then
      printf '  PASS  %s\n' "${fixture##*/}"
      pass_count=$((pass_count + 1))
    else
      printf '  FAIL  %s\n        Expected pass, got rc=%d\n%s\n' \
        "${fixture##*/}" "$rc" "$out"
      fail_count=$((fail_count + 1))
    fi
  else
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF -- "$expected_substr"; then
      printf '  PASS  %s\n' "${fixture##*/}"
      pass_count=$((pass_count + 1))
    else
      printf '  FAIL  %s\n        Expected fail with substring %q, got rc=%d\n%s\n' \
        "${fixture##*/}" "$expected_substr" "$rc" "$out"
      fail_count=$((fail_count + 1))
    fi
  fi
  rm -rf "$ctx_root"
}

run_frontmatter() {
  local fixture="$1" expect="$2" expected_substr="${3:-}"
  local ctx_root
  ctx_root="$(mktemp -d -t skill-engine-frontmatter.XXXXXX)"

  mkdir -p "$ctx_root/research" "$ctx_root/references" "$ctx_root/external-fixtures"
  cat > "$ctx_root/SKILL.md" <<'EOF'
---
name: test-context
description: When user asks for test-context. Test fixture.
---
# Test
EOF
  printf '{"schema_version": 1}\n' > "$ctx_root/research/.research-state.json"
  cat > "$ctx_root/research/source-paths.json" <<'EOF'
{ "schema_version": 1, "sources": [
  { "id": "ext", "kind": "external-doc", "path": "external-fixtures", "status": "confirmed", "lifecycle": {"state":"reachable"} }
]}
EOF
  cp "$fixture" "$ctx_root/external-fixtures/$(basename "$fixture")"

  local out rc
  out="$(CTX_ROOT="$ctx_root" bash "$VERIFY_SH" 2>&1)" && rc=0 || rc=$?

  if [ "$expect" = "pass" ]; then
    if [ "$rc" -eq 0 ]; then
      printf '  PASS  %s\n' "${fixture##*/}"
      pass_count=$((pass_count + 1))
    else
      printf '  FAIL  %s\n        Expected pass, got rc=%d\n%s\n' \
        "${fixture##*/}" "$rc" "$out"
      fail_count=$((fail_count + 1))
    fi
  else
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF -- "$expected_substr"; then
      printf '  PASS  %s\n' "${fixture##*/}"
      pass_count=$((pass_count + 1))
    else
      printf '  FAIL  %s\n        Expected fail with substring %q, got rc=%d\n%s\n' \
        "${fixture##*/}" "$expected_substr" "$rc" "$out"
      fail_count=$((fail_count + 1))
    fi
  fi
  rm -rf "$ctx_root"
}

# Schema fixtures: valid ones must pass, invalid ones must fail with the
# substring in the fixture's sidecar `.expect` file.
for f in "$FIXTURES"/schema/valid/*.json; do
  [ -f "$f" ] || continue
  run_one "$f" pass
done
for f in "$FIXTURES"/schema/invalid/*.json; do
  [ -f "$f" ] || continue
  expect_file="${f%.json}.expect"
  if [ ! -f "$expect_file" ]; then
    printf '  FAIL  %s\n        Missing sidecar %s\n' "${f##*/}" "${expect_file##*/}"
    fail_count=$((fail_count + 1))
    continue
  fi
  expected_substr="$(cat "$expect_file")"
  run_one "$f" fail "$expected_substr"
done

for f in "$FIXTURES"/frontmatter/valid/*.md; do
  [ -f "$f" ] || continue
  run_frontmatter "$f" pass
done
for f in "$FIXTURES"/frontmatter/invalid/*.md; do
  [ -f "$f" ] || continue
  expect_file="${f%.md}.expect"
  if [ ! -f "$expect_file" ]; then
    printf '  FAIL  %s\n        Missing sidecar %s\n' "${f##*/}" "${expect_file##*/}"
    fail_count=$((fail_count + 1))
    continue
  fi
  expected_substr="$(cat "$expect_file")"
  run_frontmatter "$f" fail "$expected_substr"
done

# Symlink-escape test: an external-doc path containing a symlink that
# points outside the contextualizer must not be walked by the
# external-doc-frontmatter check (Check 5.5).
escape_root="$(mktemp -d -t skill-engine-escape.XXXXXX)"
mkdir -p "$escape_root/research" "$escape_root/external-fixtures" "$escape_root/outside"
cat > "$escape_root/SKILL.md" <<'EOF'
---
name: escape-test
description: Escape test context
---
# Escape test
EOF
printf '{"schema_version": 1}\n' > "$escape_root/research/.research-state.json"
cat > "$escape_root/research/source-paths.json" <<'EOF'
{ "schema_version": 1, "sources": [
  { "id": "ext", "kind": "external-doc", "path": "external-fixtures",
    "status": "confirmed", "lifecycle": {"state":"reachable"} }
]}
EOF

# A valid frontmatter file inside the external-doc path (should be walked).
cat > "$escape_root/external-fixtures/inside.md" <<'EOF'
---
source_url: https://example.com/inside
crawl_date: 2026-05-19T00:00:00Z
decay: 30d
---
# Inside
EOF

# A file *outside* the contextualizer with BAD frontmatter (no source_url).
# If the symlink is followed and containment is not enforced, Check 5.5
# will fail on this file with "frontmatter source_url missing or fails regex".
cat > "$escape_root/outside/escaped.md" <<'EOF'
---
crawl_date: 2026-05-19T00:00:00Z
decay: 30d
---
# Escaped
EOF
ln -s "$escape_root/outside" "$escape_root/external-fixtures/link"

escape_out="$(CTX_ROOT="$escape_root" bash "$VERIFY_SH" 2>&1)" || true
if printf '%s' "$escape_out" | grep -qF 'escaped.md frontmatter source_url missing'; then
  printf '  FAIL  symlink-escape: Check 5.5 walked into a symlink that escapes CTX_ROOT\n'
  fail_count=$((fail_count + 1))
else
  printf '  PASS  symlink-escape: Check 5.5 declined to walk outside CTX_ROOT\n'
  pass_count=$((pass_count + 1))
fi
# Positive control: the absence assertion above passes vacuously if the
# containment guard is deleted or its failure message reworded — so also
# assert Check 5.5 actually ran and counted exactly the one in-tree file
# (inside.md), proving the walk happened and stopped at the boundary.
if printf '%s' "$escape_out" | grep -qF '1 provenance file(s) with valid frontmatter'; then
  printf '  PASS  symlink-escape positive control: Check 5.5 counted the in-tree file\n'
  pass_count=$((pass_count + 1))
else
  printf '  FAIL  symlink-escape positive control: expected exactly 1 provenance file counted\n%s\n' "$escape_out"
  fail_count=$((fail_count + 1))
fi
rm -rf "$escape_root"

# Manifest schema assertion: the expected-snapshot fixture's
# _crawl-manifest.json must satisfy the prose contract in
# engine-bootstrap/SKILL.md. Pin: required keys + types.
manifest="$FIXTURES/expected-snapshot/_crawl-manifest.json"
if [ -f "$manifest" ] && jq -e '
  (.source_id | type) == "string"
  and (.crawl_id | type) == "string"
  and (.crawl_date | type) == "string"
  and (.fetcher | type) == "string"
  and (.sitemap_source | type) == "string"
  and (.pages | type) == "array"
  and (.pages | length > 0)
  and (.pages | all(
    (.url | type) == "string"
    and (.file | type) == "string"
    and (.content_hash | type) == "string"
    and (.bytes | type) == "number"
  ))
  and (.failures | type) == "array"
  and (.robots_disallows | type) == "array"
  and (.budget_truncated | type) == "number"
' "$manifest" >/dev/null 2>&1; then
  printf '  PASS  _crawl-manifest.json satisfies schema\n'
  pass_count=$((pass_count + 1))
else
  printf '  FAIL  _crawl-manifest.json violates schema:\n%s\n' \
    "$(jq . "$manifest" 2>&1 | head -20)"
  fail_count=$((fail_count + 1))
fi

# Smoke check: the expected-snapshot fixture must itself satisfy the
# external-doc-frontmatter contract.
smoke_root="$(mktemp -d -t skill-engine-smoke.XXXXXX)"
mkdir -p "$smoke_root/research" "$smoke_root/references" "$smoke_root/external-snapshot"
cat > "$smoke_root/SKILL.md" <<'EOF'
---
name: smoke-context
description: Smoke test for expected snapshot fixture
---
# Smoke
EOF
printf '{"schema_version": 1}\n' > "$smoke_root/research/.research-state.json"
cat > "$smoke_root/research/source-paths.json" <<'EOF'
{ "schema_version": 1, "sources": [
  { "id": "smoke", "kind": "external-doc", "path": "external-snapshot",
    "status": "confirmed", "lifecycle": {"state":"reachable"} }
]}
EOF
cp "$FIXTURES"/expected-snapshot/*.md "$smoke_root/external-snapshot/"

smoke_out="$(CTX_ROOT="$smoke_root" bash "$VERIFY_SH" 2>&1)" && smoke_rc=0 || smoke_rc=$?
if [ "$smoke_rc" -eq 0 ]; then
  printf '  PASS  expected-snapshot fixture passes external-doc-frontmatter\n'
  pass_count=$((pass_count + 1))
else
  printf '  FAIL  expected-snapshot fixture failed verify.sh:\n%s\n' "$smoke_out"
  fail_count=$((fail_count + 1))
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
