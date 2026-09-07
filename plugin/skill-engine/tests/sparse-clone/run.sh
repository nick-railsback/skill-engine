#!/usr/bin/env bash
# Feature-scoped test runner for the opt-in files_of_interest-scoped sparse
# clone: an optional per-source array in source-paths.json that, when
# non-empty, makes the engine substitute a `git sparse-checkout` for the
# unconditional shallow clone at cache-seeding time, with a post-clone
# validator that hard-fails a typo'd entry and names sibling directories.
#
# This is a FROZEN oracle written from spec.md alone, black-box throughout:
# JSON Schema validation, prose grepped out of the two reference docs (wrap-
# normalized so hand-wrapped Markdown never breaks a match), and the actual
# git recipe extracted from those same docs and run against a scratch repo.
# It never asserts against an implementation module or function name — there
# isn't one; the recipe is pure git, per the doctrine ("no third-party
# tools"). No tree-wide grep is performed anywhere in this file (every prose
# check names its one target file), so there is no need to exclude this
# oracle's own directory from a scan.
#
# Expected RED right now, and why: source-paths.schema.json does not define
# files_of_interest at all yet (additionalProperties: true tolerates it as
# an unknown key with NO shape constraint), so every must-reject fixture
# below (a non-array value, an array containing an empty string) currently
# VALIDATES when it should be rejected — that is the red. cache-seeding.md
# Step 3.5 and cache-and-clone.md step 6 carry only the unconditional
# shallow-clone recipe today (confirmed by hand before writing this file);
# neither mentions sparse-checkout, --no-checkout, or files_of_interest, so
# every recipe-shape and executed-recipe assertion below is red for the same
# reason: there is nothing yet to extract and run — including the
# post-clone-validator prose checks (neither file mentions -maxdepth 2 or
# "resolved no files" yet either) and the whole-block execution checks
# (there is no block to substitute placeholders into and run).
# 02-artifact-contract.md's
# entry-shape section and 03-engine.md's own "## State schema" section
# (distinct from its sparse-cloning section, which already links to
# "State schema" but the target section itself says nothing back) do not
# mention files_of_interest yet either.
#
# Expected GREEN right now: the fixture self-checks; the "valid" schema
# fixtures (absent/empty/populated files_of_interest) — trivially true today
# because an unconstrained unknown key accepts anything, so this is the
# accept-side complement to the must-reject checks, not a feature test; the
# existing examples/*/research/source-paths.json and the template still
# validating; the byte-identical-baseline checks on the two files' existing
# unconditional shallow-clone recipes (nothing has touched them yet); and
# criterion 6's preservation half — `ci-local.sh json` and `ci-local.sh
# doctrine` both passing on the repo as it stands today. verify.sh's hash
# was part of that half until the heuristics work re-stamped the file; the
# byte-identity assertion it named is gone, and this list no longer claims
# it.
#
# Design decisions pinned where spec.md is silent on an operational detail:
#   1. Schema fixtures are full source-paths.json documents (schema_version
#      + sources[]), matching how scripts/ci-local.sh's own run_json
#      validates — check-jsonschema validates at the document root, not a
#      bare per-source object.
#   2. The four clone flags (--depth=1, --single-branch, --filter=blob:none,
#      --no-checkout) are checked as a SET, not a fixed substring in a fixed
#      order: git flag order carries no semantics, and the two texts this
#      spec cites already disagree on order (spec.md's own prose quotes
#      "--filter=blob:none --no-checkout --depth=1 --single-branch"; the
#      03-engine.md fenced recipe it cites as Source uses "--depth=1
#      --single-branch --filter=blob:none --no-checkout"). Locking one order
#      would fail on a semantically-correct doc that picked the other.
#   3. "Every git invocation carries a -C target under the cache root" is
#      checked as: each of the three post-clone invocations (sparse-checkout
#      init, sparse-checkout set, checkout) carries a -C flag, AND the
#      recipe block mentions .cache/skill-engine somewhere. This file does
#      NOT assert that -C's literal argument string is the cache-root path,
#      because the existing (already-shipped) recipes in both files compute
#      that path into a $dest variable well before the git invocation line —
#      guessing that a not-yet-written sparse block reuses that same
#      variable name would be anticipating implementation, not testing
#      contract. This is not a gap left untested, though: the preservation
#      section's `bash scripts/ci-local.sh doctrine` run exercises doctrine
#      check 4 for real, and check 4 DOES reject a -C target that is a bare
#      variable reference without a literal cache-root path in scope (per
#      chunk 01's own must-reject fixtures) — so a recipe whose -C argument
#      isn't genuinely cache-scoped fails there instead, once it exists.
#   4. The executed half runs ONE files_of_interest list per file —
#      ["docs/**", "dcos/**"] — rather than spec.md's single-entry
#      `["dcos/**"]` example. A single-entry all-fail sparse-checkout leaves
#      the destination directory empty, so there would be nothing for the
#      doctrine's own `find <repo>/<ancestor> -maxdepth 2` sibling lookup to
#      find — which is exactly why the doctrine's OWN worked example
#      ("nearest siblings under 'src/': src/auth/, src/audit/, src/lib/")
#      only makes sense next to OTHER, valid entries in the same list that
#      really did check out. Pairing the typo with one valid sibling entry
#      is what makes the doctrine's named mechanism (find -maxdepth 2)
#      executable at all, and matches its own example's shape. This is a
#      genuine tension between spec.md's literal single-entry example and
#      the doctrine's own find-based mechanism (which needs something
#      checked out to find) — surfaced here for the maintainer, not
#      resolved: this oracle does not test the all-entries-fail case either
#      way, and does not prescribe how a validator would need to handle it.
#   5. Two independent layers test the must-reject/validator claim, because
#      the executed git-level facts alone (typo resolves nothing; docs/ is
#      discoverable at the top level) cannot tell a real validator apart
#      from NO validator at all — both leave the identical git-level trace.
#      Layer one (prose, robust): the section text is grepped for the
#      doctrine's own verbatim mechanism strings ("-maxdepth 2", "resolved
#      no files") and for the per-source skip phrasing ("this source" near
#      skip/continue/proceed) both files already use for every other
#      failure branch — this alone is enough to fail red on a recipe-only
#      (no-validator) implementation. Layer two (executed, best-effort): the
#      WHOLE extracted block — not just the four git lines — is run for
#      real (stdin closed, so a defensive `read` in the block can't hang
#      this run), substituting the placeholder tokens (<source_id>, <url>,
#      <ref>, <repo-uri>) already established in both files' EXISTING
#      shallow-clone code plus the one token 03-engine.md's own doctrine
#      names (<files_of_interest entries...>), then asserting the combined
#      stdout+stderr names the typo'd entry and lists docs/, and that a
#      sentinel appended after the script is reached — proving the block
#      ran to its end rather than an early `exit` (the "other sources
#      proceed" contract; the sentinel, not raw exit status, because the
#      block's own last command can legitimately be non-zero without
#      exiting the shell). If a real implementation names its placeholders
#      differently, layer two reports a clear "unsubstituted placeholder"
#      reason rather than a false "no validator" — layer one is the
#      dependable signal; layer two is corroboration when the doc's
#      convention matches what's already there today.
#   6. The four clone flags are extracted dynamically from each file's clone
#      line (so a doc that drops or reorders a flag is caught); the two
#      fixed CLI phrases actually invoked during execution
#      (`sparse-checkout init --no-cone`, a bare `checkout`) are gated
#      behind their own presence assertions passing first — execution never
#      runs unless every piece was independently confirmed present in the
#      doc, so nothing here ever hand-types content the file doesn't
#      already contain. Backslash-continued lines are joined before any
#      single-line grep, so a doc author wrapping the five-flag clone
#      invocation across two physical lines does not read as a dropped flag.
#   7. The byte-identical-baseline check (empty/absent files_of_interest path
#      unchanged) hashes the fenced block immediately following a fixed
#      anchor sentence ("atomic-rename idiom"). It assumes the sparse
#      addition leaves that block as a sibling (e.g. inside an added
#      if/else) rather than relocating or rewording the sentence that
#      precedes it; a correct implementation that rewords the surrounding
#      prose while leaving the git commands byte-identical would false-red
#      here. Flagged as a known limitation rather than switched to
#      substring-containment matching, to keep this chunk's oracle scoped.
#
# -e is intentionally omitted: every assertion runs and reports, not abort
# at the first red one. Every tmpdir this file creates is removed on exit.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_ROOT/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

