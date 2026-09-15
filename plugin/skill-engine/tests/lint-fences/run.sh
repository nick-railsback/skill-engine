#!/usr/bin/env bash
# Oracle for `scripts/lint-fences.sh` — the gate that reads the executable
# code shipping inside SKILL Markdown.
#
# THE INVARIANTS.
#   planted defects caught — a shell fence carrying SC2155 or SC2164, and a
#                     python fence that does not parse, each make the linter
#                     exit non-zero and name the shellcheck code or the
#                     syntax error.
#   placeholders survive — `<name>`-style placeholders are substituted, not
#                     read as redirections, and two DIFFERENT placeholders
#                     become two different values. Collapsing them to one
#                     shared token would make `<old_sha>` and `<new_sha>`
#                     compare equal, and any check written on that
#                     comparison would quietly stop meaning anything.
#   redirections survive — `cmd <in >out` and `cat <<EOF >out` are shell,
#                     not placeholders, and must come through untouched.
#   the tracked tree is clean — the linter run over the real inventory
#                     passes, which is what makes the fixture's failure a
#                     statement about the fixture.
#   wired in         — `scripts/ci-local.sh` runs it, so the gate is part of
#                     `make ci-local` and of what lint.yml runs, rather than
#                     a script nothing calls.
#   fixtures excluded — the default inventory skips `tests/*/fixtures/`, or
#                     this suite's own planted fixture would take
#                     `make ci-local` red.
#
# -e is intentionally omitted: every assertion runs and reports.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

LINTER="$REPO_ROOT/scripts/lint-fences.sh"
CI_LOCAL="$REPO_ROOT/scripts/ci-local.sh"
PLANTED="$SCRIPT_DIR/fixtures/planted.md"

pass_count=0
fail_count=0

report() {
  local ok="$1" name="$2"
  shift 2
  if [ "$ok" -eq 1 ]; then
    printf '  PASS  %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %s\n' "$name"
    local why
    for why in "$@"; do
      [ -n "$why" ] && printf '        %s\n' "$why"
    done
    fail_count=$((fail_count + 1))
  fi
}

fixture_error() {
  printf '  FAIL  fixture error: %s\n' "$1"
  fail_count=$((fail_count + 1))
}

for f in "$LINTER" "$CI_LOCAL" "$PLANTED"; do
  [ -s "$f" ] || fixture_error "a file under test is missing or empty: $f"
done

if ! command -v shellcheck >/dev/null 2>&1; then
  fixture_error "shellcheck is not on PATH; the gate cannot be exercised"
elif ! command -v python3 >/dev/null 2>&1; then
  fixture_error "python3 is not on PATH; the gate cannot be exercised"
else
  # ── the planted fixture is caught, and for the stated reasons ─────────
  PLANTED_OUT="$(bash "$LINTER" "$PLANTED" 2>&1)"
  PLANTED_RC=$?

  ok=1
  [ "$PLANTED_RC" -ne 0 ] || ok=0
  report "$ok" "a Markdown file carrying broken fences fails the gate" \
    "exit $PLANTED_RC"

  ok=1
  printf '%s' "$PLANTED_OUT" | grep -q 'SC2155' || ok=0
  report "$ok" "the SC2155 the review found in STATUS's fleet section is reported" \
    "$(printf '%s' "$PLANTED_OUT" | tr '\n' '~')"

  ok=1
  printf '%s' "$PLANTED_OUT" | grep -q 'SC2164' || ok=0
  report "$ok" "an unguarded \`cd\` in a fenced block is reported"

  ok=1
  printf '%s' "$PLANTED_OUT" | grep -qiE 'syntax|SyntaxError' || ok=0
  report "$ok" "a python fence that does not parse is reported"

  # ── what must NOT be reported, so the gate is usable at all ───────────
  # Distinctness is read off the line shellcheck echoes back. Substituting
  # every placeholder to ONE token would make two different placeholders
  # compare equal, and any check built on that comparison would silently
  # stop meaning anything.
  ok=1
  printf '%s' "$PLANTED_OUT" | grep -q 'PLACEHOLDER_old_sha' || ok=0
  printf '%s' "$PLANTED_OUT" | grep -q 'PLACEHOLDER_new_sha' || ok=0
  report "$ok" "two different placeholders become two different values, not one shared token" \
    "$(printf '%s' "$PLANTED_OUT" | grep -i 'placeholder' | tr '\n' '~')"

  ok=1
  printf '%s' "$PLANTED_OUT" | grep -qE 'SC107[23]|SC1064|SC226[01]' && ok=0
  report "$ok" "a placeholder is substituted rather than parsed as a redirection" \
    "$(printf '%s' "$PLANTED_OUT" | grep -E 'SC107[23]|SC1064|SC226[01]' | tr '\n' '~')"

  ok=1
  printf '%s' "$PLANTED_OUT" | grep -qE 'SC2188|SC2217|SC2227' && ok=0
  report "$ok" "a real redirection — \`<in >out\`, and a heredoc redirected to a file — survives the placeholder rewrite" \
    "$(printf '%s' "$PLANTED_OUT" | grep -E 'SC2188|SC2217|SC2227' | tr '\n' '~')"

  # ── the tracked tree passes, which is what makes the above mean
  #    something rather than reporting that everything fails ────────────
  TREE_OUT="$(cd "$REPO_ROOT" && bash "$LINTER" 2>&1)"
  TREE_RC=$?
  ok=1
  [ "$TREE_RC" -eq 0 ] || ok=0
  report "$ok" "every fenced block in the tracked tree passes the gate" \
    "$(printf '%s' "$TREE_OUT" | tr '\n' '~')"

  # It really did read something: a gate whose inventory is empty passes
  # everything.
  ok=1
  printf '%s' "$TREE_OUT" | grep -qE '[0-9]+ shell' || ok=0
  case "$(printf '%s' "$TREE_OUT" | sed -n 's/.*OK (\([0-9]*\) shell.*/\1/p')" in
    ''|0) ok=0 ;;
  esac
  report "$ok" "the gate's default inventory is not empty" \
    "$(printf '%s' "$TREE_OUT" | tr '\n' '~')"

  # ── the planted fixture is not in that inventory ─────────────────────
  ok=1
  printf '%s' "$TREE_OUT" | grep -q 'planted' && ok=0
  report "$ok" "the default inventory excludes tests/*/fixtures/, so this suite's own fixture cannot fail the build"
fi

# ── the gate is wired into the one validator entry point ───────────────
ok=1
grep -q 'lint-fences.sh' "$CI_LOCAL" || ok=0
report "$ok" "scripts/ci-local.sh runs the gate, so it is part of \`make ci-local\` and of lint.yml"

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
