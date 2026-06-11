#!/usr/bin/env bash
# Single validator entry point: every check .github/workflows/lint.yml runs,
# runnable locally. lint.yml's jobs call the matching subcommand, and the
# /release skill's Phase 5 runs `make ci-local` — one inventory, three
# consumers, no hand-synced transcription to lapse.
#
# Usage: bash scripts/ci-local.sh [shellcheck|json|doctrine|tests|examples|all]
#
# Tool installation is the caller's concern (CI installs in workflow steps);
# this script asserts presence and fails loud — except check-jsonschema,
# which degrades to a pointer when absent locally. In CI ($CI set) the
# degradation is refused: it is pip-pinned there, and a missing binary means
# the install step regressed, not that skipping is acceptable.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' not found on PATH (required for this subcommand)." >&2
    exit 69
  }
}

run_shellcheck() {
  need shellcheck
  need git
  # git ls-files, not find: a CI checkout and a local working copy must
  # agree on the inventory, and find would lint local-only files CI never
  # sees (gitignored or .git/info/exclude'd scratch scripts), breaking
  # `make ci-local` on files that cannot fail CI. --others --exclude-standard
  # adds untracked-but-not-ignored files, which WOULD reach CI once
  # committed. *.sh.template covers the scripts stamped into user repos;
  # -s bash because shellcheck cannot infer a dialect from the .template
  # extension.
  local files
  files=$(git ls-files --cached --others --exclude-standard -- '*.sh' '*.sh.template' | LC_ALL=C sort)
  if [ -z "$files" ]; then
    echo "No shell files found."
    return 0
  fi
  # shellcheck disable=SC2086 # newline-split is intended; repo paths carry no whitespace
  shellcheck -s bash --severity=warning $files
  echo "shellcheck: OK"
}

run_json() {
  need jq
  local paths=(
    ".claude/settings.json"
    ".claude-plugin/marketplace.json"
    "plugin/skill-engine/.claude-plugin/plugin.json"
    "plugin/skill-engine/engine-bootstrap-templates/research-state.json.template"
    "plugin/skill-engine/engine-bootstrap-templates/source-paths.json.template"
    "plugin/skill-engine/engine-bootstrap-templates/monorepo-config.json.template"
  )
  local f
  for f in "${paths[@]}"; do
    if [ -f "$f" ]; then
      echo "Validating $f"
      jq empty "$f"
    else
      echo "Skipping $f (not present)"
    fi
  done

  local schema="plugin/skill-engine/engine-bootstrap-templates/source-paths.schema.json"
  if ! command -v check-jsonschema >/dev/null 2>&1; then
    if [ -n "${CI:-}" ]; then
      echo "ERROR: check-jsonschema not on PATH in CI — the pip install step regressed." >&2
      echo "       Schema meta-validation, target validation, and the negative-fixture gate must not be skipped here." >&2
      exit 69
    fi
    echo "NOTE: check-jsonschema not on PATH — skipping schema validation locally." >&2
    echo "      CI runs it (pip install check-jsonschema==0.37.2); install it to match CI exactly." >&2
    return 0
  fi
  echo "Meta-validating the schema"
  check-jsonschema --check-metaschema "$schema"
  local targets=( "plugin/skill-engine/engine-bootstrap-templates/source-paths.json.template" )
  for f in examples/*/research/source-paths.json; do
    [ -f "$f" ] && targets+=( "$f" )
  done
  echo "Validating ${#targets[@]} file(s) against the schema in one pass"
  check-jsonschema --schemafile "$schema" "${targets[@]}"

  # Invalid fixtures must FAIL the schema — the tested half of the
  # schema↔verify.sh equivalence claim. One declared gap: page_list
  # same-origin is not expressible in JSON Schema (see the schema's
  # description); only verify.sh enforces it.
  local bad=0
  for f in plugin/skill-engine/tests/web-doc/fixtures/schema/invalid/*.json; do
    case "$(basename "$f")" in
      invalid--page-list-cross-origin.json)
        echo "skipped (declared schema gap): $f"
        continue ;;
    esac
    if check-jsonschema --schemafile "$schema" "$f" >/dev/null 2>&1; then
      echo "FAIL: invalid fixture passed schema validation: $f"
      bad=1
    else
      echo "rejected as expected: $f"
    fi
  done
  return "$bad"
}

run_doctrine() {
  bash plugin/skill-engine/tests/doctrine.sh
}

run_tests() {
  need jq
  # The loop, not a hand-enumerated list: a new tests/<name>/run.sh is
  # included automatically instead of being green-by-omission.
  local t
  for t in plugin/skill-engine/tests/*/run.sh; do
    echo "== $t =="
    bash "$t"
  done
  echo "== plugin/skill-engine/tests/hooks-audit.sh =="
  bash plugin/skill-engine/tests/hooks-audit.sh
}

run_examples() {
  need python3
  local v refs ctx
  for v in examples/*/verify.sh; do
    echo "== $v =="
    bash "$v"
  done
  for refs in examples/*/references; do
    [ -d "$refs" ] || continue
    echo "== permalink density: $refs =="
    # No --threshold: the bar is single-sourced as DEFAULT_COVERAGE_THRESHOLD
    # in permalink_density.py; re-stating it here is where drift would start.
    python3 plugin/skill-engine/tests/permalink_density.py "$refs" --min-paragraphs 5 --require-min-paragraphs
  done
  for ctx in examples/*/; do
    [ -f "$ctx/research/eval-prompts.json" ] || continue
    echo "== eval corpus dry-run: $ctx =="
    python3 plugin/skill-engine/tests/grounded_rate.py "$ctx" --dry-run
  done
}

cmd="${1:-all}"
case "$cmd" in
  shellcheck) run_shellcheck ;;
  json)       run_json ;;
  doctrine)   run_doctrine ;;
  tests)      run_tests ;;
  examples)   run_examples ;;
  all)
    run_shellcheck
    run_json
    run_doctrine
    run_tests
    run_examples
    echo "ci-local: all suites passed."
    ;;
  *)
    echo "usage: $0 [shellcheck|json|doctrine|tests|examples|all]" >&2
    exit 64
    ;;
esac