SCHEMA="$PLUGIN_ROOT/engine-bootstrap-templates/source-paths.schema.json"
TEMPLATE="$PLUGIN_ROOT/engine-bootstrap-templates/source-paths.json.template"
CACHE_SEEDING="$PLUGIN_ROOT/skills/engine-bootstrap/references/cache-seeding.md"
CACHE_AND_CLONE="$PLUGIN_ROOT/skills/discover/references/cache-and-clone.md"
ARTIFACT_CONTRACT="$PLUGIN_ROOT/docs/02-artifact-contract.md"
ENGINE_DOC="$PLUGIN_ROOT/docs/03-engine.md"
CI_LOCAL="$REPO_ROOT/scripts/ci-local.sh"

CS_BASELINE_SHA256="4761ffa8e16f67e48631de83fca6e6706d12a3b6b6044956e1e745f41c04d3c5"
CC_BASELINE_SHA256="4c126c42b367d1b20b246b69356950baac6c6f921e3fb0e5207cfb6d84600472"

pass_count=0
fail_count=0

WORK="$(mktemp -d -t skill-engine-sparse-clone.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass() {
  printf '  PASS  %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail() {
  local label="$1"
  shift
  printf '  FAIL  %s\n' "$label"
  if [ "$#" -gt 0 ]; then
    printf '        %s\n' "$@"
  fi
  fail_count=$((fail_count + 1))
}

section() {
  printf '\n── %s ──\n' "$1"
}

# Collapse every run of whitespace — newlines included — to one space, so a
# phrase assertion against a hard-wrapped reference file does not depend on
# where the phrase happened to break across lines.
normalize() {
  printf '%s' "$1" | tr -s '[:space:]' ' '
}

sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

