#!/usr/bin/env bash
# The navigator-frontmatter gate (verify.sh Check 3), read in isolation.
#
# Sourced, not run. The caller sets VERIFY_SH to the checker under test,
# which is the template by default in every suite and a scratch copy when a
# mutation control points the suite at one.
#
# A verdict is read from the checker's own `(navigator-skill)` section over
# a scratch contextualizer root, never from its exit code: every other check
# in the file also moves that, and a fixture this small reaches later
# checks that report on their own terms. How the section is isolated lives
# here and only here.

# nav_gate_report <contextualizer-root> — the navigator-frontmatter check's
# own section of a verify run over that root.
nav_gate_report() {
  local root cache out
  root="$1"
  cache="$(mktemp -d)"
  out="$(CTX_ROOT="$root" SKILL_ENGINE_CACHE_ROOT="$cache" bash "$VERIFY_SH" 2>&1)"
  rm -rf "$cache"
  printf '%s\n' "$out" | awk '
    index($0, "(navigator-skill)") > 0 && !found { found = 1; print; next }
    found && /^=== / { exit }
    found { print }
  '
}

# gate_case <frontmatter-body> — "accept", "reject" or "unreadable", from a
# scratch contextualizer whose navigator frontmatter is exactly those lines.
gate_case() {
  local root report
  root="$(mktemp -d)"
  mkdir -p "$root/research"
  {
    printf -- '---\n'
    printf '%s\n' "$1"
    printf -- '---\n\n# Acme\n'
  } > "$root/SKILL.md"
  printf '{"schema_version": 1, "sources": []}\n' > "$root/research/source-paths.json"
  report="$(nav_gate_report "$root")"
  rm -rf "$root"
  if [ -z "$report" ]; then
    printf 'unreadable'
  elif printf '%s\n' "$report" | grep -q '\[FAIL\]'; then
    printf 'reject'
  else
    printf 'accept'
  fi
}
