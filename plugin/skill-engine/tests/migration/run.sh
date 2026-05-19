#!/usr/bin/env bash
# Feature-scoped test runner for the REFRESH cache-layout migration
# detector (pre-flight step 1.5 in refresh/SKILL.md). Asserts that:
#   - A flat-layout git clone at the cache root is detected.
#   - A future-kind subdirectory (e.g. local-path/) is NOT detected.
#   - A non-git directory at the cache root is NOT detected.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass_count=0
fail_count=0

run_case() {
  local label="$1" expected="$2"
  shift 2
  local cache
  cache="$(mktemp -d -t skill-engine-mig.XXXXXX)"
  # The remaining args are "name:gitmarker" pairs; gitmarker=g means create .git/HEAD.
  while [ $# -gt 0 ]; do
    local pair="$1"; shift
    local name="${pair%%:*}"
    local marker="${pair#*:}"
    mkdir -p "$cache/$name"
    if [ "$marker" = "g" ]; then
      mkdir -p "$cache/$name/.git"
      printf 'ref: refs/heads/main\n' > "$cache/$name/.git/HEAD"
    fi
  done
  local detected
  detected="$(SKILL_ENGINE_CACHE_ROOT="$cache" bash "$SCRIPT_DIR/detect-flat-shim.sh" | sort)"
  if [ "$detected" = "$expected" ]; then
    printf '  PASS  %s\n' "$label"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %s\n        expected:\n%s\n        actual:\n%s\n' \
      "$label" "$expected" "$detected"
    fail_count=$((fail_count + 1))
  fi
  rm -rf "$cache"
}

# Existing top-level dirs that ARE kinds.
run_case "git-managed/ subdir is not flat-layout" "" "git-managed:n"
run_case "web-doc/ subdir is not flat-layout" "" "web-doc:n"

# Flat-layout git-managed clone at cache root.
run_case "flat-layout git clone is detected" "vitejs-vite-aaaa1111" "vitejs-vite-aaaa1111:g"

# Future kind directory (local-path) at cache root — must NOT be classified as flat.
run_case "future kind dir (local-path) is not flat-layout" "" "local-path:n"

# Non-git plain dir at cache root — must NOT be classified as flat.
run_case "non-git plain dir is not flat-layout" "" "stray-dir:n"

# Mixed: flat + future-kind.
expected_mixed="vitejs-vite-aaaa1111"
run_case "mixed flat+future-kind detects only the flat one" "$expected_mixed" \
  "vitejs-vite-aaaa1111:g" "local-path:n"

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