sha256_of_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# check-jsonschema availability — mirrors scripts/ci-local.sh's own
# NOTE-and-skip behavior exactly, per spec.md's Test paths note.
# ---------------------------------------------------------------------------
HAVE_CJS=0
if command -v check-jsonschema >/dev/null 2>&1; then
  HAVE_CJS=1
else
  echo "NOTE: check-jsonschema not on PATH — skipping schema validation locally." >&2
  echo "      CI runs it (pip install check-jsonschema==0.37.2); install it to match CI exactly." >&2
fi

schema_accepts() {
  local label="$1" f="$2" out
  if out="$(check-jsonschema --schemafile "$SCHEMA" "$f" 2>&1)"; then
    pass "$label"
  else
    fail "$label" "$out"
  fi
}

schema_rejects() {
  local label="$1" f="$2"
  if check-jsonschema --schemafile "$SCHEMA" "$f" >/dev/null 2>&1; then
    fail "$label" "expected schema validation to reject $f, but it passed"
  else
    pass "$label"
  fi
}

# write_source_doc <out-file> <jq-extra-json-or-null> — a minimal, otherwise
# valid source-paths.json document with one git-managed source, optionally
# merged with $2 (a JSON object fragment, e.g. '{"files_of_interest": []}').
write_source_doc() {
  local out="$1" extra="${2:-null}"
  jq -n --argjson extra "$extra" '
    {
      schema_version: 1,
      sources: [
        ({
          id: "widget-src",
          kind: "git-managed",
          url: "https://example.com/acme/widgets",
          status: "confirmed",
          archived: false,
          lifecycle: {state: "reachable", last_checked: "2026-09-03", last_checked_sha: "abc1234", proposed_url: null},
          discovered_via: null
        } + (if $extra == null then {} else $extra end))
      ]
    }
  ' > "$out"
}

# ---------------------------------------------------------------------------
# Prose extraction helpers, reused by both the recipe-shape and the
# doc-consistency sections below.
# ---------------------------------------------------------------------------

# section_between <file> <start-ere> <end-ere> — lines from the first line
# matching <start-ere> up to (excluding) the next line matching <end-ere>.
# Patterns travel through ENVIRON, not -v: awk's -v assignment runs its own
# backslash-escape processing on the value (POSIX str-constant rules), which
# silently eats a literal `\.` down to `.` before the regex engine ever sees
# it — ENVIRON is not escape-processed, so `\.`/`\*` survive intact.
section_between() {
  SECTION_BETWEEN_START="$2" SECTION_BETWEEN_END="$3" awk '
    $0 ~ ENVIRON["SECTION_BETWEEN_END"] && f { exit }
    $0 ~ ENVIRON["SECTION_BETWEEN_START"] { f=1 }
    f
  ' "$1"
}

# extract_fenced_containing <needle> — reads a section on stdin, prints the
# content of the first ```bash fenced block that contains <needle> as a
# literal substring; empty output (and non-zero exit) when none does.
extract_fenced_containing() {
  awk -v needle="$1" '
    /^[[:space:]]*```bash/ { infence=1; buf=""; next }
    /^[[:space:]]*```/ {
      if (infence) {
        if (index(buf, needle) > 0) { printf "%s", buf; found=1 }
        infence=0
      }
      next
    }
    infence { buf = buf $0 "\n" }
    END { exit (found ? 0 : 1) }
  '
}

# join_continuations — collapses a backslash-continued physical line into
# one logical line, so a single-line grep (the four clone flags, the
# fixed-shape phrases, -C) does not go false-red just because a doc author
# wrapped a long invocation with a trailing `\`. Portable sed idiom (no GNU
# extensions): loop-append the next line whenever the current one ends in a
# bare backslash, then collapse the join point to one space.
join_continuations() {
  sed -e ':a' -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta'
}

# baseline_block_hash <file> <anchor-substring> — sha256 of the fenced
# ```bash block immediately following the first line containing
# <anchor-substring>.
baseline_block_hash() {
  local file="$1" anchor="$2"
  awk -v anchor="$anchor" '
    index($0, anchor) > 0 { a=1 }
    a && /^[[:space:]]*```bash/ { infence=1; next }
    infence && /^[[:space:]]*```/ { exit }
    infence { print }
  ' "$file" | sha256_of_stdin
}

# ---------------------------------------------------------------------------
# Scratch upstream repo shared by both files' executed-recipe checks:
# docs/** and src/** trees, so materialization and exclusion are both
# provable in one clone.
# ---------------------------------------------------------------------------
build_upstream_repo() {
  local root="$1"
  mkdir -p "$root/docs/sub" "$root/src/lib"
  printf 'doc a\n' > "$root/docs/a.md"
  printf 'doc b\n' > "$root/docs/sub/b.md"
  printf 'print("hi")\n' > "$root/src/main.py"
  printf 'def f(): pass\n' > "$root/src/lib/util.py"
  git -C "$root" init -q -b main
  git -C "$root" -c user.email=test@example.com -c user.name=Test add -A
  git -C "$root" -c user.email=test@example.com -c user.name=Test -c commit.gpgsign=false \
    commit -q -m 'seed'
}

