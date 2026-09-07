#!/usr/bin/env bash
# Prose-and-executed oracle for many-source bootstrap intake: a file of
# sources (one per line, optional branch column) as an alternative to
# positional arguments or the interactive paste loop, plus a flag that
# answers the per-source "which branch?" question for every source the
# file doesn't already answer.
#
# THE INVARIANTS.
#   - A sources file is intaken as a peer of positional arguments: one
#     entry per non-blank, non-'#'-comment line, an optional second
#     whitespace-separated column names a branch, and file entries and
#     positional entries combine in one invocation with identical kind
#     inference and identical id derivation.
#   - A flag exists that answers the per-source branch question for every
#     git-managed entry the file leaves unanswered, without disturbing
#     what happens to a source that arrives by positional argument, by
#     the interactive paste loop, or by a file entry that already carries
#     its own branch column.
#   - Together, the file and the flag reduce the interactive-prompt
#     surface to exactly one prompt (the contextualizer name) regardless
#     of source count.
#   - A sources file that is unreadable, empty, or all comments, and a
#     line that names neither a URL nor an existing local path, are
#     malformed input: intake must halt before anything is stamped,
#     never proceed on a partial or empty read.
#
# WHY IT MATTERS. Today one prompt fires per git-managed source before a
# single byte is read from any of them; at scale that prompt volume is
# the whole cost of positional/paste-loop intake for a large fleet of
# sources. A file-based intake path only actually helps if it (a)
# genuinely takes over the branch question by default, (b) doesn't
# quietly change the two existing intake forms for the sources that keep
# using them, and (c) doesn't trade "too many prompts" for "silently
# stamps whatever garbage was in the file" — hence the reject list.
#
# THIS IS A PROSE-ONLY SKILL. Bootstrap runs as a model reading SKILL.md
# and its references, not as a program a fixture can invoke — so most of
# this oracle greps the reference for the contract, wrap-normalized
# (collapse newlines/whitespace runs before matching; these are hand-
# wrapped Markdown files, and a naive line-oriented grep silently misses
# any phrase that happens to cross a line break). The one piece that IS
# executable is the file format's own parsing logic: wherever the
# reference carries the sources-file format as a fenced example plus a
# parsing one-liner (awk or shell), this runner extracts that fenced
# block and actually runs it against real fixture files, so the parsing
# and rejection contract is checked against behavior, not only against
# wording. Right now neither flag, no file-format section, and no fenced
# parsing block exists in the reference, so every extraction below comes
# back empty and every assertion — prose and executed alike — fails for
# that reason: the behavior is absent, not the harness broken.
#
# GATING, NOT DROPPING, PRESERVATION CHECKS. Some of the invariants above
# are about NOT changing something already true today (the existing
# positional/paste-loop bullets, the existing per-source branch prompt,
# the router's byte ceiling). Asserting those in isolation right now —
# before any edit — would report a pass for free and prove nothing.
# Every preservation check below is gated on the new surface it is
# preservation ALONGSIDE (the --sources-file flag documented, or the
# --branch-default-all flag documented) being present first; until that
# gate is true the check fails with an explicit "not yet checkable"
# reason instead of a vacuous pass, and once the gate flips true it
# independently verifies the original wording actually survived. Fixture
# self-checks are not reported as passes either: a malformed fixture is
# a harness defect, so it aborts the run with a diagnostic rather than
# printing a green line for scaffolding that isn't the behavior under
# test.
#
# EXECUTION CONVENTION FOR THE EXTRACTED PARSING BLOCK (pinned here
# because nothing upstream pins it yet): the fixture path is substituted
# for a single `<...>`-bracketed placeholder token if the block has
# exactly one; a block with zero such tokens instead receives the
# fixture path as its first positional argument AND the fixture's own
# content on stdin, so a block written either as "read the path I was
# given" or as "read whatever's on stdin" both run. A block with more
# than one distinct placeholder is refused with a diagnostic naming
# them, rather than guessed at. Every invocation runs under
# `set -o pipefail` so a failure earlier in a pipeline (e.g. `cat <path>
# | awk ...` when <path> doesn't exist) is not masked by a later stage's
# own exit code — sufficient for a one-liner's single top-level pipeline
# without imposing `set -e`'s stronger, more surprising whole-script
# abort semantics. Rejection is read off the block's own exit status,
# never off how much or how little it printed — a correct block is free
# to print a full diagnostic on a bad file and that must not itself
# count against it. Whether the sources-file path itself is unreadable
# (as opposed to a bad line inside it) is exercised with a path that
# does not exist at all; a permission-denied variant is a known,
# deliberately-omitted corroboration (root and sandboxed runners make it
# unreliable), not a second must-reject fixture.
#
# FIXTURES. Built fresh in a tmpdir, never committed: two real entries (a
# git URL, a local path) with blank lines in three positions — leading,
# between, and trailing; a second file adding two separate '#'-comment
# lines and a branch column on one entry while leaving the other
# unbranched; an empty file; a comment-only file; a file whose second
# line is neither a URL nor an existing path; and a sources-file path
# that does not exist at all. No single fixture stands in for more than
# one thing at once.
#
# `set -e` is intentionally omitted from this runner itself (a separate
# concern from the substituted-block invocation described above): every
# assertion below must run and report, not abort at the first failing
# one.

