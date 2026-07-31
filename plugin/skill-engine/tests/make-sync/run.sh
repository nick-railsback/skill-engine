#!/usr/bin/env bash
# Feature-scoped test runner for the `make sync` target.
#
# Builds an isolated tmp-dir fixture that mirrors the repo's relevant
# relative paths (Makefile, the master verify.sh template, and the example
# verify.sh copies), runs `make -C <fixture> sync` against it, and asserts
# byte-identity between the fixture's template and its example copies
# directly (the same thing doctrine.sh's byte-compare check asserts against
# the real tree). Never touches the real repo's Makefile, examples/, or
# engine-bootstrap-templates/, and never depends on whether those happen to
# be in sync when this runs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

SRC_MAKEFILE="$REPO_ROOT/Makefile"
SRC_TEMPLATE="$REPO_ROOT/plugin/skill-engine/engine-bootstrap-templates/verify.sh"
EXAMPLE_NAMES=(
  inspect-ai-context
  langchain-context
  modelcontextprotocol-python-sdk-context
)

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

# Build a fixture tree under a fresh tmp dir: the real Makefile, the real
# template's content, and that same content seeded as every example copy —
# a known, self-consistent starting point that does not depend on whether
# the real repo's examples happen to be in sync right now. Relative paths
# are preserved so a Makefile recipe run from the fixture root behaves the
# same as it would from the real repo root.
build_fixture() {
  local scratch="$1"
  mkdir -p "$scratch/plugin/skill-engine/engine-bootstrap-templates" "$scratch/examples"
  cp "$SRC_MAKEFILE" "$scratch/Makefile"
  cp "$SRC_TEMPLATE" "$scratch/plugin/skill-engine/engine-bootstrap-templates/verify.sh"
  local name
  for name in "${EXAMPLE_NAMES[@]}"; do
    mkdir -p "$scratch/examples/$name"
    cp "$scratch/plugin/skill-engine/engine-bootstrap-templates/verify.sh" \
      "$scratch/examples/$name/verify.sh"
  done
}

fixture_template() {
  printf '%s/plugin/skill-engine/engine-bootstrap-templates/verify.sh' "$1"
}

fixture_example() {
  printf '%s/examples/%s/verify.sh' "$1" "$2"
}

echo "== template edit propagates to every example copy =="
scratch_a="$(mktemp -d -t skill-engine-make-sync.XXXXXX)"
created_dirs+=("$scratch_a")
build_fixture "$scratch_a"
tmpl_a="$(fixture_template "$scratch_a")"
printf '\n# fixture edit %s\n' "$$" >> "$tmpl_a"

sync_out_a="$(make -C "$scratch_a" sync 2>&1)" && sync_rc_a=0 || sync_rc_a=$?
if [ "$sync_rc_a" -ne 0 ]; then
  printf '  (make sync exited %d)\n%s\n' "$sync_rc_a" "$sync_out_a"
fi

for name in "${EXAMPLE_NAMES[@]}"; do
  ex="$(fixture_example "$scratch_a" "$name")"
  if cmp -s "$tmpl_a" "$ex"; then
    printf '  PASS  %s matches edited template after make sync\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %s does not match edited template after make sync\n' "$name"
    fail_count=$((fail_count + 1))
  fi
done

echo
echo "== diverged example copy is corrected =="
scratch_b="$(mktemp -d -t skill-engine-make-sync.XXXXXX)"
created_dirs+=("$scratch_b")
build_fixture "$scratch_b"
tmpl_b="$(fixture_template "$scratch_b")"

# Deliberately diverge every example copy from the template, each a
# different way, before running sync.
ex_inspect="$(fixture_example "$scratch_b" inspect-ai-context)"
printf '# diverged: appended line\n' >> "$ex_inspect"

ex_langchain="$(fixture_example "$scratch_b" langchain-context)"
printf '#!/usr/bin/env bash\n# diverged: entirely different content\n' > "$ex_langchain"

ex_mcp="$(fixture_example "$scratch_b" modelcontextprotocol-python-sdk-context)"
head -c 20 "$tmpl_b" > "$ex_mcp"

# Sanity: fixture setup actually diverged them (guards against a no-op edit
# silently passing below).
for name in "${EXAMPLE_NAMES[@]}"; do
  ex="$(fixture_example "$scratch_b" "$name")"
  if cmp -s "$tmpl_b" "$ex"; then
    printf '  FAIL  %s failed to diverge from template during fixture setup (test bug)\n' "$name"
    fail_count=$((fail_count + 1))
  fi
done

sync_out_b="$(make -C "$scratch_b" sync 2>&1)" && sync_rc_b=0 || sync_rc_b=$?
if [ "$sync_rc_b" -ne 0 ]; then
  printf '  (make sync exited %d)\n%s\n' "$sync_rc_b" "$sync_out_b"
fi

for name in "${EXAMPLE_NAMES[@]}"; do
  ex="$(fixture_example "$scratch_b" "$name")"
  if cmp -s "$tmpl_b" "$ex"; then
    printf '  PASS  %s corrected to match template after make sync\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %s still diverges from template after make sync\n' "$name"
    fail_count=$((fail_count + 1))
  fi
done

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