# select_clone_line <block> — the git-clone invocation to test/run: prefers
# a line carrying --no-checkout (the sparse variant) when the block holds
# more than one `git clone` line — e.g. an implementer keeping the
# shallow-clone `if`-branch and the new sparse `else`-branch in one fence —
# so the shallow line is never mistaken for the sparse one. Falls back to
# the first clone line so a genuinely missing --no-checkout still reports
# as a missing flag rather than silently matching nothing.
select_clone_line() {
  local block="$1" line
  line="$(printf '%s' "$block" | grep 'git clone' | grep -F -- '--no-checkout' | head -n1 || true)"
  if [ -z "$line" ]; then
    line="$(printf '%s' "$block" | grep -m1 'git clone' || true)"
  fi
  printf '%s' "$line"
}

# run_recipe <block> <upstream> <dest> <entries...> — clones <upstream> into
# <dest> (must not exist) with the flags found on <block>'s clone line, then
# runs the two fixed-shape phrases the caller has already confirmed are
# present. Returns non-zero if any step fails.
run_recipe() {
  local block="$1" upstream="$2" dest="$3"
  shift 3
  local clone_line flags=() flag
  clone_line="$(select_clone_line "$block")"
  for flag in '--depth=1' '--single-branch' '--filter=blob:none' '--no-checkout'; do
    if printf '%s' "$clone_line" | grep -qF -- "$flag"; then
      flags+=("$flag")
    fi
  done
  git clone "${flags[@]}" -- "$upstream" "$dest" >/dev/null 2>&1 || return 1
  git -C "$dest" sparse-checkout init --no-cone >/dev/null 2>&1 || return 1
  git -C "$dest" sparse-checkout set "$@" >/dev/null 2>&1 || return 1
  git -C "$dest" checkout >/dev/null 2>&1 || return 1
  return 0
}

# run_whole_block <block> <upstream> <home> <source_id> <entries-literal> —
# best-effort execution of the WHOLE extracted block (not just the four git
# lines), so a post-clone validator living in the SAME fenced block gets
# exercised too, not just the raw clone/sparse-checkout/checkout mechanics.
# Substitutes the placeholder tokens cache-seeding.md and cache-and-clone.md
# ALREADY use today for the shallow-clone recipe (<source_id>, <url>,
# <ref>, and cache-and-clone.md's own <repo-uri> spelling in some doctrine
# prose) plus the one 03-engine.md's own doctrine names
# (<files_of_interest entries...>) — established conventions, not a guess
# about the sparse feature's own implementation. If any `<...>` token
# survives substitution (the doc used a different convention), this refuses
# to execute and reports which token, rather than running a mangled command
# line and reporting a misleading crash as "no validator". Runs under an
# overridden $HOME (so `~/.cache/skill-engine/...` in the block can never
# touch the real cache) with stdin explicitly closed (a defensive `read` in
# an implementer's block must not hang this run), and with a sentinel
# appended so a caller can tell "ran to the end" apart from "the last
# command happened to exit non-zero" (a per-source validation failure that
# tolerates continuing is a legitimate last-command-nonzero case; only an
# early `exit` skips the sentinel). Sets WHOLE_BLOCK_OUT (stdout+stderr,
# sentinel included) and WHOLE_BLOCK_RC (raw exit status, diagnostic only)
# on success; on a substitution failure, sets WHOLE_BLOCK_ERR and returns 2.
WHOLE_BLOCK_SENTINEL='__ORACLE_SPARSE_CLONE_END__'
WHOLE_BLOCK_OUT=""
WHOLE_BLOCK_RC=0
WHOLE_BLOCK_ERR=""
run_whole_block() {
  local block="$1" upstream="$2" home="$3" source_id="$4" entries_literal="$5"
  local substituted="$block"
  substituted="${substituted//<source_id>/$source_id}"
  substituted="${substituted//<url>/$upstream}"
  substituted="${substituted//<repo-uri>/$upstream}"
  substituted="${substituted//<ref>/HEAD}"
  substituted="${substituted//<files_of_interest entries...>/$entries_literal}"

  local leftover
  leftover="$(printf '%s' "$substituted" | grep -oE '<[A-Za-z_][^>]*>' | sort -u | tr '\n' ' ')"
  if [ -n "$leftover" ]; then
    WHOLE_BLOCK_ERR="unsubstituted placeholder(s) remain (doc uses a different token than <source_id>/<url>/<repo-uri>/<ref>/<files_of_interest entries...>): $leftover"
    return 2
  fi

  local script outfile errfile
  printf -v script '%s\nprintf %s\n' "$substituted" "$WHOLE_BLOCK_SENTINEL"
  outfile="$(mktemp)"
  errfile="$(mktemp)"
  HOME="$home" bash -c "$script" </dev/null >"$outfile" 2>"$errfile"
  WHOLE_BLOCK_RC=$?
  WHOLE_BLOCK_OUT="$(cat "$outfile" "$errfile" 2>/dev/null)"
  rm -f "$outfile" "$errfile"
  return 0
}

