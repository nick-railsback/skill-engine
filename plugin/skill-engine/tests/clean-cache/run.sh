#!/usr/bin/env bash
# Feature-scoped test runner for the clean-cache workflow.
# Builds a fake $XDG_CACHE_HOME/skill-engine cache tree, runs the dry-run
# bash from clean-cache/SKILL.md against it, and asserts the entries
# listed under the chosen [kind] match expectations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass_count=0
fail_count=0

# Build a fake cache tree under a tmp XDG_CACHE_HOME, then run the
# clean-cache "list eligible directories" snippet (NOT the rm; dry-run
# only) and capture the list of directories it would propose to delete.
#
# Args: 1=kind-arg ("" | "git-managed" | "web-doc"), 2=expected-entries
#       (newline-separated relative-from-cache-root, sorted)
run_one() {
  local kind_arg="$1" expected_entries="$2"
  local label="${3:-kind=${kind_arg:-<omitted>}}"
  local tmphome
  tmphome="$(mktemp -d -t skill-engine-cc-test.XXXXXX)"

  # Populate fixture tree (current kind-partitioned layout + one flat-legacy entry).
  mkdir -p \
    "$tmphome/skill-engine/git-managed/vitejs-vite-aaaa1111" \
    "$tmphome/skill-engine/git-managed/django-django-cccc3333" \
    "$tmphome/skill-engine/web-doc/anthropic-docs-bbbb2222" \
    "$tmphome/skill-engine/legacy-flat-dddd4444"
  # Leaf files so du reports >0.
  for d in "$tmphome/skill-engine/git-managed/vitejs-vite-aaaa1111" \
           "$tmphome/skill-engine/git-managed/django-django-cccc3333" \
           "$tmphome/skill-engine/web-doc/anthropic-docs-bbbb2222" \
           "$tmphome/skill-engine/legacy-flat-dddd4444"; do
    printf 'x' > "$d/.touch"
  done

  # Run the dry-run enumerator. clean-cache/SKILL.md emits the listing as
  # the script; we invoke a thin shim here that mirrors the workflow's
  # globbing logic. Once Task 1.2 lands, this shim will dispatch on
  # $kind_arg to the kind-scoped path.
  local actual
  actual="$(XDG_CACHE_HOME="$tmphome" SKILL_ENGINE_CLEAN_CACHE_KIND="$kind_arg" \
    bash "$SCRIPT_DIR/dry-run-shim.sh" \
    | awk 'NF { print $1 }' \
    | grep -v '^Directory$' \
    | grep -v '^---' \
    | sort)"

  if [ "$actual" = "$expected_entries" ]; then
    printf '  PASS  %s\n' "$label"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %s\n        expected:\n%s\n        actual:\n%s\n' \
      "$label" "$expected_entries" "$actual"
    fail_count=$((fail_count + 1))
  fi
  rm -rf "$tmphome"
}

# Test cases: filled in by Task 1.2 once the [kind] arg is implemented.

expected_all="$(printf '%s\n' \
  'git-managed/django-django-cccc3333' \
  'git-managed/vitejs-vite-aaaa1111' \
  'legacy-flat-dddd4444' \
  'web-doc/anthropic-docs-bbbb2222' | sort)"
run_one "" "$expected_all" "kind=<omitted>"

expected_gm="$(printf '%s\n' \
  'git-managed/django-django-cccc3333' \
  'git-managed/vitejs-vite-aaaa1111' | sort)"
run_one "git-managed" "$expected_gm" "kind=git-managed"

expected_wd="$(printf '%s\n' \
  'web-doc/anthropic-docs-bbbb2222' | sort)"
run_one "web-doc" "$expected_wd" "kind=web-doc"

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