set -uo pipefail

# ---------------------------------------------------------------------------
# Setup: locate the repo, load the surfaces under test, prepare a tmpdir.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT_MARKER="plugin/skill-engine/docs/02-artifact-contract.md"
find_root() {
  local d="$1"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/$ROOT_MARKER" ]; then
      printf '%s\n' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}
REPO_ROOT="$(find_root "$SCRIPT_DIR" || find_root "$PWD")"
if [ -z "$REPO_ROOT" ]; then
  echo "ERROR: cannot locate the repository root — no $ROOT_MARKER above $SCRIPT_DIR or $PWD." >&2
  exit 69
fi
PLUGIN_ROOT="$REPO_ROOT/plugin/skill-engine"

SKILL_MD="$PLUGIN_ROOT/skills/engine-bootstrap/SKILL.md"
INTAKE_REF="$PLUGIN_ROOT/skills/engine-bootstrap/references/intake-and-detection.md"
# quickstart.md is in the declared edit surface for this work, but no
# invariant above touches its wording, so nothing here asserts against it.

for f in "$SKILL_MD" "$INTAKE_REF"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: expected surface is missing entirely: $f" >&2
    exit 69
  fi
done

WORK="$(mktemp -d -t skill-engine-bootstrap-sources-file.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass_count=0
fail_count=0

banner() { printf '\n== %s ==\n' "$1"; }

pass() {
  printf '  PASS  %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail() {
  local label="$1"
  shift
  printf '  FAIL  %s\n' "$label"
  local detail
  for detail in "$@"; do
    printf '%s\n' "$detail" | sed 's/^/        /'
  done
  fail_count=$((fail_count + 1))
}

# norm — collapse every run of whitespace, newlines included, to one
# space, then trim the ends. Every multi-word phrase assertion below runs
# against normalized text so a hand-wrapped line break can never hide a
# phrase from a naive line-oriented grep.
norm() { tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }

# near <text> <anchor-ere> <needle-ere> <window> — true when <needle>
# occurs within <window> characters of some occurrence of <anchor> in
# <text>. 240, not more: BSD grep (the default on macOS) rejects an
# interval bound above 255, and the window applies on both sides of the
# anchor.
near() {
  local text="$1" anchor="$2" needle="$3" window="$4"
  printf '%s' "$text" \
    | grep -oiE ".{0,${window}}${anchor}.{0,${window}}" \
    | grep -qiE -- "$needle"
}

assert_has() {
  local label="$1" text="$2" pat="$3"
  if printf '%s' "$text" | grep -qiE -- "$pat"; then
    pass "$label"
  else
    fail "$label" "no match for /$pat/"
  fi
}

assert_str() {
  local label="$1" text="$2" lit="$3"
  if printf '%s' "$text" | grep -qF -- "$lit"; then
    pass "$label"
  else
    fail "$label" "string not found: $lit"
  fi
}

assert_nonempty() {
  local label="$1" text="$2"
  if [ -n "$text" ]; then
    pass "$label"
  else
    fail "$label" "extraction returned nothing"
  fi
}

# gated_check <label> <gate:0|1> <absent-reason> <predicate-fn> — runs
# <predicate-fn> (a 0/1-exit shell function) only when <gate> is 1. When
# the gate is 0 this always fails with <absent-reason>, so a preservation
# check whose subject doesn't exist yet cannot report green just because
# the thing being preserved was already true before any edit.
gated_check() {
  local label="$1" gate="$2" absent_reason="$3" predicate="$4"
  if [ "$gate" -ne 1 ]; then
    fail "$label" "$absent_reason"
    return
  fi
  if "$predicate"; then
    pass "$label"
  else
    fail "$label" "the new flag is documented, but the preserved/derived content itself is missing or wrong"
  fi
}