# test_reference_file <label> <file> <start-ere> <end-ere> <dest>
test_reference_file() {
  local label="$1" file="$2" start_pat="$3" end_pat="$4" dest="$5"

  section "$label — sparse recipe shape and cache-root scoping"

  local section_text block
  section_text="$(section_between "$file" "$start_pat" "$end_pat")"
  if [ -z "$section_text" ]; then
    fail "$label: the designated section is present" "start pattern matched nothing: $start_pat"
    return
  fi
  pass "$label: the designated section is present"

  block="$(printf '%s' "$section_text" | extract_fenced_containing 'sparse-checkout set')"
  # Join backslash-continued physical lines before any single-line grep
  # below, so a doc author wrapping the (longer, five-flag) sparse clone
  # invocation across two lines does not read as a missing flag.
  block="$(printf '%s' "$block" | join_continuations)"

  local section_flat
  section_flat="$(normalize "$section_text")"

  local clone_line flag
  clone_line="$(select_clone_line "$block")"
  for flag in '--depth=1' '--single-branch' '--filter=blob:none' '--no-checkout'; do
    if printf '%s' "$clone_line" | grep -qF -- "$flag"; then
      pass "$label: the clone invocation carries $flag"
    else
      fail "$label: the clone invocation carries $flag" "clone line: ${clone_line:-<not found>}"
    fi
  done

  local init_line set_line checkout_line
  init_line="$(printf '%s' "$block" | grep -m1 -E 'sparse-checkout[[:space:]]+init' || true)"
  set_line="$(printf '%s' "$block" | grep -m1 -E 'sparse-checkout[[:space:]]+set' || true)"
  # A bare checkout invocation: "checkout" must be its own command word, not
  # a substring of --no-checkout or sparse-checkout — both of which have a
  # hyphen, not whitespace, immediately before "checkout".
  checkout_line="$(printf '%s' "$block" | grep -E '(^|[[:space:]])checkout([[:space:]]|$)' | head -n1 || true)"

  if printf '%s' "$init_line" | grep -qE 'sparse-checkout[[:space:]]+init[[:space:]]+--no-cone'; then
    pass "$label: sparse-checkout init --no-cone is present"
  else
    fail "$label: sparse-checkout init --no-cone is present" "matched line: ${init_line:-<not found>}"
  fi

  if [ -n "$set_line" ]; then
    pass "$label: sparse-checkout set is present"
  else
    fail "$label: sparse-checkout set is present"
  fi

  if [ -n "$checkout_line" ]; then
    pass "$label: a bare checkout invocation (not sparse-checkout) is present"
  else
    fail "$label: a bare checkout invocation (not sparse-checkout) is present"
  fi

  if printf '%s' "$init_line" | grep -qE -- '-C[[:space:]]'; then
    pass "$label: the sparse-checkout init invocation carries -C"
  else
    fail "$label: the sparse-checkout init invocation carries -C" "line: ${init_line:-<not found>}"
  fi
  if printf '%s' "$set_line" | grep -qE -- '-C[[:space:]]'; then
    pass "$label: the sparse-checkout set invocation carries -C"
  else
    fail "$label: the sparse-checkout set invocation carries -C" "line: ${set_line:-<not found>}"
  fi
  if printf '%s' "$checkout_line" | grep -qE -- '-C[[:space:]]'; then
    pass "$label: the checkout invocation carries -C"
  else
    fail "$label: the checkout invocation carries -C" "line: ${checkout_line:-<not found>}"
  fi

  if printf '%s' "$block" | grep -qF '.cache/skill-engine'; then
    pass "$label: the recipe block is scoped under the engine cache root (.cache/skill-engine)"
  else
    fail "$label: the recipe block is scoped under the engine cache root (.cache/skill-engine)"
  fi

  section "$label — post-clone validator is documented (not just the recipe)"

  # A recipe with no validator at all would sail through every check above —
  # this is the discriminator: a validator this permissive is worse than
  # none, per the must-reject non-negotiable. Both anchor strings are the
  # doctrine's own verbatim mechanism text (03-engine.md § Post-clone
  # validation), not a guess about how this file's own bash spells it.
  if printf '%s' "$section_flat" | grep -qF -- '-maxdepth 2'; then
    pass "$label: the post-clone validator's sibling lookup (find ... -maxdepth 2) is documented"
  else
    fail "$label: the post-clone validator's sibling lookup (find ... -maxdepth 2) is documented"
  fi
  if printf '%s' "$section_flat" | grep -qiF 'resolved no files'; then
    pass "$label: the post-clone validator's failure wording (an entry resolved no files) is documented"
  else
    fail "$label: the post-clone validator's failure wording (an entry resolved no files) is documented"
  fi
  # Windowed around "resolved no files" specifically, not searched over the
  # whole section: both files ALREADY carry "skip this source ... do not
  # exit" phrasing for the pre-existing shallow-clone failure branches
  # (empty ls-remote, unsafe source_id), so an unscoped proximity search
  # over the whole section would pass today for a reason that has nothing
  # to do with the new validator — exactly the false-green this file must
  # not produce. Tying the window to the validator's own failure trigger
  # means this can only go green once that trigger text exists.
  local validator_context
  # Window capped at 250, not 300: BSD/macOS grep -E rejects an interval
  # bound above 255 ("maximum repetition exceeds 255").
  validator_context="$(printf '%s' "$section_flat" | grep -ioE '.{0,250}resolved no files.{0,250}' | head -n1 || true)"
  if printf '%s' "$validator_context" | grep -qiE 'this source.{0,150}(skip|continue|do not exit|proceed)|(skip|continue|do not exit|proceed).{0,150}this source'; then
    pass "$label: a hard-reject entry is scoped to skip only this source's seed (other sources proceed)"
  else
    fail "$label: a hard-reject entry is scoped to skip only this source's seed (other sources proceed)" \
      "context around 'resolved no files': ${validator_context:-<'resolved no files' not found>}"
  fi

  section "$label — sparse recipe executed against a scratch repo"

  local ready=1
  [ -n "$clone_line" ] || ready=0
  for flag in '--depth=1' '--single-branch' '--filter=blob:none' '--no-checkout'; do
    printf '%s' "$clone_line" | grep -qF -- "$flag" || ready=0
  done
  printf '%s' "$init_line" | grep -qE 'sparse-checkout[[:space:]]+init[[:space:]]+--no-cone' || ready=0
  [ -n "$set_line" ] || ready=0
  [ -n "$checkout_line" ] || ready=0

  if [ "$ready" -ne 1 ]; then
    local why="prerequisite: the full recipe (clone flags + sparse-checkout init --no-cone + sparse-checkout set + checkout) was not fully found in $label"
    fail "$label: files_of_interest docs/** materializes docs/ files" "$why"
    fail "$label: src/ (outside files_of_interest) is excluded from the checkout" "$why"
    fail "$label: the typo'd entry dcos/** resolves to no path in the checkout" "$why"
    fail "$label: the top-level checkout (the closest existing ancestor to the typo'd entry) surfaces docs/ as a sibling" "$why"
    fail "$label: the extracted block does not exit the shell on a validation failure (other sources' seeds proceed)" "$why"
    fail "$label: the validator's output names the offending entry (dcos/**)" "$why"
    fail "$label: the validator's output lists docs/ as a sibling" "$why"
    return
  fi

  if ! run_recipe "$block" "$UPSTREAM" "$dest" "docs/**" "dcos/**"; then
    local why="the extracted recipe (clone / sparse-checkout init / sparse-checkout set / checkout) did not complete cleanly against the scratch repo"
    fail "$label: files_of_interest docs/** materializes docs/ files" "$why"
    fail "$label: src/ (outside files_of_interest) is excluded from the checkout" "$why"
    fail "$label: the typo'd entry dcos/** resolves to no path in the checkout" "$why"
    fail "$label: the top-level checkout (the closest existing ancestor to the typo'd entry) surfaces docs/ as a sibling" "$why"
    fail "$label: the extracted block does not exit the shell on a validation failure (other sources' seeds proceed)" "$why"
    fail "$label: the validator's output names the offending entry (dcos/**)" "$why"
    fail "$label: the validator's output lists docs/ as a sibling" "$why"
    return
  fi

  if [ -f "$dest/docs/a.md" ] && [ -f "$dest/docs/sub/b.md" ]; then
    pass "$label: files_of_interest docs/** materializes docs/ files"
  else
    fail "$label: files_of_interest docs/** materializes docs/ files" \
      "docs/a.md present=$([ -f "$dest/docs/a.md" ] && echo yes || echo no); docs/sub/b.md present=$([ -f "$dest/docs/sub/b.md" ] && echo yes || echo no)"
  fi

  if [ ! -e "$dest/src" ]; then
    pass "$label: src/ (outside files_of_interest) is excluded from the checkout"
  else
    fail "$label: src/ (outside files_of_interest) is excluded from the checkout" \
      "$(find "$dest/src" 2>&1)"
  fi

  if [ ! -e "$dest/dcos" ]; then
    pass "$label: the typo'd entry dcos/** resolves to no path in the checkout"
  else
    fail "$label: the typo'd entry dcos/** resolves to no path in the checkout" \
      "$dest/dcos unexpectedly exists"
  fi

  local siblings entry
  siblings=""
  while IFS= read -r -d '' entry; do
    siblings="${siblings}$(basename "$entry")"$'\n'
  done < <(find "$dest" -maxdepth 1 -mindepth 1 -not -name '.git' -print0 2>/dev/null)
  if printf '%s' "$siblings" | grep -qx 'docs'; then
    pass "$label: the top-level checkout (the closest existing ancestor to the typo'd entry) surfaces docs/ as a sibling"
  else
    fail "$label: the top-level checkout (the closest existing ancestor to the typo'd entry) surfaces docs/ as a sibling" \
      "top-level entries found: ${siblings:-<none>}"
  fi

  # The discriminating check: run the WHOLE extracted block (not just the
  # four git lines), so a validator co-located in the same fenced block
  # actually gets exercised, and a recipe with no validator at all — which
  # the checks above cannot distinguish from one with a validator, since
  # both leave the same git-level trace — is caught here instead.
  local home_scratch
  home_scratch="$(mktemp -d "$WORK/home.XXXXXX")"
  if run_whole_block "$block" "$UPSTREAM" "$home_scratch" "sparse-clone-oracle-src" '"docs/**" "dcos/**"'; then
    # Sentinel presence, not raw exit status: the block's LAST command can
    # legitimately exit non-zero (e.g. a per-source failure signal an outer
    # loop tolerates) while still reaching the end — only an early `exit`
    # skips the sentinel appended after the substituted script.
    if printf '%s' "$WHOLE_BLOCK_OUT" | grep -qF "$WHOLE_BLOCK_SENTINEL"; then
      pass "$label: the extracted block does not exit the shell on a validation failure (other sources' seeds proceed)"
    else
      fail "$label: the extracted block does not exit the shell on a validation failure (other sources' seeds proceed)" \
        "sentinel not reached; exit status: $WHOLE_BLOCK_RC; combined output: ${WHOLE_BLOCK_OUT:-<empty>}"
    fi
    if printf '%s' "$WHOLE_BLOCK_OUT" | grep -qF 'dcos'; then
      pass "$label: the validator's output names the offending entry (dcos/**)"
    else
      fail "$label: the validator's output names the offending entry (dcos/**)" \
        "combined output: ${WHOLE_BLOCK_OUT:-<empty>}"
    fi
    if printf '%s' "$WHOLE_BLOCK_OUT" | grep -qF 'docs'; then
      pass "$label: the validator's output lists docs/ as a sibling"
    else
      fail "$label: the validator's output lists docs/ as a sibling" \
        "combined output: ${WHOLE_BLOCK_OUT:-<empty>}"
    fi
  else
    fail "$label: the extracted block does not exit the shell on a validation failure (other sources' seeds proceed)" "$WHOLE_BLOCK_ERR"
    fail "$label: the validator's output names the offending entry (dcos/**)" "$WHOLE_BLOCK_ERR"
    fail "$label: the validator's output lists docs/ as a sibling" "$WHOLE_BLOCK_ERR"
  fi
}

