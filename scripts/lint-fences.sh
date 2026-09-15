#!/usr/bin/env bash
# Lint the executable code that ships inside SKILL Markdown.
#
# WHY THIS EXISTS. The engine's workflows are prose an agent executes, and
# a growing share of them are fenced blocks the prose instructs it to run
# verbatim: the shared locator, STATUS's fleet-row derivation, `review`'s
# disagreement budget and catalog grouper, the bootstrap CODEOWNERS seed.
# `scripts/ci-local.sh`'s shellcheck inventory is extension-based —
# `*.sh` and `*.sh.template` — so none of it was read by any gate. Code
# that decides what a user sees, held to no standard at all because of the
# file extension it happens to live in.
#
# WHAT IT LINTS. Every ```bash / ```sh fence in tracked Markdown under
# `plugin/skill-engine/`, plus the two custom tags this repo invented for
# runnable blocks, ```budget-rule and ```group-rule. ```python fences get
# a syntax check (`py_compile`), not a lint: a fragment that runs with an
# environment already built cannot be usefully style-checked, but it can
# certainly be un-parseable, and that is worth catching.
#
# WHAT IT DOES NOT LINT, and why:
#
#   - Fixture Markdown under `tests/*/fixtures/`. Those are frozen pins
#     and deliberately-broken inputs; a suite that needs one linted passes
#     its path explicitly (see "Usage" below).
#   - Python inside a `budget-rule` / `group-rule` heredoc. To shellcheck
#     that is a here-document string, and to this script it is shell. The
#     residual is named rather than implied: those two blocks' Python is
#     covered by `tests/review-size-aware/`, which runs them.
#   - Indented four-space blocks. They are Markdown code blocks with no
#     language, frequently elided with "…", and not runnable as written.
#
# TWO ADJUSTMENTS, both properties of the form rather than concessions:
#
#   - `<placeholder>` substitution. These fences are templates: `<name>`,
#     `<area-domain>`, `<old_sha>` are substituted by whoever runs them,
#     and left in place they read to shellcheck as redirections. Each is
#     replaced by a distinct identifier derived from its own name, so two
#     different placeholders stay two different values and a comparison
#     between them does not collapse into a constant.
#   - SC2034 and SC2154 are disabled. A fence is a fragment: it runs in a
#     session where an earlier fence already set `CTX_ROOT`, and it leaves
#     variables behind for a later one. "Appears unused" and "referenced
#     but not assigned" are true of every such block by construction, and
#     are the only two checks that are.
#
# Usage:
#   lint-fences.sh              # every tracked Markdown file in scope
#   lint-fences.sh FILE...      # exactly these files (used by the suite)
#
# Read-only over the repository: writes only inside its own tmpdir.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' not found on PATH (required by lint-fences.sh)." >&2
    exit 69
  }
}

need shellcheck
need python3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lint-fences.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# The inventory. git ls-files, not find, for the same reason
# `ci-local.sh`'s shellcheck step uses it: a CI checkout and a local
# working copy must agree on what gets linted.
files=()
if [ "$#" -gt 0 ]; then
  files=("$@")
else
  while IFS= read -r f; do
    case "$f" in
      plugin/skill-engine/tests/*/fixtures/*) continue ;;
    esac
    files+=("$f")
  done < <(cd "$REPO_ROOT" && git ls-files -- \
    'plugin/skill-engine/*.md' 'plugin/skill-engine/**/*.md' | LC_ALL=C sort)
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "lint-fences: no Markdown files in scope."
  exit 0
fi

# extract <file> <outdir> — one file per fence, named after the source file
# and the fence's ordinal within it, so a diagnostic names something a
# reader can find. Shell fences get a `.sh`, python fences a `.py`.
#
# The placeholder rewrite requires the closing `>` to follow a non-space.
# `<name>` and `<files_of_interest entries...>` qualify; `cmd <in >out` and
# `cat <<EOF > f` do not, so real redirections survive untouched.
extract() {
  awk -v src="$1" -v out="$2" '
    function slugify(s,   t) { t = s; gsub(/[^A-Za-z0-9]/, "_", t); return t }
    function subst(line,   res, head, name, rest) {
      res = ""
      while (match(line, /<[A-Za-z_]([^<> ]|[^<>]*[^<> ])?>/)) {
        head = substr(line, 1, RSTART - 1)
        name = substr(line, RSTART + 1, RLENGTH - 2)
        rest = substr(line, RSTART + RLENGTH)
        res = res head "PLACEHOLDER_" slugify(name)
        line = rest
      }
      return res line
    }
    /^```(bash|sh|budget-rule|group-rule)[[:space:]]*$/ && !inf {
      inf = 1; n++
      dest = out "/" slugify(src) "__fence" n ".sh"
      print "#!/usr/bin/env bash" > dest
      print "# shellcheck disable=SC2034,SC2154 # see lint-fences.sh" > dest
      next
    }
    /^```python[[:space:]]*$/ && !inf {
      inf = 1; n++
      dest = out "/" slugify(src) "__fence" n ".py"
      printf "" > dest
      next
    }
    inf && /^```[[:space:]]*$/ { inf = 0; close(dest); next }
    inf { print subst($0) >> dest }
  ' "$1"
}

count=0
for f in "${files[@]}"; do
  [ -f "$REPO_ROOT/$f" ] || [ -f "$f" ] || {
    echo "ERROR: no such file: $f" >&2
    exit 66
  }
  if [ -f "$REPO_ROOT/$f" ]; then src="$REPO_ROOT/$f"; else src="$f"; fi
  extract "$src" "$WORK"
  count=$((count + 1))
done

shopt -s nullglob
shell_fences=("$WORK"/*.sh)
python_fences=("$WORK"/*.py)
shopt -u nullglob

total=$(( ${#shell_fences[@]} + ${#python_fences[@]} ))
if [ "$total" -eq 0 ]; then
  echo "lint-fences: no executable fences in $count file(s)."
  exit 0
fi

rc=0
if [ "${#shell_fences[@]}" -gt 0 ]; then
  # Same dialect and severity as the tracked-script inventory, so a block
  # is not held to a different standard for living in Markdown.
  shellcheck -s bash --severity=warning "${shell_fences[@]}" || rc=1
fi

for py in "${python_fences[@]}"; do
  python3 -m py_compile "$py" || rc=1
done

if [ "$rc" -eq 0 ]; then
  echo "lint-fences: OK (${#shell_fences[@]} shell, ${#python_fences[@]} python, in $count file(s))."
fi
exit "$rc"