RAW_INTAKE="$(cat "$INTAKE_REF")"
NORM_INTAKE="$(printf '%s' "$RAW_INTAKE" | norm)"
RAW_SKILL="$(cat "$SKILL_MD")"
NORM_SKILL="$(printf '%s' "$RAW_SKILL" | norm)"

SOURCES_FILE_DOC=0
printf '%s' "$NORM_INTAKE" | grep -qF -- '--sources-file' && SOURCES_FILE_DOC=1
BRANCH_DEFAULT_ALL_DOC=0
printf '%s' "$NORM_INTAKE" | grep -qF -- '--branch-default-all' && BRANCH_DEFAULT_ALL_DOC=1
BOTH_DOC=0
[ "$SOURCES_FILE_DOC" -eq 1 ] && [ "$BRANCH_DEFAULT_ALL_DOC" -eq 1 ] && BOTH_DOC=1

echo "NOTE: --sources-file documented in the reference = $SOURCES_FILE_DOC" >&2
echo "NOTE: --branch-default-all documented in the reference = $BRANCH_DEFAULT_ALL_DOC" >&2

# ---------------------------------------------------------------------------
# Fenced-block extraction helpers, shared by the format-example and
# parsing-block sections below.
# ---------------------------------------------------------------------------

# extract_fence_matching <file> <predicate-fn> — prints the content of the
# first fenced block in <file> (any info string, including none) whose
# joined content satisfies <predicate-fn> (called with the block's
# content on stdin; expected to exit 0 to select it). Empty output and a
# non-zero return when no block satisfies it or none exist.
extract_fence_matching() {
  local file="$1" predicate="$2"
  local fence_re='^[[:space:]]*```'
  local in_fence=0 buf="" line
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ $fence_re ]]; then
      if [ "$in_fence" -eq 1 ]; then
        if printf '%s' "$buf" | "$predicate"; then
          printf '%s' "$buf"
          return 0
        fi
        in_fence=0
      else
        buf=""
        in_fence=1
      fi
      continue
    fi
    [ "$in_fence" -eq 1 ] && buf+="$line"$'\n'
  done < "$file"
  return 1
}

# is_format_example_block — reads a fenced block's content on stdin;
# selects it when it carries at least one '#'-comment line AND at least
# one line that looks like a plausible source entry (a URL, or a
# path-shaped token) — the signature of "a worked example of the
# sources-file format", without demanding one specific wording of it.
is_format_example_block() {
  local content
  content="$(cat)"
  printf '%s\n' "$content" | grep -qE '^[[:space:]]*#' || return 1
  printf '%s\n' "$content" | grep -qE '(https?://|^[[:space:]]{0,4}[./~])' || return 1
  return 0
}

# locate_parser_block <file> — scans the WHOLE reference for fenced
# blocks labeled bash/sh/shell/awk (case-insensitive), the shapes a
# parsing one-liner would plausibly be shown in. Sets PARSER_BLOCK to the
# single match's content (and PARSER_ERR empty), or PARSER_BLOCK empty
# with PARSER_ERR naming why: none found, or more than one candidate
# (ambiguous — refused rather than guessed at).
PARSER_BLOCK=""
PARSER_ERR=""
locate_parser_block() {
  local file="$1"
  local fence_open_re='^[[:space:]]*```([A-Za-z]*)[[:space:]]*$'
  local in_fence=0 info="" info_lc="" buf="" line
  local -a matches=()
  local -a heads=()
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ $fence_open_re ]]; then
      if [ "$in_fence" -eq 1 ]; then
        info_lc="$(printf '%s' "$info" | tr '[:upper:]' '[:lower:]')"
        case "$info_lc" in
          bash | sh | shell | awk)
            matches+=("$buf")
            heads+=("$(printf '%s' "$buf" | head -n1)")
            ;;
        esac
        in_fence=0
      else
        info="${BASH_REMATCH[1]}"
        buf=""
        in_fence=1
      fi
      continue
    fi
    [ "$in_fence" -eq 1 ] && buf+="$line"$'\n'
  done < "$file"

  case "${#matches[@]}" in
    0)
      PARSER_BLOCK=""
      PARSER_ERR="no bash/sh/shell/awk-labeled fenced block found anywhere in the reference"
      ;;
    1)
      PARSER_BLOCK="${matches[0]}"
      PARSER_ERR=""
      ;;
    *)
      PARSER_BLOCK=""
      local joined
      joined="$(
        IFS='; '
        echo "${heads[*]}"
      )"
      PARSER_ERR="${#matches[@]} candidate shell/awk-labeled fenced blocks found (ambiguous which one parses the sources file): $joined"
      ;;
  esac
}