# ============================================================================
# Fixture self-check
# ============================================================================
section "fixture self-check"

UPSTREAM="$WORK/upstream"
build_upstream_repo "$UPSTREAM"

if [ -f "$UPSTREAM/docs/a.md" ] && [ -f "$UPSTREAM/docs/sub/b.md" ] \
  && [ -f "$UPSTREAM/src/main.py" ] && [ -f "$UPSTREAM/src/lib/util.py" ] \
  && [ -d "$UPSTREAM/.git" ]; then
  pass "the scratch upstream repo has the intended docs/ and src/ trees"
else
  fail "the scratch upstream repo has the intended docs/ and src/ trees" "$(find "$UPSTREAM" 2>&1)"
fi

if [ -f "$SCHEMA" ]; then
  pass "the schema under test exists at the expected path"
else
  fail "the schema under test exists at the expected path" "not found: $SCHEMA"
fi

# ============================================================================
# Schema: files_of_interest accepts non-empty-string arrays, rejects a
# non-array value and an array containing an empty string
# ============================================================================
section "schema — files_of_interest shape"

write_source_doc "$WORK/valid-absent.json" 'null'
write_source_doc "$WORK/valid-empty-array.json" '{"files_of_interest": []}'
write_source_doc "$WORK/valid-populated.json" '{"files_of_interest": ["docs/**", "src/auth.py"]}'
write_source_doc "$WORK/invalid-non-array-string.json" '{"files_of_interest": "docs/**"}'
write_source_doc "$WORK/invalid-non-array-object.json" '{"files_of_interest": {}}'
write_source_doc "$WORK/invalid-empty-string-entry.json" '{"files_of_interest": ["docs/**", ""]}'

fixture_ok=true
for f in valid-absent valid-empty-array valid-populated invalid-non-array-string invalid-non-array-object invalid-empty-string-entry; do
  if ! jq empty "$WORK/$f.json" 2>/dev/null; then
    fixture_ok=false
    fail "fixture $f.json is well-formed JSON"
  fi
done
$fixture_ok && pass "every schema fixture is well-formed JSON"

if [ "$HAVE_CJS" -eq 1 ]; then
  schema_accepts "files_of_interest absent still validates" "$WORK/valid-absent.json"
  schema_accepts "files_of_interest: [] (empty array) validates" "$WORK/valid-empty-array.json"
  schema_accepts "files_of_interest: [non-empty strings] validates" "$WORK/valid-populated.json"

  schema_rejects "files_of_interest as a bare string (non-array) is rejected" "$WORK/invalid-non-array-string.json"
  schema_rejects "files_of_interest as an object (non-array) is rejected" "$WORK/invalid-non-array-object.json"
  schema_rejects "files_of_interest containing an empty string is rejected" "$WORK/invalid-empty-string-entry.json"

  for f in "$REPO_ROOT"/examples/*/research/source-paths.json; do
    [ -f "$f" ] || continue
    schema_accepts "still validates: ${f#"$REPO_ROOT"/}" "$f"
  done
  if [ -f "$TEMPLATE" ]; then
    schema_accepts "still validates: ${TEMPLATE#"$REPO_ROOT"/}" "$TEMPLATE"
  fi
fi

# ============================================================================
# Reference-doc recipe shape + executed recipe (both cache-seeding.md and
# cache-and-clone.md)
# ============================================================================
CS_DEST="$WORK/checkouts/cs-dest"
CC_DEST="$WORK/checkouts/cc-dest"
mkdir -p "$WORK/checkouts"

test_reference_file "cache-seeding.md Step 3.5" "$CACHE_SEEDING" \
  '^## Step 3\.5' '^## Step 3\.6' "$CS_DEST"

test_reference_file "cache-and-clone.md step 6" "$CACHE_AND_CLONE" \
  '^6\. \*\*Cache-miss offer' '^7\. \*\*Pre-flight inventory' "$CC_DEST"

# ============================================================================
# Empty/absent files_of_interest ⇒ byte-identical to the pre-chunk baseline
# shallow-clone recipe (no behavior change on that path)
# ============================================================================
section "empty/absent files_of_interest leaves the existing shallow-clone recipe untouched"

cs_hash="$(baseline_block_hash "$CACHE_SEEDING" 'atomic-rename idiom')"
if [ "$cs_hash" = "$CS_BASELINE_SHA256" ]; then
  pass "cache-seeding.md's unconditional shallow-clone recipe is byte-identical to the pre-chunk baseline"
else
  fail "cache-seeding.md's unconditional shallow-clone recipe is byte-identical to the pre-chunk baseline" \
    "expected sha256 $CS_BASELINE_SHA256, got ${cs_hash:-<empty: block not found>}"
fi

cc_hash="$(baseline_block_hash "$CACHE_AND_CLONE" 'clone via the same atomic-rename idiom')"
if [ "$cc_hash" = "$CC_BASELINE_SHA256" ]; then
  pass "cache-and-clone.md's unconditional shallow-clone recipe is byte-identical to the pre-chunk baseline"
else
  fail "cache-and-clone.md's unconditional shallow-clone recipe is byte-identical to the pre-chunk baseline" \
    "expected sha256 $CC_BASELINE_SHA256, got ${cc_hash:-<empty: block not found>}"
fi

# ============================================================================
# Doctrine consistency: 02-artifact-contract.md's entry shape documents the
# field; 03-engine.md's own State schema section (not just the sparse-
# cloning section that links to it) names it and points at source-paths.json
# ============================================================================
section "doctrine consistency — files_of_interest documented where the entry shape and state schema live"

entry_shape_flat="$(normalize "$(section_between "$ARTIFACT_CONTRACT" '^### source-paths\.json entry shape' '^### Body')")"
if [ -n "$entry_shape_flat" ]; then
  pass "02-artifact-contract.md's source-paths.json entry shape section is present"
  if printf '%s' "$entry_shape_flat" | grep -qF 'files_of_interest'; then
    pass "02-artifact-contract.md's entry shape section documents files_of_interest"
  else
    fail "02-artifact-contract.md's entry shape section documents files_of_interest"
  fi
else
  fail "02-artifact-contract.md's source-paths.json entry shape section is present"
  fail "02-artifact-contract.md's entry shape section documents files_of_interest" "prerequisite section not found"
fi

state_schema_flat="$(normalize "$(section_between "$ENGINE_DOC" '^## State schema' '^## Pre-approval validation')")"
if [ -n "$state_schema_flat" ]; then
  pass "03-engine.md's ## State schema section is present"
  if printf '%s' "$state_schema_flat" | grep -qF 'files_of_interest'; then
    pass "03-engine.md's State schema section names files_of_interest"
  else
    fail "03-engine.md's State schema section names files_of_interest"
  fi
  if printf '%s' "$state_schema_flat" | grep -qiE 'files_of_interest.{0,250}source-paths\.json|source-paths\.json.{0,250}files_of_interest'; then
    pass "03-engine.md's State schema section points files_of_interest at source-paths.json"
  else
    fail "03-engine.md's State schema section points files_of_interest at source-paths.json"
  fi
else
  fail "03-engine.md's ## State schema section is present"
  fail "03-engine.md's State schema section names files_of_interest" "prerequisite section not found"
  fail "03-engine.md's State schema section points files_of_interest at source-paths.json" "prerequisite section not found"
fi

# ============================================================================
# Preservation: json/doctrine gates currently pass
# ============================================================================
# This section originally also asserted verify.sh byte-identical to this
# chunk's own pre-chunk baseline (criterion 6's preservation half — true at
# the time, since this chunk's own diff never touched verify.sh). Retired
# 2026-09-06: a later chunk on this same feature branch re-stamps verify.sh's
# Check 6/8 content by roadmap design (verify.sh is edited in exactly two
# chunks total, this being neither of them) — a hash pinned against a SHA
# from before that re-stamp can never be true again, in this chunk or any
# later one, so keeping the assertion would permanently red this oracle
# rather than verify anything about this chunk's own feature.
section "preservation — json and doctrine gates currently pass"

json_out="$(bash "$CI_LOCAL" json 2>&1)"
json_rc=$?
if [ "$json_rc" -eq 0 ]; then
  pass "bash scripts/ci-local.sh json passes on the repo as it stands"
else
  fail "bash scripts/ci-local.sh json passes on the repo as it stands" "$json_out"
fi

doctrine_out="$(bash "$CI_LOCAL" doctrine 2>&1)"
doctrine_rc=$?
if [ "$doctrine_rc" -eq 0 ]; then
  pass "bash scripts/ci-local.sh doctrine passes on the repo as it stands"
else
  fail "bash scripts/ci-local.sh doctrine passes on the repo as it stands" "$doctrine_out"
fi

# ----- summary -------------------------------------------------------------

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