# run_parser_block <fixture-path> [stdin-mode] — runs PARSER_BLOCK against
# <fixture-path> per the execution convention documented at the top of
# this file. stdin-mode "none" (or an already-nonexistent fixture) feeds
# /dev/null instead of the fixture's own content, for the case under test
# being the path itself, not a line inside it. Sets RUN_OUT (combined
# stdout+stderr) and RUN_RC (exit status) on a completed run, or RUN_ERR
# (and leaves RUN_OUT/RUN_RC stale) when the block could not be run at
# all — an unsubstitutable placeholder set, not a run outcome.
RUN_OUT=""
RUN_RC=0
RUN_ERR=""
run_parser_block() {
  local fixture="$1" stdin_mode="${2:-content}"
  RUN_ERR=""
  local block="$PARSER_BLOCK"
  local placeholders=""
  placeholders="$(printf '%s' "$block" | grep -oE '<[A-Za-z_][A-Za-z0-9_ .-]*>' | sort -u)"
  local placeholder_count=0
  [ -n "$placeholders" ] && placeholder_count="$(printf '%s\n' "$placeholders" | grep -c .)"

  local substituted="$block"
  if [ "$placeholder_count" -eq 1 ]; then
    substituted="${substituted//$placeholders/$fixture}"
  elif [ "$placeholder_count" -gt 1 ]; then
    RUN_ERR="multiple distinct <...> placeholders in the block ($(printf '%s' "$placeholders" | tr '\n' ' ')) — cannot tell which one stands for the sources-file path"
    return
  fi

  local stdin_src="$fixture"
  if [ "$stdin_mode" = "none" ] || [ ! -f "$fixture" ]; then
    stdin_src="/dev/null"
  fi

  local full_script="set -o pipefail; $substituted"
  local outfile
  outfile="$(mktemp)"
  (cd "$WORK" && bash -c "$full_script" _ "$fixture") <"$stdin_src" >"$outfile" 2>&1
  RUN_RC=$?
  RUN_OUT="$(cat "$outfile")"
  rm -f "$outfile"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

mkdir -p "$WORK/local-repo-a" "$WORK/local-repo-b"
printf 'placeholder\n' >"$WORK/local-repo-a/README"
printf 'placeholder\n' >"$WORK/local-repo-b/README"

URL_A="https://github.com/acme/widgets"
PATH_A="$WORK/local-repo-a"
PATH_B="$WORK/local-repo-b"

VALID_BASIC="$WORK/valid-basic.txt"
printf '\n%s\n\n%s\n\n' "$URL_A" "$PATH_A" >"$VALID_BASIC"

COMMENTS_BRANCH="$WORK/comments-and-branch.txt"
printf '# comment describing this file\n%s dev\n# a second, unrelated comment\n%s\n' \
  "$URL_A" "$PATH_B" >"$COMMENTS_BRANCH"

EMPTY_FILE="$WORK/empty.txt"
: >"$EMPTY_FILE"

COMMENT_ONLY="$WORK/comment-only.txt"
printf '# just a comment\n# another comment, still nothing to intake\n' >"$COMMENT_ONLY"

BAD_LINE_NO=2
BAD_LINE_FILE="$WORK/bad-line.txt"
printf '%s\nnot-a-url-and-not-a-real-path\n%s\n' "$URL_A" "$PATH_A" >"$BAD_LINE_FILE"

NONEXISTENT_FILE="$WORK/does-not-exist-sources.txt"

# Fixture self-checks: a malformed fixture is a harness defect, not a red
# criterion, so it aborts the whole run with a diagnostic instead of
# quietly making some later assertion fail for the wrong reason.
harness_error() {
  echo "ERROR: fixture setup is broken — $1" >&2
  exit 70
}
[ -d "$PATH_A" ] || harness_error "$PATH_A does not exist"
[ -d "$PATH_B" ] || harness_error "$PATH_B does not exist"
[ ! -s "$EMPTY_FILE" ] || harness_error "$EMPTY_FILE is not actually empty"
[ -s "$COMMENT_ONLY" ] || harness_error "$COMMENT_ONLY is empty, not comment-only"
grep -qvE '^[[:space:]]*(#.*)?$' "$COMMENT_ONLY" && harness_error "$COMMENT_ONLY has a non-comment, non-blank line"
BAD_LINE_TEXT="$(sed -n "${BAD_LINE_NO}p" "$BAD_LINE_FILE")"
case "$BAD_LINE_TEXT" in
  http*://* | /*) harness_error "line $BAD_LINE_NO of $BAD_LINE_FILE looks like a URL or absolute path: $BAD_LINE_TEXT" ;;
esac
[ -e "$BAD_LINE_TEXT" ] && harness_error "line $BAD_LINE_NO of $BAD_LINE_FILE unexpectedly exists on disk: $BAD_LINE_TEXT"
[ ! -e "$NONEXISTENT_FILE" ] || harness_error "$NONEXISTENT_FILE unexpectedly exists"

# ---------------------------------------------------------------------------
# Fixture-execution assertion helpers
# ---------------------------------------------------------------------------

# check_accepts <label> <fixture> <source|branch>... — runs the parser
# block against a WELL-FORMED fixture and checks, format-agnostically:
# exit 0, exactly one non-blank output line per real entry, each entry's
# source string present in the output, a given entry's branch (when
# non-empty) present on that entry's own line, and no comment text
# leaking into the output.
check_accepts() {
  local label="$1" fixture="$2"
  shift 2
  if [ -z "$PARSER_BLOCK" ]; then
    fail "$label" "$PARSER_ERR"
    return
  fi
  run_parser_block "$fixture"
  if [ -n "$RUN_ERR" ]; then
    fail "$label" "$RUN_ERR"
    return
  fi

  local -a detail=()
  local ok=1
  if [ "$RUN_RC" -ne 0 ]; then
    ok=0
    detail+=("exit code $RUN_RC (expected 0 for a well-formed sources file)")
  fi

  local nonblank_lines
  nonblank_lines="$(printf '%s\n' "$RUN_OUT" | grep -c '[^[:space:]]' || true)"
  local expected_count=$#
  if [ "$nonblank_lines" -ne "$expected_count" ]; then
    ok=0
    detail+=("expected $expected_count non-blank output line(s), got $nonblank_lines")
  fi

  local pair src branch
  for pair in "$@"; do
    src="${pair%%|*}"
    branch="${pair#*|}"
    if ! printf '%s\n' "$RUN_OUT" | grep -qF -- "$src"; then
      ok=0
      detail+=("no output line mentions source: $src")
      continue
    fi
    if [ -n "$branch" ] && ! printf '%s\n' "$RUN_OUT" | grep -F -- "$src" | grep -qF -- "$branch"; then
      ok=0
      detail+=("the output line for $src does not carry its branch: $branch")
    fi
  done

  if printf '%s\n' "$RUN_OUT" | grep -qF -- '#'; then
    ok=0
    detail+=("output retains a '#' — a comment line leaked through")
  fi

  if [ "$ok" -eq 1 ]; then
    pass "$label"
  else
    fail "$label" "${detail[@]}"
  fi
}

# check_rejects_zero_entries <label> <fixture> [stdin-mode] — runs the
# parser block against a fixture that must be refused outright (empty,
# comment-only, or a sources-file path that doesn't exist) and requires a
# non-zero exit. Diagnostic wording (naming the path/reason) is asserted
# separately as prose, not demanded of the executed block itself — a
# correct block is free to print as little or as much as it likes on the
# way to a non-zero exit.
check_rejects_zero_entries() {
  local label="$1" fixture="$2" stdin_mode="${3:-content}"
  if [ -z "$PARSER_BLOCK" ]; then
    fail "$label" "$PARSER_ERR"
    return
  fi
  run_parser_block "$fixture" "$stdin_mode"
  if [ -n "$RUN_ERR" ]; then
    fail "$label" "$RUN_ERR"
    return
  fi
  if [ "$RUN_RC" -ne 0 ]; then
    pass "$label"
  else
    fail "$label" "exit code 0 — expected a non-zero exit (a halt); output was: $RUN_OUT"
  fi
}

# check_rejects_bad_line <label> <fixture> <line-no> — as above, plus
# requires the offending physical line number to appear (as a standalone
# number, not embedded in a longer one) somewhere in the combined output.
check_rejects_bad_line() {
  local label="$1" fixture="$2" line_no="$3"
  if [ -z "$PARSER_BLOCK" ]; then
    fail "$label" "$PARSER_ERR"
    return
  fi
  run_parser_block "$fixture"
  if [ -n "$RUN_ERR" ]; then
    fail "$label" "$RUN_ERR"
    return
  fi
  local -a detail=()
  local ok=1
  if [ "$RUN_RC" -eq 0 ]; then
    ok=0
    detail+=("exit code 0 — a line naming neither a URL nor an existing path must halt, not succeed")
  fi
  # Scrub the tmpdir first: it's a mktemp path (e.g. /var/folders/2k/...)
  # that routinely contains a bare digit bounded by non-digits, and every
  # fixture path is under it — searching raw output risks a false PASS
  # off the fixture's own path rather than a genuine line-number citation.
  local scrubbed="${RUN_OUT//$WORK/}"
  if ! printf '%s\n' "$scrubbed" | grep -qE "(^|[^0-9])${line_no}([^0-9]|\$)"; then
    ok=0
    detail+=("diagnostic does not name line ${line_no}: $RUN_OUT")
  fi
  if [ "$ok" -eq 1 ]; then
    pass "$label"
  else
    fail "$label" "${detail[@]}"
  fi
}

# ---------------------------------------------------------------------------
# sources-file parsing: format, semantics, and combination with positional
# arguments (prose)
# ---------------------------------------------------------------------------

banner "sources-file intake: flag, one-entry-per-line, optional branch column"

assert_has "the --sources-file flag takes a path argument" "$NORM_INTAKE" \
  '--sources-file[[:space:]]*<path>'

if near "$NORM_INTAKE" '--sources-file' 'one[^.]{0,15}(source|entry|line)[^.]{0,15}per line' 240; then
  pass "the reference states one source per line"
else
  fail "the reference states one source per line" "no 'one ... per line' phrasing near --sources-file"
fi

if near "$NORM_INTAKE" '--sources-file' 'a URL or a local path' 240 \
  || near "$NORM_INTAKE" '--sources-file' 'URL[^.]{0,10}or[^.]{0,15}(local )?path' 240; then
  pass "the reference states each line is a URL or a local path"
else
  fail "the reference states each line is a URL or a local path" \
    "no 'URL or a (local) path' phrasing near --sources-file"
fi

if near "$NORM_INTAKE" 'branch' 'second[^.]{0,15}(whitespace-separated )?column' 240; then
  pass "the reference documents an optional second, whitespace-separated branch column"
else
  fail "the reference documents an optional second, whitespace-separated branch column" \
    "no 'second ... column' phrasing near 'branch'"
fi

if near "$NORM_INTAKE" 'blank line' '#' 120 && near "$NORM_INTAKE" '#' 'ignor' 120; then
  pass "the reference states blank lines and '#'-comment lines are ignored"
else
  fail "the reference states blank lines and '#'-comment lines are ignored" \
    "no co-occurrence of 'blank line', '#', and 'ignor...' close together"
fi

if near "$NORM_INTAKE" '--sources-file' 'same kind inference' 240 \
  || near "$NORM_INTAKE" '--sources-file' 'same[^.]{0,20}source_id[^.]{0,20}derivation' 240; then
  pass "each sources-file entry is intaken with the same kind inference and source_id derivation as a positional argument"
else
  fail "each sources-file entry is intaken with the same kind inference and source_id derivation as a positional argument" \
    "no 'same kind inference' / 'same source_id derivation' phrasing near --sources-file"
fi

if near "$NORM_INTAKE" '--sources-file' 'combined with positional' 240 \
  || near "$NORM_INTAKE" 'positional argument' 'combined' 240; then
  pass "sources-file entries may be combined with positional arguments in one invocation"
else
  fail "sources-file entries may be combined with positional arguments in one invocation" \
    "no 'combined with positional arguments' phrasing"
fi

banner "sources-file format: a fenced example and an executable parsing block"

if format_block="$(extract_fence_matching "$INTAKE_REF" is_format_example_block)"; then
  assert_nonempty "the reference shows a fenced example of the sources-file format" "$format_block"
else
  fail "the reference shows a fenced example of the sources-file format" \
    "no fenced block in the reference carries both a '#'-comment line and a plausible source line"
fi

locate_parser_block "$INTAKE_REF"
if [ -n "$PARSER_BLOCK" ]; then
  pass "the reference carries exactly one shell/awk-labeled fenced block that parses the sources-file format"
else
  fail "the reference carries exactly one shell/awk-labeled fenced block that parses the sources-file format" "$PARSER_ERR"
fi

# ---------------------------------------------------------------------------
# sources-file parsing: executed against real fixtures
# ---------------------------------------------------------------------------

banner "sources-file parsing: executed against a well-formed file (git URL + local path, blank lines leading/between/trailing)"
check_accepts "well-formed two-entry file, no branch column, is parsed to exactly its two real entries" \
  "$VALID_BASIC" "$URL_A|" "$PATH_A|"

banner "sources-file parsing: executed against comments plus a branch column"
check_accepts "comments are ignored and the branch column is captured only on the entry that carries one" \
  "$COMMENTS_BRANCH" "$URL_A|dev" "$PATH_B|"

banner "sources-file must-reject inputs: executed rejection, one fixture per category"

check_rejects_zero_entries "an entirely empty sources file halts intake" "$EMPTY_FILE"
check_rejects_zero_entries "a comment-only sources file halts intake" "$COMMENT_ONLY"
check_rejects_zero_entries "a sources-file path that does not exist halts intake" "$NONEXISTENT_FILE" none
check_rejects_bad_line "a line naming neither a URL nor an existing path halts intake and names its line number" \
  "$BAD_LINE_FILE" "$BAD_LINE_NO"

banner "sources-file must-reject inputs: the halt is described with a path and a reason (prose)"

f1_ok() {
  near "$NORM_INTAKE" 'unreadable|empty|entirely.{0,6}comment' 'halt' 240 || return 1
  near "$NORM_INTAKE" 'halt' 'path' 240 || return 1
  near "$NORM_INTAKE" 'halt' 'reason' 240 || return 1
  return 0
}
if f1_ok; then
  pass "the reference states an unreadable/empty/comment-only sources file halts intake with an error naming the path and the reason"
else
  fail "the reference states an unreadable/empty/comment-only sources file halts intake with an error naming the path and the reason" \
    "no co-occurrence of a reject condition, 'halt', 'path', and 'reason'"
fi

f2_ok() {
  near "$NORM_INTAKE" 'neither[^.]{0,10}a URL nor' 'line' 240 || return 1
  near "$NORM_INTAKE" 'line' 'number' 60 || return 1
  near "$NORM_INTAKE" 'line number' 'halt' 240 || return 1
  return 0
}
if f2_ok; then
  pass "the reference states a bad line is reported with its line number and halts intake"
else
  fail "the reference states a bad line is reported with its line number and halts intake" \
    "no co-occurrence of 'neither a URL nor ...', 'line number', and 'halt'"
fi

# ---------------------------------------------------------------------------
# --branch-default-all: suppression, and the prompt it does NOT touch
# ---------------------------------------------------------------------------

banner "branch-default-all: suppresses the per-source branch prompt for unanswered git-managed sources"

assert_str "the --branch-default-all flag is documented" "$NORM_INTAKE" '--branch-default-all'

if near "$NORM_INTAKE" '--branch-default-all' 'suppress|skip' 240; then
  pass "--branch-default-all suppresses Step 2.4's per-source prompt"
else
  fail "--branch-default-all suppresses Step 2.4's per-source prompt" \
    "no 'suppress'/'skip' phrasing near --branch-default-all"
fi

if near "$NORM_INTAKE" '--branch-default-all' 'absent|omit' 240 \
  && near "$NORM_INTAKE" '--branch-default-all' 'Enter' 240; then
  pass "a source left unanswered by --branch-default-all gets the same absent-branch record pressing Enter produces today"
else
  fail "a source left unanswered by --branch-default-all gets the same absent-branch record pressing Enter produces today" \
    "no co-occurrence of --branch-default-all, an absent/omit phrasing, and the existing Enter-default equivalence"
fi

if near "$NORM_INTAKE" 'branch column' 'prompt-free|without prompting|no prompt' 240 \
  && near "$NORM_INTAKE" 'branch column' 'whether or not|with or without|regardless of' 240; then
  pass "an entry that carries its own branch column is recorded prompt-free whether or not the flag is given"
else
  fail "an entry that carries its own branch column is recorded prompt-free whether or not the flag is given" \
    "no co-occurrence of 'branch column', a prompt-free phrasing, and a flag-independence phrasing"
fi

banner "branch-default-all: the branch prompt still fires without it (gated on the flag existing at all)"

predicate_step24_prompt_preserved() {
  printf '%s' "$NORM_INTAKE" | grep -qF -- "Monitor the repo's default branch?" || return 1
  printf '%s' "$NORM_INTAKE" | grep -qF -- 'Empty, `y`, `Y`, `yes`' || return 1
  printf '%s' "$NORM_INTAKE" | grep -qF -- 'Omit `branch`' || return 1
  return 0
}
gated_check \
  "a git-managed source with no branch column and no --branch-default-all still gets the original once-per-source prompt" \
  "$BRANCH_DEFAULT_ALL_DOC" \
  "--branch-default-all is not documented yet — whether the original prompt still fires without it is not yet checkable" \
  predicate_step24_prompt_preserved

# ---------------------------------------------------------------------------
# Combined flags: the prompt-count contract
# ---------------------------------------------------------------------------

banner "combined --sources-file and --branch-default-all: the only remaining interactive prompt is the contextualizer name"

table_row_has() {
  local step="$1" value="$2"
  grep -E '^[[:space:]]*\|' "$INTAKE_REF" \
    | grep -F -- "$step" \
    | grep -qE "(^|[^0-9])${value}([^0-9]|\$)"
}
if table_row_has '2.4' '0'; then
  pass "the prompt-count table shows Step 2.4 at zero prompts when both flags are given"
else
  fail "the prompt-count table shows Step 2.4 at zero prompts when both flags are given" \
    "no table row naming Step 2.4 with a standalone 0"
fi
if table_row_has '2.5' '1'; then
  pass "the prompt-count table shows Step 2.5 at exactly one prompt"
else
  fail "the prompt-count table shows Step 2.5 at exactly one prompt" \
    "no table row naming Step 2.5 with a standalone 1"
fi

if near "$NORM_INTAKE" 'only' 'Step 2\.5' 240 && near "$NORM_INTAKE" 'Step 2\.5' 'Step 3\.5' 240; then
  pass "the reference states the only interactive prompt before Step 3.5 is the Step 2.5 name prompt"
else
  fail "the reference states the only interactive prompt before Step 3.5 is the Step 2.5 name prompt" \
    "no co-occurrence of 'only', 'Step 2.5', and 'Step 3.5'"
fi

# ---------------------------------------------------------------------------
# Preservation: the two existing intake forms, and the router's byte budget
# ---------------------------------------------------------------------------

banner "preservation: positional and paste-loop intake are described unchanged (gated on --sources-file existing at all)"

predicate_step1_positional_bullet_preserved() {
  printf '%s' "$NORM_INTAKE" | grep -qF -- 'Positional arguments.' || return 1
  printf '%s' "$NORM_INTAKE" | grep -qF -- 'one per argument' || return 1
  printf '%s' "$NORM_INTAKE" | grep -qF -- 'do not enter the interactive loop' || return 1
  return 0
}
gated_check \
  "the positional-arguments bullet's existing wording is untouched" \
  "$SOURCES_FILE_DOC" \
  "--sources-file is not documented yet — preservation of the positional-arguments bullet is not yet checkable" \
  predicate_step1_positional_bullet_preserved

predicate_step1_interactive_bullet_preserved() {
  printf '%s' "$NORM_INTAKE" | grep -qF -- 'Interactive loop.' || return 1
  printf '%s' "$NORM_INTAKE" | grep -qF -- 'Paste a URL or local path; type' || return 1
  printf '%s' "$NORM_INTAKE" | grep -qF -- 'literal word `finish`' || return 1
  return 0
}
gated_check \
  "the interactive paste-loop bullet's existing wording is untouched" \
  "$SOURCES_FILE_DOC" \
  "--sources-file is not documented yet — preservation of the interactive-loop bullet is not yet checkable" \
  predicate_step1_interactive_bullet_preserved

predicate_skill_intake_paths_described_unchanged() {
  # A byte-neutral rewrite that moves a sentence out of SKILL.md and into
  # the reference is an allowed way to hold the router's byte ceiling, so
  # this does not pin SKILL.md's exact wording (that pin lives on the
  # reference's own bullets, above) — only that SKILL.md still names both
  # intake forms at all, in whichever surface (SKILL.md or its own
  # doctrine pointer) ends up carrying them.
  printf '%s' "$NORM_SKILL" | grep -qi -- 'positional' || return 1
  printf '%s' "$NORM_SKILL" | grep -qi -- 'finish' || return 1
  return 0
}
gated_check \
  "engine-bootstrap/SKILL.md still names both intake forms after the sources-file addition" \
  "$SOURCES_FILE_DOC" \
  "--sources-file is not documented yet — preservation of SKILL.md's intake summary is not yet checkable" \
  predicate_skill_intake_paths_described_unchanged

banner "preservation: the router stays inside its byte ceiling and the shipped doctrine suite still passes"

predicate_skill_byte_ceiling() {
  local bytes
  bytes="$(wc -c <"$SKILL_MD" | tr -d ' ')"
  [ "$bytes" -le 8204 ]
}
gated_check \
  "engine-bootstrap/SKILL.md stays at or under its router byte ceiling once both flags are documented" \
  "$BOTH_DOC" \
  "--sources-file and --branch-default-all are not both documented yet — the post-edit byte ceiling is not yet checkable" \
  predicate_skill_byte_ceiling

predicate_doctrine_passes() {
  (cd "$REPO_ROOT" && bash scripts/ci-local.sh doctrine) >/dev/null 2>&1
}
gated_check \
  "the repo's doctrine suite still passes once both flags are documented" \
  "$BOTH_DOC" \
  "--sources-file and --branch-default-all are not both documented yet — the post-edit doctrine run is not yet checkable" \
  predicate_doctrine_passes

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
