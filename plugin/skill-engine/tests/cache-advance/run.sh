#!/usr/bin/env bash
# Feature-scoped test runner for the git-managed cache's in-place advance
# recipe — the fenced bash block one of four engine reference docs carries
# that moves a source's local clone forward from an old upstream SHA to a
# new one without ever deleting the old commit from history, so the set of
# paths that changed between the two SHAs stays locally computable.
#
# This file designs and freezes the recipe's execution contract, since
# nothing upstream pins it. These reference docs describe a workflow an
# agent performs step by step, substituting angle-bracket prose
# placeholders (`<source_id>`, `<url>`, `<ref>`, ...) textually into each
# fenced block it runs fresh — there is no continuous shell session across
# steps, so a placeholder is never read back as an inherited environment
# variable. The already-shipped clone recipe in cache-and-clone.md is the
# precedent (`case "<source_id>" in`, `git ls-remote -- "<url>" "<ref>"`,
# `dest="$HOME/.cache/skill-engine/git-managed/<source_id>-$sha"`): only
# `$HOME` and script-local values computed within that one invocation
# (`$sha`, `$dest`, `$tmpdir`) are real shell variables; `<source_id>`,
# `<url>`, and `<ref>` are substituted before the block ever runs.
#
# The advance recipe's `<source_id>`, `<old_sha>`, and `<new_sha>` are the
# same kind of value — already known or already computed by the
# orchestrating agent (old SHA from persisted lifecycle state, new SHA
# from the upstream probe drift-detection-and-phases.md's Phase 1
# documents as a prior step) before this recipe is ever invoked. So this
# harness extracts the fenced block as a template, textually substitutes
# every `<source_id>` / `<old_sha>` / `<new_sha>` occurrence with the
# fixture's concrete values (generalizing to whatever other angle-bracket
# placeholders the real recipe turns out to use), and only then runs the
# result as a standalone script under
#
#   ( cd <scratch-contextualizer-root> && \
#     env HOME=<scratch-home> CLAUDE_PLUGIN_ROOT=<real-plugin-root> \
#     bash <substituted-script> )
#
# HOME is overridden (never SKILL_ENGINE_CACHE_ROOT) because the recipe's
# `-C` targets must be literal `$HOME/.cache/skill-engine/...` text for the
# doctrine git-verb lint's cache-scoped exception to recognize them — a
# literal that resolves through any other variable does not qualify, so a
# scratch cache root can only be reached by relocating HOME itself.
# CLAUDE_PLUGIN_ROOT is handed through unchanged (not relocated) because it
# names the real, already-installed discover_inventory.py, which a recipe
# is free to shell out to. CTX_ROOT is handed through as the scratch
# contextualizer root the inventory belongs under. Those three are the
# genuinely-environment-variable values in this contract;
# refresh-probe-budget/run.sh:427 already runs a refresh reference fence
# with CTX_ROOT supplied the same way.
#
# The recipe owns writing `$CTX_ROOT/research/.discover-inventory.json`.
# cache-and-clone.md step 7 documents this file as gitignored runtime state,
# "not a reference artifact, and not subject to any verify.sh check",
# re-derived and fully overwritten every run — so unlike
# `source-paths.json` it is never copy-on-write staged, and there is no
# `$CTX_PROPOSED` layer for it to route around. It does not follow that the
# path may be written bare-relative, which is what this comment asserted
# until 2026-09-12 on the grounds that "every mention of it anywhere in this
# codebase uses the same bare relative form": review/SKILL.md:71 already
# read it as `<install>/<name>-context/research/...`, so the two routes
# disagreed, and the bare form silently resolved against whatever working
# directory the caller had. Being gitignored is what made that dangerous
# rather than harmless — `git status` never mentions a stray copy, and the
# inventory a reader consumes is a *consumed input*, not an artifact, so a
# stale one yields a wrong and plausible re-emit candidate count.
#
# So this harness hands the recipe CTX_ROOT, runs it from a working
# directory that is deliberately not that root, and reads the file back from
# `$CTX_ROOT/research/.discover-inventory.json`. The helper now requires
# that parent directory to exist rather than manufacturing it, so each
# fixture below creates `research/` the way a real contextualizer root
# already carries it. The file's content is asserted only by outcome, in the shape
# already frozen elsewhere and already emitted by this repo's
# discover_inventory.py: a top-level object keyed by
# source_id, each value carrying a `since_last_check` of
# `{from_sha, to_sha, files: [{path, changes}, ...]}`. How that JSON gets
# produced — shelling out to discover_inventory.py, or building it
# directly — is left open; only `.[<source_id>].since_last_check` and its
# `from_sha`/`to_sha`/`files[].path` are checked.
#
# A hazard for whichever mechanism is chosen: discover_inventory.py's
# current --last-checked-sha path is git-log-based, and a directory that
# reached <new_sha> via `git fetch --depth=1` on top of an already-shallow
# clone puts <new_sha> in `.git/shallow` as its own parentless boundary —
# so a log-range walk between <old_sha> and <new_sha> silently drops
# deleted paths and reports every surviving path as added, not modified,
# even though both SHAs are individually resolvable. `git diff --name-only
# <old_sha> <new_sha>` is unaffected by the shallow boundary and can be fed
# to discover_inventory.py's `--since-json <file>` flag (a file path, not
# inline JSON) instead — the same pattern cache-and-clone.md's own
# gh-api pre-flight branch already uses for the no-cache case.
#
# The recipe is located by scanning every declared-scope reference for one
# occurrence of a paired sentinel comment (the same paired-HTML-comment
# family doctrine.sh already parses elsewhere), never by assuming which of
# the four files carries it:
#
#   <!-- doctrine:cache-advance-recipe:start -->
#   ...fenced bash block...
#   <!-- doctrine:cache-advance-recipe:end -->
#
# Zero, or more than one, sentinel-delimited block anywhere in scope is a
# hard failure in its own right — not a silent skip, and every assertion
# that depends on actually running the recipe reports an explicit FAIL
# rather than being quietly omitted, so an empty extraction can never look
# like a passing suite.
#
# Fixture style: a real bare-ish upstream repo built with `git init` plus
# local commits under a tmpdir (fully offline), a cache seeded by
# `git clone --depth=1 file://<upstream>` followed by `checkout --detach`
# — a shallow clone left in the detached-HEAD state a CI checkout runs in,
# not a fresh clone still on a branch. The must-reject input is a fetch
# aimed at a since-broken origin; the no-op-re-run input additionally
# deletes the upstream entirely before re-invoking the recipe, so a recipe
# that still attempts a real fetch when nothing moved fails loudly instead
# of coincidentally looking identical to one that correctly skipped it.
#
# -e is intentionally omitted: every assertion runs and reports, not abort
# at the first red one. Every tmpdir this file creates is removed on exit.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_ROOT/.." && pwd)"

SENTINEL_START='<!-- doctrine:cache-advance-recipe:start -->'
SENTINEL_END='<!-- doctrine:cache-advance-recipe:end -->'

# The four references declared as this recipe's possible homes. Order is
# irrelevant — every one of them is searched, and exactly one sentinel pair
# must turn up across the whole set.
SCOPE_FILES=(
  "skills/refresh/references/tool-and-output-mechanics.md"
  "skills/refresh/references/drift-detection-and-phases.md"
  "skills/discover/references/cache-and-clone.md"
  "docs/03-engine.md"
)

pass_count=0
fail_count=0

section() {
  printf '\n── %s ──\n' "$1"
}

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

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/cache-advance.XXXXXX")"
cleanup() {
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

# Every recipe runs from here: a directory that is no contextualizer root and
# has no research/ of its own, so a recipe that depended on its caller's
# working directory would write somewhere visible to the assertions as a
# miss rather than silently land on its feet. See run_recipe below.
NEUTRAL_CWD="$TMPROOT/neutral-cwd"
mkdir -p "$NEUTRAL_CWD"

# ---- generic helpers --------------------------------------------------

sha256_of_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# dir_fingerprint <dir> — a content fingerprint (path + sha256 of bytes) of
# every regular file under <dir>, including .git internals, so the
# no-op-re-run check can tell "genuinely unchanged" from "coincidentally
# looks the same" (a same-size rewrite would fool a byte-count-only
# fingerprint). Absence of <dir> fingerprints to a fixed sentinel value
# rather than silently hashing nothing, so a since-deleted directory can
# never be mistaken for an unchanged one.
dir_fingerprint() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    printf 'ORACLE-MISSING-DIRECTORY\n' | sha256_of_stdin
    return
  fi
  ( cd "$dir" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s ' "$f"
      sha256_of_file "$f"
    done ) | sha256_of_stdin
}

# sibling_dirs <cache-git-managed-dir> <source_id> — sorted list of
# <source_id>-* directories directly under the cache's git-managed root.
sibling_dirs() {
  find "$1" -mindepth 1 -maxdepth 1 -type d -name "${2}-*" 2>/dev/null | LC_ALL=C sort
}

# upstream_init_commit_a <upstream-dir> — creates a fresh, non-bare git
# repo with one commit (a two-file tree: a top-level file and a nested
# one), and echoes its SHA. Fully offline; the repo is fetched from later
# via a file:// URL, never pushed into.
upstream_init_commit_a() {
  local upstream="$1"
  git init -q "$upstream"
  git -C "$upstream" checkout -q -b main
  mkdir -p "$upstream/dirX"
  printf 'one\n' > "$upstream/fileA.txt"
  printf 'keep\n' > "$upstream/dirX/fileB.txt"
  git -C "$upstream" add -A
  git -C "$upstream" -c user.email=oracle@example.invalid -c user.name=oracle \
    commit -q -m "commit A"
  git -C "$upstream" rev-parse HEAD
}

# upstream_add_commit_b <upstream-dir> — modifies the top-level file, adds
# a new one, and removes the nested one, then echoes the new HEAD SHA. The
# resulting change set is unambiguous under any name-only diff (an add, a
# modify, and a remove — no rename, whose two-sided representation is an
# open question this recipe explicitly hands to a later inventory change,
# not this one).
upstream_add_commit_b() {
  local upstream="$1"
  printf 'one\ntwo\n' > "$upstream/fileA.txt"
  printf 'new\n' > "$upstream/fileC.txt"
  rm -f "$upstream/dirX/fileB.txt"
  rmdir "$upstream/dirX" 2>/dev/null || true
  git -C "$upstream" add -A
  git -C "$upstream" -c user.email=oracle@example.invalid -c user.name=oracle \
    commit -q -m "commit B"
  git -C "$upstream" rev-parse HEAD
}

# seed_cache_shallow <upstream-dir> <cache-git-managed-dir> <source_id> <sha>
# — a --depth=1 clone from a file:// URL (a bare local path silently
# ignores --depth) left in a detached HEAD, the state a CI checkout runs
# in and a fresh `git clone` does NOT leave you in on its own.
seed_cache_shallow() {
  local upstream="$1" cache_gm="$2" source_id="$3" sha="$4"
  mkdir -p "$cache_gm"
  git clone -q --depth=1 "file://$upstream" "$cache_gm/${source_id}-${sha}" || return 1
  git -C "$cache_gm/${source_id}-${sha}" checkout -q --detach HEAD || return 1
}

# plant_gc_markers <cache-git-managed-dir> <scratch-home> <fixture-root> —
# an unrelated cache sibling, a symlink escaping the cache root to a
# canary file outside it entirely, and a sentinel file directly under HOME
# but outside .cache/skill-engine/. Populates UNRELATED_DIR, ESCAPE_LINK,
# OUTSIDE_TARGET_DIR, and OUTSIDE_HOME_SENTINEL for the caller to re-check
# after the recipe runs.
plant_gc_markers() {
  local cache_gm="$1" home="$2" fxroot="$3"
  UNRELATED_DIR="$cache_gm/unrelated-source-deadbeef"
  mkdir -p "$UNRELATED_DIR"
  printf 'do not touch\n' > "$UNRELATED_DIR/marker.txt"
  OUTSIDE_TARGET_DIR="$fxroot/outside-cache-canary"
  mkdir -p "$OUTSIDE_TARGET_DIR"
  printf 'canary content\n' > "$OUTSIDE_TARGET_DIR/canary.txt"
  ESCAPE_LINK="$cache_gm/escape-link"
  ln -s "$OUTSIDE_TARGET_DIR" "$ESCAPE_LINK"
  OUTSIDE_HOME_SENTINEL="$home/outside-cache-sentinel.txt"
  printf 'sentinel\n' > "$OUTSIDE_HOME_SENTINEL"
}

# gc_markers_intact — true (rc 0) only if every artifact plant_gc_markers
# left behind is byte-identical to what it planted.
gc_markers_intact() {
  local u e c s
  u="$(cat "$UNRELATED_DIR/marker.txt" 2>/dev/null || echo "<missing>")"
  e="$(readlink "$ESCAPE_LINK" 2>/dev/null || echo "<missing>")"
  c="$(cat "$OUTSIDE_TARGET_DIR/canary.txt" 2>/dev/null || echo "<missing>")"
  s="$(cat "$OUTSIDE_HOME_SENTINEL" 2>/dev/null || echo "<missing>")"
  [ "$u" = "do not touch" ] && [ "$e" = "$OUTSIDE_TARGET_DIR" ] \
    && [ "$c" = "canary content" ] && [ "$s" = "sentinel" ]
}

# substitute_placeholders <template-file> <out-file> <source_id> <old_sha> <new_sha>
# — the textual substitution an orchestrating agent performs before running
# one of these reference docs' fenced blocks: every `<source_id>`,
# `<old_sha>`, and `<new_sha>` occurrence in the template is replaced with
# the caller's concrete value. Values here are always plain hex SHAs or a
# kebab-case id, so a bare sed substitution is safe (no sed-metacharacter
# escaping needed).
substitute_placeholders() {
  local template="$1" out="$2" source_id="$3" old_sha="$4" new_sha="$5"
  sed -e "s/<source_id>/${source_id}/g" \
      -e "s/<old_sha>/${old_sha}/g" \
      -e "s/<new_sha>/${new_sha}/g" \
      "$template" > "$out"
}

# run_recipe <template> <home> <source_id> <old_sha> <new_sha> <ctx_root>
# — the frozen invocation contract: substitute the prose placeholders with
# this call's concrete values, then run the result with HOME,
# CLAUDE_PLUGIN_ROOT and CTX_ROOT as real environment variables, from a
# working directory that is deliberately NOT <ctx_root>.
#
# The neutral CWD is the whole point. This harness used to `cd "$ctx_root"`
# first, which made every recipe-driven assertion below pass under a
# precondition the harness itself supplied and the published recipe never
# stated — so a caller who followed the recipe from anywhere else was
# following it correctly and still wrote the inventory to the wrong place,
# with the suite green. The contract under test was strictly stronger than
# the contract as published, which is exactly the configuration in which a
# suite cannot catch that class of bug. Running from NEUTRAL_CWD asks the
# same question a real caller does: given only these three variables, does
# the inventory land under the contextualizer?
#
# Sets RUN_OUT (combined stdout+stderr) and RUN_RC (exit code).
RUN_OUT=""
RUN_RC=0
run_recipe() {
  local template="$1" home="$2" source_id="$3" old_sha="$4" new_sha="$5" ctx_root="$6"
  local invocation
  # No trailing suffix after the X's: BSD mktemp (macOS) only recognizes a
  # trailing-X template, so "invoke-XXXXXX.sh" creates the literal,
  # unexpanded file "invoke-XXXXXX.sh" once and then collides on every
  # later call. Bash does not need a .sh extension to execute the file.
  invocation="$(mktemp "$TMPROOT/invoke-XXXXXX")"
  substitute_placeholders "$template" "$invocation" "$source_id" "$old_sha" "$new_sha"
  RUN_OUT="$(cd "$NEUTRAL_CWD" && env HOME="$home" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    CTX_ROOT="$ctx_root" bash "$invocation" 2>&1)"
  RUN_RC=$?
}

# substitute_named_placeholders <template-file> <out-file> <name1> <value1> [<name2> <value2> ...]
# — the same textual substitution as substitute_placeholders above, but
# generic over however many placeholder/value pairs a given block turns
# out to need, for blocks (like the cache-hit check below) whose exact
# placeholder names nothing pins yet. Values here are always plain hex
# SHAs or kebab-case ids, so a bare sed substitution is safe.
substitute_named_placeholders() {
  local template="$1" out="$2"
  shift 2
  cp "$template" "$out"
  while [ "$#" -ge 2 ]; do
    local name="$1" value="$2" tmp
    tmp="${out}.subst"
    sed "s/<${name}>/${value}/g" "$out" > "$tmp" && mv "$tmp" "$out"
    shift 2
  done
}

# mk_cache_entry <cache-git-managed-dir> <source_id> <sha> — a directory
# that looks like a valid warm git-managed cache entry to the DISCOVER
# pre-flight probe (name + .git/ present). The probe only checks the
# directory-name suffix and .git/ presence, never git validity, so no
# real git repository is needed for this section's fixtures.
mk_cache_entry() {
  mkdir -p "$1/${2}-${3}/.git"
}

# run_hit_check <template> <home> <source_id> <resolved_name> <resolved_value>
# — substitutes <source_id> and the detected resolved-SHA placeholder,
# then runs the block plus one appended line reporting the block's own
# `cache_dir` variable: the name already used for exactly this purpose in
# today's committed probe, frozen here as the observable "which directory
# (if any) counts as the hit" contract a SHA-aware rewrite is expected to
# preserve. Sets HIT_CHECK_OUT (the reported cache_dir, or empty on a
# miss) and HIT_CHECK_RC.
HIT_CHECK_OUT=""
HIT_CHECK_RC=0
run_hit_check() {
  local template="$1" home="$2" source_id="$3" resolved_name="$4" resolved_value="$5"
  local subst combined
  subst="$(mktemp "$TMPROOT/hitcheck-subst-XXXXXX")"
  substitute_named_placeholders "$template" "$subst" source_id "$source_id" "$resolved_name" "$resolved_value"
  combined="$(mktemp "$TMPROOT/hitcheck-run-XXXXXX")"
  {
    cat "$subst"
    printf '\n'
    # shellcheck disable=SC2016 # literal text appended to the combined
    # script — it must expand later, when that script runs, not now.
    printf '%s\n' 'printf "%s" "${cache_dir:-}"'
  } > "$combined"
  HIT_CHECK_OUT="$(env HOME="$home" bash "$combined" 2>"$TMPROOT/hitcheck-err.txt")"
  HIT_CHECK_RC=$?
}

# extract_sentinel_block <label> <start-sentinel> <end-sentinel> <file...>
# — the generic sentinel-delimited fenced-block extractor shared by every
# section below that locates a fenced block inside the declared-scope
# references without assuming which file holds it. Requires exactly one
# start/end pair, in that order, across every given file; a malformed or
# absent pair is reported under <label> and the function returns non-zero
# — a hard, clearly-labeled failure rather than a silent skip, the failure
# mode a naive "grep for absence" pipeline would otherwise reach
# vacuously. On success, writes the block body (fence delimiters stripped,
# syntax-checked with `bash -n`) to a fresh tmpfile and exposes its path
# via the global EXTRACTED_BLOCK.
EXTRACTED_BLOCK=""
extract_sentinel_block() {
  local label="$1" start_sentinel="$2" end_sentinel="$3"
  shift 3
  local -a files=("$@")
  local rel abs s_count e_count sl el
  local -a hit_files=() malformed=()
  local total_start=0 total_end=0
  local sole_file="" sole_start=0 sole_end=0
  EXTRACTED_BLOCK=""

  for rel in "${files[@]}"; do
    abs="$PLUGIN_ROOT/$rel"
    if [ ! -f "$abs" ]; then
      malformed+=("$rel: declared scope file does not exist")
      continue
    fi
    s_count="$(grep -c -F -- "$start_sentinel" "$abs")"
    e_count="$(grep -c -F -- "$end_sentinel" "$abs")"
    total_start=$((total_start + s_count))
    total_end=$((total_end + e_count))
    [ "$s_count" -eq 0 ] && [ "$e_count" -eq 0 ] && continue
    hit_files+=("$rel ($s_count start / $e_count end)")
    if [ "$s_count" -eq 1 ] && [ "$e_count" -eq 1 ]; then
      sl="$(grep -n -F -- "$start_sentinel" "$abs" | head -n1 | cut -d: -f1)"
      el="$(grep -n -F -- "$end_sentinel" "$abs" | head -n1 | cut -d: -f1)"
      if [ "$sl" -lt "$el" ]; then
        sole_file="$rel"
        sole_start="$sl"
        sole_end="$el"
      else
        malformed+=("$rel: end sentinel is not after start sentinel")
      fi
    else
      malformed+=("$rel: $s_count start / $e_count end sentinels (need exactly one of each)")
    fi
  done

  if [ "$total_start" -eq 0 ] && [ "$total_end" -eq 0 ]; then
    fail "$label" \
      "no ${start_sentinel} / ${end_sentinel} pair found in any declared-scope reference:" \
      "${files[@]}"
    return 1
  elif [ "$total_start" -ne 1 ] || [ "$total_end" -ne 1 ] || [ "${#malformed[@]}" -gt 0 ] || [ -z "$sole_file" ]; then
    fail "$label" \
      "total start sentinels: $total_start, total end sentinels: $total_end" \
      "files carrying a sentinel: ${hit_files[*]:-<none>}" \
      "${malformed[@]}"
    return 1
  fi

  local body
  body="$(sed -n "$((sole_start + 1)),$((sole_end - 1))p" "$PLUGIN_ROOT/$sole_file" | grep -vE '^[[:space:]]*```')"
  if [ -z "${body//[$'\t\r\n ']/}" ]; then
    fail "$label" "sentinel pair found in $sole_file but the block between them is empty"
    return 1
  fi

  local outfile
  outfile="$(mktemp "$TMPROOT/block-XXXXXX")"
  printf '%s\n' "$body" > "$outfile"
  if ! bash -n "$outfile" 2>"$TMPROOT/extract-syntax-err.txt"; then
    fail "$label" "extracted block from $sole_file is not valid shell:" "$(cat "$TMPROOT/extract-syntax-err.txt")"
    return 1
  fi

  pass "$label ($sole_file)"
  EXTRACTED_BLOCK="$outfile"
  return 0
}

# ---- recipe location ----------------------------------------------------

section "recipe present: exactly one sentinel-delimited advance recipe across the declared references"

HAVE_RECIPE=false
RECIPE_TEMPLATE=""
if extract_sentinel_block \
     "recipe present: exactly one sentinel-delimited advance recipe across the declared references" \
     "$SENTINEL_START" "$SENTINEL_END" "${SCOPE_FILES[@]}"; then
  HAVE_RECIPE=true
  RECIPE_TEMPLATE="$EXTRACTED_BLOCK"
fi

NO_RECIPE_REASON="cannot evaluate — no cache-advance recipe found (see 'recipe present' section above)"

# ---- in-place advance, changed-path list, and GC-on-success -------------
# One fixture, one execution of the recipe, feeding three logical sections
# below: the advance itself, the staged inventory it produces, and the
# garbage-collection guarantee that only the superseded sibling is gone.

section "in-place advance: one directory survives, named for the new SHA, both commits resolvable, no git clone issued"

FX1_READY=false
if ! $HAVE_RECIPE; then
  fail "in-place advance leaves exactly one <id>-<new-sha> directory with both commits resolvable and no git clone" \
    "$NO_RECIPE_REASON"
else
  FX1="$TMPROOT/fx-success"
  UPSTREAM1="$FX1/upstream"
  mkdir -p "$FX1"
  SHA_A1="$(upstream_init_commit_a "$UPSTREAM1")"
  HOME1="$FX1/home"
  CACHE_GM1="$HOME1/.cache/skill-engine/git-managed"
  SOURCE_ID1="acme-widgets"

  if ! seed_cache_shallow "$UPSTREAM1" "$CACHE_GM1" "$SOURCE_ID1" "$SHA_A1"; then
    fail "in-place advance leaves exactly one <id>-<new-sha> directory with both commits resolvable and no git clone" \
      "fixture setup failed: could not seed a --depth=1 scratch cache from the scratch upstream"
  else
    SHA_B1="$(upstream_add_commit_b "$UPSTREAM1")"
    WANT_PATHS1="$(git -C "$UPSTREAM1" diff --name-only "$SHA_A1" "$SHA_B1" | LC_ALL=C sort -u)"
    # A scratch stand-in for the contextualizer root, handed to the recipe
    # as CTX_ROOT — where its `$CTX_ROOT/research/...` write lands. Not a staging directory: research/.discover-inventory.json is
    # never copy-on-write staged, unlike source-paths.json. research/ is
    # created here because a real contextualizer root already has one and the
    # helper no longer manufactures a missing parent.
    CTX_ROOT1="$FX1/ctxroot"
    mkdir -p "$CTX_ROOT1/research"
    plant_gc_markers "$CACHE_GM1" "$HOME1" "$FX1"

    run_recipe "$RECIPE_TEMPLATE" "$HOME1" "$SOURCE_ID1" "$SHA_A1" "$SHA_B1" "$CTX_ROOT1"

    if [ "$RUN_RC" -eq 0 ]; then
      pass "the recipe exits 0 advancing a shallow, detached-HEAD cache from A to B"
    else
      fail "the recipe exits 0 advancing a shallow, detached-HEAD cache from A to B" \
        "exit: $RUN_RC" "output:" "$RUN_OUT"
    fi

    expected_dir1="$CACHE_GM1/${SOURCE_ID1}-${SHA_B1}"
    siblings1="$(sibling_dirs "$CACHE_GM1" "$SOURCE_ID1")"
    sibling_count1="$(printf '%s' "$siblings1" | grep -c . || true)"
    if [ "$sibling_count1" -eq 1 ] && [ "$siblings1" = "$expected_dir1" ]; then
      pass "exactly one <id>-<sha> directory remains, named for the new SHA"
      FX1_READY=true
    else
      fail "exactly one <id>-<sha> directory remains, named for the new SHA" \
        "expected: $expected_dir1" "found:" "${siblings1:-<none>}"
    fi

    if [ -d "$expected_dir1" ] && git -C "$expected_dir1" cat-file -e "$SHA_A1" 2>/dev/null; then
      pass "the old SHA is still resolvable inside the advanced directory (git cat-file -e)"
    else
      fail "the old SHA is still resolvable inside the advanced directory (git cat-file -e)" "sha: $SHA_A1"
    fi

    if [ -d "$expected_dir1" ] && git -C "$expected_dir1" cat-file -e "$SHA_B1" 2>/dev/null; then
      pass "the new SHA is resolvable inside the advanced directory (git cat-file -e)"
    else
      fail "the new SHA is resolvable inside the advanced directory (git cat-file -e)" "sha: $SHA_B1"
    fi

    recipe_verbs="$(bash "$TESTS_ROOT/lib/git_verb_scan.sh" --root "" "$RECIPE_TEMPLATE" 2>/dev/null | awk -F: '{print $3}')"
    if printf '%s\n' "$recipe_verbs" | grep -qx 'clone'; then
      fail "the recipe issues no git clone" "candidate verbs in the extracted recipe: ${recipe_verbs:-<none>}"
    else
      pass "the recipe issues no git clone"
    fi
    # A raw `fetch` verb in the extracted block is the direct signal; a
    # `cache-git.sh` mention is the same claim made once the recipe
    # delegates its git invocations to that shared helper instead of
    # spelling them out inline (chunk 08-cache-git-helper).
    if printf '%s\n' "$recipe_verbs" | grep -qx 'fetch' || grep -qF 'cache-git.sh' "$RECIPE_TEMPLATE"; then
      pass "the recipe advances via git fetch, not a fresh clone"
    else
      fail "the recipe advances via git fetch, not a fresh clone" \
        "candidate verbs in the extracted recipe: ${recipe_verbs:-<none>}"
    fi

    # ---- changed-path list -------------------------------------------
    section "changed-path list: the staged inventory's since_last_check matches the A→B diff"

    inv_file1="$CTX_ROOT1/research/.discover-inventory.json"
    if [ ! -f "$inv_file1" ]; then
      fail "the staged inventory carries a non-null since_last_check for the advanced source" \
        "not found: $inv_file1"
    else
      since_json1="$(jq -c --arg sid "$SOURCE_ID1" '.[$sid].since_last_check // "null"' "$inv_file1" 2>"$FX1/jq-err.txt")"
      if [ -z "$since_json1" ] || [ "$since_json1" = '"null"' ] || [ "$since_json1" = "null" ]; then
        fail "the staged inventory carries a non-null since_last_check for the advanced source" \
          "$inv_file1 : .[\"$SOURCE_ID1\"].since_last_check is null or missing" \
          "$(cat "$FX1/jq-err.txt" 2>/dev/null)"
      else
        pass "the staged inventory carries a non-null since_last_check for the advanced source"

        got_from1="$(jq -r --arg sid "$SOURCE_ID1" '.[$sid].since_last_check.from_sha' "$inv_file1")"
        got_to1="$(jq -r --arg sid "$SOURCE_ID1" '.[$sid].since_last_check.to_sha' "$inv_file1")"
        if [ "$got_from1" = "$SHA_A1" ] && [ "$got_to1" = "$SHA_B1" ]; then
          pass "since_last_check.from_sha/to_sha match the advance's old and new SHAs"
        else
          fail "since_last_check.from_sha/to_sha match the advance's old and new SHAs" \
            "expected: $SHA_A1 -> $SHA_B1" "got: $got_from1 -> $got_to1"
        fi

        got_paths1="$(jq -r --arg sid "$SOURCE_ID1" '.[$sid].since_last_check.files[]?.path' "$inv_file1" 2>/dev/null | LC_ALL=C sort -u)"
        if [ "$got_paths1" = "$WANT_PATHS1" ]; then
          pass "since_last_check.files[].path equals the set of paths that differ between A and B"
        else
          fail "since_last_check.files[].path equals the set of paths that differ between A and B" \
            "expected:" "$WANT_PATHS1" "got:" "${got_paths1:-<none>}"
        fi
      fi
    fi

    # ---- GC on success --------------------------------------------------
    section "GC guarantees: a successful advance removes only the superseded sibling"

    if [ -d "$HOME1/.cache/skill-engine" ] && [ -d "$CACHE_GM1" ]; then
      pass "the cache root is never removed by a successful advance"
    else
      fail "the cache root is never removed by a successful advance" \
        "missing: $HOME1/.cache/skill-engine or $CACHE_GM1"
    fi

    if gc_markers_intact; then
      pass "unrelated cache siblings and out-of-cache symlink targets survive a successful advance untouched"
    else
      fail "unrelated cache siblings and out-of-cache symlink targets survive a successful advance untouched" \
        "unrelated marker: $(cat "$UNRELATED_DIR/marker.txt" 2>/dev/null || echo "<missing>")" \
        "escape link target: $(readlink "$ESCAPE_LINK" 2>/dev/null || echo "<missing>")" \
        "canary content: $(cat "$OUTSIDE_TARGET_DIR/canary.txt" 2>/dev/null || echo "<missing>")" \
        "outside-HOME sentinel: $(cat "$OUTSIDE_HOME_SENTINEL" 2>/dev/null || echo "<missing>")"
    fi
  fi
fi

if ! $HAVE_RECIPE; then
  fail "the staged inventory's since_last_check matches the A→B diff" "$NO_RECIPE_REASON"
  fail "a successful advance removes only the superseded sibling" "$NO_RECIPE_REASON"
fi

# ---- no-op re-run ---------------------------------------------------------
# Run the same recipe a second time with no upstream movement — it must
# change nothing and must not even attempt a fetch. The upstream is
# deleted outright before this second call so a recipe that still tries a
# real fetch fails loudly instead of coincidentally looking like one that
# correctly skipped it — proving "fetches nothing" by more than exit code.

section "no-op re-run: an unmoved upstream fetches nothing and changes nothing"

if ! $HAVE_RECIPE; then
  fail "re-running the recipe with no upstream movement changes nothing and fetches nothing" "$NO_RECIPE_REASON"
elif ! $FX1_READY; then
  fail "re-running the recipe with no upstream movement changes nothing and fetches nothing" \
    "cannot evaluate — the prior in-place-advance fixture did not reach a stable post-advance state"
else
  noop_dir="$CACHE_GM1/${SOURCE_ID1}-${SHA_B1}"
  before_fp="$(dir_fingerprint "$noop_dir")"
  rm -rf "$UPSTREAM1"

  # Same scratch contextualizer root as the first run — re-derived and
  # fully overwritten every run is the documented contract for this file,
  # so reusing it here is exactly what a second real invocation would do.
  run_recipe "$RECIPE_TEMPLATE" "$HOME1" "$SOURCE_ID1" "$SHA_B1" "$SHA_B1" "$CTX_ROOT1"
  after_fp="$(dir_fingerprint "$noop_dir")"

  if [ "$RUN_RC" -eq 0 ]; then
    pass "re-running the recipe with no upstream movement (upstream now deleted) still exits 0"
  else
    fail "re-running the recipe with no upstream movement (upstream now deleted) still exits 0" \
      "exit: $RUN_RC" "output:" "$RUN_OUT"
  fi

  if [ "$before_fp" = "$after_fp" ]; then
    pass "the cache directory is byte-for-byte unchanged after the no-op re-run"
  else
    fail "the cache directory is byte-for-byte unchanged after the no-op re-run" \
      "fingerprint before: $before_fp" "fingerprint after: $after_fp"
  fi

  if printf '%s\n' "$RUN_OUT" | grep -qiE 'fatal|could not read from remote|does not appear to be a git repository'; then
    fail "no network call was attempted against the now-deleted upstream" "output:" "$RUN_OUT"
  else
    pass "no network call was attempted against the now-deleted upstream"
  fi
fi

# ---- must-reject: failed fetch --------------------------------------------

section "must-reject: a failed fetch leaves the old directory intact and touches nothing else"

if ! $HAVE_RECIPE; then
  fail "a failed fetch leaves the old directory intact, exits non-zero, and touches nothing else" "$NO_RECIPE_REASON"
else
  FX2="$TMPROOT/fx-failed-fetch"
  UPSTREAM2="$FX2/upstream"
  mkdir -p "$FX2"
  SHA_A2="$(upstream_init_commit_a "$UPSTREAM2")"
  HOME2="$FX2/home"
  CACHE_GM2="$HOME2/.cache/skill-engine/git-managed"
  SOURCE_ID2="acme-widgets"

  if ! seed_cache_shallow "$UPSTREAM2" "$CACHE_GM2" "$SOURCE_ID2" "$SHA_A2"; then
    fail "a failed fetch leaves the old directory intact, exits non-zero, and touches nothing else" \
      "fixture setup failed: could not seed a --depth=1 scratch cache from the scratch upstream"
  else
    # Commit B lands upstream only after the cache is seeded at A — seeding
    # from an upstream that already carries B would silently clone B under
    # a directory misnamed for A instead of exercising a real old-SHA cache.
    SHA_B2="$(upstream_add_commit_b "$UPSTREAM2")"
    old_dir2="$CACHE_GM2/${SOURCE_ID2}-${SHA_A2}"
    # Break the remote so the fetch this recipe issues cannot succeed —
    # the must-reject case a garbage-collection guarantee has to survive.
    git -C "$old_dir2" remote set-url origin "file://$FX2/no-such-upstream" >/dev/null 2>&1

    plant_gc_markers "$CACHE_GM2" "$HOME2" "$FX2"
    # A scratch stand-in for the contextualizer root handed to the recipe
    # — see CTX_ROOT1 above for why this is not a staging directory.
    CTX_ROOT2="$FX2/ctxroot"
    mkdir -p "$CTX_ROOT2/research"

    run_recipe "$RECIPE_TEMPLATE" "$HOME2" "$SOURCE_ID2" "$SHA_A2" "$SHA_B2" "$CTX_ROOT2"

    if [ "$RUN_RC" -ne 0 ]; then
      pass "the recipe exits non-zero when the fetch fails"
    else
      fail "the recipe exits non-zero when the fetch fails" "exit: $RUN_RC" "output:" "$RUN_OUT"
    fi

    if [ -d "$old_dir2" ] && git -C "$old_dir2" cat-file -e "$SHA_A2" 2>/dev/null; then
      pass "the old <id>-<sha> directory is intact and its SHA still resolvable after the failed fetch"
    else
      fail "the old <id>-<sha> directory is intact and its SHA still resolvable after the failed fetch" \
        "expected directory: $old_dir2"
    fi

    siblings2="$(sibling_dirs "$CACHE_GM2" "$SOURCE_ID2")"
    if [ "$siblings2" = "$old_dir2" ]; then
      pass "no new sibling directory was created for the failed advance"
    else
      fail "no new sibling directory was created for the failed advance" \
        "expected only: $old_dir2" "found:" "${siblings2:-<none>}"
    fi

    if [ -d "$HOME2/.cache/skill-engine" ] && [ -d "$CACHE_GM2" ]; then
      pass "the cache root is never removed by a failed advance"
    else
      fail "the cache root is never removed by a failed advance" \
        "missing: $HOME2/.cache/skill-engine or $CACHE_GM2"
    fi

    if gc_markers_intact; then
      pass "unrelated cache siblings and out-of-cache symlink targets survive the failed fetch untouched"
    else
      fail "unrelated cache siblings and out-of-cache symlink targets survive the failed fetch untouched" \
        "unrelated marker: $(cat "$UNRELATED_DIR/marker.txt" 2>/dev/null || echo "<missing>")" \
        "escape link target: $(readlink "$ESCAPE_LINK" 2>/dev/null || echo "<missing>")" \
        "canary content: $(cat "$OUTSIDE_TARGET_DIR/canary.txt" 2>/dev/null || echo "<missing>")" \
        "outside-HOME sentinel: $(cat "$OUTSIDE_HOME_SENTINEL" 2>/dev/null || echo "<missing>")"
    fi

    # The source must be reported as not advanced, not merely non-zero-exit
    # — a recipe that wrote a staged inventory claiming NEW_SHA before the
    # fetch failed would pass every check above while lying about the
    # result. Either no inventory was written for this source, or its
    # since_last_check does not claim the advance completed.
    inv_file2="$CTX_ROOT2/research/.discover-inventory.json"
    claimed_to2=""
    if [ -f "$inv_file2" ]; then
      claimed_to2="$(jq -r --arg sid "$SOURCE_ID2" '.[$sid].since_last_check.to_sha // empty' "$inv_file2" 2>/dev/null)"
    fi
    if [ "$claimed_to2" != "$SHA_B2" ]; then
      pass "the source is reported as not advanced (no staged inventory claims the new SHA)"
    else
      fail "the source is reported as not advanced (no staged inventory claims the new SHA)" \
        "$inv_file2 claims since_last_check.to_sha = $claimed_to2 despite the fetch failing"
    fi
  fi
fi

section "must-replay: a failed inventory write leaves the advance repeatable, not wedged"

# The directory rename is the step that changes what the NEXT session sees:
# after it, `<id>-<old_sha>/` is gone and the recorded old SHA no longer
# names anything on disk. Every fallible step therefore has to happen before
# it, or a failure in between leaves the cache advanced and the recorded
# state behind it — and the next advance fetches from a directory that no
# longer exists, prints "advance aborted", and does so again every session
# until someone hand-edits the registry (PR #15 review, finding 3).
#
# The transient failure here is an unwritable research/ directory: a
# stand-in for the malformed existing inventory, the full disk, and the
# interrupted run, all of which land in the same window. What is asserted is
# not the failure but the recovery — repair the condition, run the identical
# advance again, and it completes.

if ! $HAVE_RECIPE; then
  fail "a failed inventory write leaves the advance repeatable" "$NO_RECIPE_REASON"
else
  FX5="$TMPROOT/fx-replay"
  UPSTREAM5="$FX5/upstream"
  mkdir -p "$FX5"
  SHA_A5="$(upstream_init_commit_a "$UPSTREAM5")"
  HOME5="$FX5/home"
  CACHE_GM5="$HOME5/.cache/skill-engine/git-managed"
  SOURCE_ID5="acme-widgets"

  if ! seed_cache_shallow "$UPSTREAM5" "$CACHE_GM5" "$SOURCE_ID5" "$SHA_A5"; then
    fail "a failed inventory write leaves the advance repeatable" \
      "fixture setup failed: could not seed a --depth=1 scratch cache from the scratch upstream"
  else
    SHA_B5="$(upstream_add_commit_b "$UPSTREAM5")"
    CTX_ROOT5="$FX5/ctxroot"
    mkdir -p "$CTX_ROOT5/research"
    chmod 500 "$CTX_ROOT5/research"

    run_recipe "$RECIPE_TEMPLATE" "$HOME5" "$SOURCE_ID5" "$SHA_A5" "$SHA_B5" "$CTX_ROOT5"
    replay_rc1="$RUN_RC"
    replay_out1="$RUN_OUT"
    chmod 700 "$CTX_ROOT5/research"

    inv_file5="$CTX_ROOT5/research/.discover-inventory.json"
    # Fixture self-check: everything below is about what a FAILED write
    # leaves behind, so a write that quietly succeeded (running as root, an
    # exotic filesystem) would make the rest vacuous.
    if [ ! -f "$inv_file5" ]; then
      pass "fixture self-check: the unwritable research/ really did stop the inventory write"
    else
      fail "fixture self-check: the unwritable research/ really did stop the inventory write" \
        "$inv_file5 exists — the run below no longer exercises a failed write"
    fi

    old_dir5="$CACHE_GM5/${SOURCE_ID5}-${SHA_A5}"
    if [ -d "$old_dir5" ]; then
      pass "the cache directory still carries the recorded old SHA after the write failed (state and disk agree)"
    else
      fail "the cache directory still carries the recorded old SHA after the write failed (state and disk agree)" \
        "expected: $old_dir5" "found:" "$(sibling_dirs "$CACHE_GM5" "$SOURCE_ID5")" \
        "first-run exit: $replay_rc1" "first-run output:" "$replay_out1"
    fi

    # The replay: same source, same two SHAs, nothing hand-repaired but the
    # transient condition itself.
    run_recipe "$RECIPE_TEMPLATE" "$HOME5" "$SOURCE_ID5" "$SHA_A5" "$SHA_B5" "$CTX_ROOT5"
    if [ "$RUN_RC" -eq 0 ]; then
      pass "re-running the identical advance after the transient failure exits 0"
    else
      fail "re-running the identical advance after the transient failure exits 0" \
        "exit: $RUN_RC" "output:" "$RUN_OUT"
    fi

    if printf '%s' "$RUN_OUT" | grep -qF 'advance aborted'; then
      fail "the replay is not refused with 'advance aborted'" \
        "the first run moved the cache directory out from under the recorded SHA, so every later session re-reads a directory that no longer exists" \
        "output:" "$RUN_OUT"
    else
      pass "the replay is not refused with 'advance aborted'"
    fi

    replay_to5=""
    if [ -f "$inv_file5" ]; then
      replay_to5="$(jq -r --arg sid "$SOURCE_ID5" '.[$sid].since_last_check.to_sha // empty' "$inv_file5" 2>/dev/null)"
    fi
    if [ "$replay_to5" = "$SHA_B5" ]; then
      pass "the replay writes the inventory it could not write the first time"
    else
      fail "the replay writes the inventory it could not write the first time" \
        "expected since_last_check.to_sha = $SHA_B5, got: ${replay_to5:-<no inventory>}"
    fi

    expected_dir5="$CACHE_GM5/${SOURCE_ID5}-${SHA_B5}"
    siblings5="$(sibling_dirs "$CACHE_GM5" "$SOURCE_ID5")"
    if [ "$siblings5" = "$expected_dir5" ]; then
      pass "after the replay exactly one directory remains, named for the new SHA"
    else
      fail "after the replay exactly one directory remains, named for the new SHA" \
        "expected only: $expected_dir5" "found:" "${siblings5:-<none>}"
    fi
  fi
fi

section "must-guard: advance validates its environment before touching the checkout, and leaks no temp file"

# Driven against bin/cache-git.sh directly rather than through the recipe,
# because the environment under test is the one the recipe needs to find the
# helper at all: $CLAUDE_PLUGIN_ROOT. The scenario is the header's own -- a
# maintainer running the helper by hand, or a harness that does not export
# it. `set -u` is in force, so an unguarded dereference aborts the script;
# what matters is WHERE it aborts. Dereferenced after the fetch and the
# `checkout --detach`, it leaves <id>-<old_sha>/ holding new_sha's tree,
# and DISCOVER's pre-flight explicitly trusts that directory's SHA suffix
# (PR #15 review, finding 4).

FX6="$TMPROOT/fx-guard"
UPSTREAM6="$FX6/upstream"
mkdir -p "$FX6"
SHA_A6="$(upstream_init_commit_a "$UPSTREAM6")"
HOME6="$FX6/home"
CACHE_GM6="$HOME6/.cache/skill-engine/git-managed"
SOURCE_ID6="acme-widgets"
CACHE_GIT_SH="$PLUGIN_ROOT/bin/cache-git.sh"

if ! seed_cache_shallow "$UPSTREAM6" "$CACHE_GM6" "$SOURCE_ID6" "$SHA_A6"; then
  fail "advance refuses a missing CLAUDE_PLUGIN_ROOT before it fetches or checks out" \
    "fixture setup failed: could not seed a --depth=1 scratch cache from the scratch upstream"
else
  SHA_B6="$(upstream_add_commit_b "$UPSTREAM6")"
  old_dir6="$CACHE_GM6/${SOURCE_ID6}-${SHA_A6}"
  CTX_ROOT6="$FX6/ctxroot"
  mkdir -p "$CTX_ROOT6/research"

  guard_out="$(cd "$CTX_ROOT6" && env -u CLAUDE_PLUGIN_ROOT HOME="$HOME6" \
    bash "$CACHE_GIT_SH" advance "$SOURCE_ID6" "$SHA_A6" "$SHA_B6" \
    "$CTX_ROOT6/research/.discover-inventory.json" 2>&1)"
  guard_rc=$?

  if [ "$guard_rc" -ne 0 ]; then
    pass "advance exits non-zero when CLAUDE_PLUGIN_ROOT is not set"
  else
    fail "advance exits non-zero when CLAUDE_PLUGIN_ROOT is not set" "exit: $guard_rc" "$guard_out"
  fi

  if printf '%s' "$guard_out" | grep -qF 'CLAUDE_PLUGIN_ROOT' \
     && ! printf '%s' "$guard_out" | grep -qF 'unbound variable'; then
    pass "advance names CLAUDE_PLUGIN_ROOT in a diagnostic of its own, rather than aborting on an unbound variable"
  else
    fail "advance names CLAUDE_PLUGIN_ROOT in a diagnostic of its own, rather than aborting on an unbound variable" \
      "output: ${guard_out:-<empty>}"
  fi

  # The same guard, for the other precondition the recipe cannot verify for
  # itself: an inventory path whose parent does not exist. The helper used to
  # `mkdir -p` it, so a caller standing in the wrong place got a freshly
  # manufactured directory tree there instead of an error, and — research/
  # being gitignored — no `git status` line either. Asserted from
  # NEUTRAL_CWD with a bare-relative path, which is exactly the shape the
  # published recipe carried until 2026-09-12.
  parent_out="$(cd "$NEUTRAL_CWD" && env HOME="$HOME6" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "$CACHE_GIT_SH" advance "$SOURCE_ID6" "$SHA_A6" "$SHA_B6" \
    "research/.discover-inventory.json" 2>&1)"
  parent_rc=$?

  if [ "$parent_rc" -ne 0 ]; then
    pass "advance exits non-zero when the inventory path's parent directory does not exist"
  else
    fail "advance exits non-zero when the inventory path's parent directory does not exist" \
      "exit: $parent_rc" "$parent_out"
  fi

  if printf '%s' "$parent_out" | grep -qF 'parent directory does not exist'; then
    pass "advance says which precondition failed rather than writing somewhere it was not asked to"
  else
    fail "advance says which precondition failed rather than writing somewhere it was not asked to" \
      "output: ${parent_out:-<empty>}"
  fi

  if [ ! -e "$NEUTRAL_CWD/research" ]; then
    pass "no research/ tree was manufactured under the caller's working directory"
  else
    fail "no research/ tree was manufactured under the caller's working directory" \
      "found: $(find "$NEUTRAL_CWD/research" 2>/dev/null | head -5)"
  fi

  head6_parent="$(git -C "$old_dir6" rev-parse HEAD 2>/dev/null || echo '<no such directory>')"
  if [ "$head6_parent" = "$SHA_A6" ]; then
    pass "that refusal also came before the fetch — the cached checkout is still at the old SHA"
  else
    fail "that refusal also came before the fetch — the cached checkout is still at the old SHA" \
      "HEAD of $old_dir6: $head6_parent (expected $SHA_A6)"
  fi

  head6="$(git -C "$old_dir6" rev-parse HEAD 2>/dev/null || echo '<no such directory>')"
  if [ "$head6" = "$SHA_A6" ]; then
    pass "the cached checkout is still at the old SHA — the refusal came before the fetch and the checkout"
  else
    fail "the cached checkout is still at the old SHA — the refusal came before the fetch and the checkout" \
      "expected HEAD $SHA_A6, found: $head6" \
      "a directory named <id>-<old_sha> whose tree is at new_sha is what DISCOVER's pre-flight trusts the suffix against"
  fi

  # Temp-file hygiene, on a failure path that lands inside the window: the
  # since-last-check scratch file is mktemp'd, filled, and read by
  # discover_inventory.py, and any abort between the mktemp and its removal
  # used to leave the file behind (the --probe recipe in
  # intake-and-detection.md sets a trap; this did not). The abort used here
  # is a CLAUDE_PLUGIN_ROOT that is set but does not point at an install --
  # the other half of the same environment mistake as above, and the reason
  # the guard checks only for a missing value: a wrong one is not detectable
  # until the script it names is actually invoked. TMPDIR is an empty
  # scratch directory, so the check is exact rather than a heuristic over
  # whatever else is in the system temp dir.
  LEAK_TMPDIR="$FX6/leak-tmp"
  BOGUS_ROOT="$FX6/not-an-install"
  mkdir -p "$LEAK_TMPDIR" "$BOGUS_ROOT"
  leak_out="$(cd "$CTX_ROOT6" && env HOME="$HOME6" CLAUDE_PLUGIN_ROOT="$BOGUS_ROOT" \
    TMPDIR="$LEAK_TMPDIR" bash "$CACHE_GIT_SH" advance "$SOURCE_ID6" "$SHA_A6" "$SHA_B6" \
    "$CTX_ROOT6/research/.discover-inventory.json" 2>&1)"
  leak_rc=$?

  if [ "$leak_rc" -ne 0 ]; then
    pass "fixture self-check: a CLAUDE_PLUGIN_ROOT with no discover_inventory.py really did abort the advance mid-run"
  else
    fail "fixture self-check: a CLAUDE_PLUGIN_ROOT with no discover_inventory.py really did abort the advance mid-run" \
      "exit: $leak_rc" "$leak_out"
  fi

  leaked6="$(find "$LEAK_TMPDIR" -mindepth 1 2>/dev/null)"
  if [ -z "$leaked6" ]; then
    pass "an aborted advance leaves no temp file behind"
  else
    fail "an aborted advance leaves no temp file behind" "found under TMPDIR:" "$leaked6"
  fi

  # Calibration. The assertion above is a preservation assertion over a
  # scratch directory that is empty to begin with, so "nothing was left
  # behind" is also what a run that never reached the mktemp reports, and
  # what a run whose mktemp ignored TMPDIR reports (BSD mktemp does exactly
  # that without an explicit template -- this assertion was silently vacuous
  # for that reason before the helper grew one). Re-running the identical
  # abort against a copy of the helper with only the cleanup trap removed
  # has to leave the file behind; if it does not, the check above is not
  # watching the right directory.
  CALIB_TMPDIR="$FX6/calib-tmp"
  CALIB_HELPER="$FX6/cache-git-no-trap.sh"
  mkdir -p "$CALIB_TMPDIR"
  sed '/trap .*since_tmpfile/d' "$CACHE_GIT_SH" > "$CALIB_HELPER"
  if cmp -s "$CALIB_HELPER" "$CACHE_GIT_SH"; then
    fail "calibration: an aborted advance leaves no temp file behind" \
      "removing the cleanup trap changed nothing in bin/cache-git.sh — there is no trap to calibrate against"
  else
    ( cd "$CTX_ROOT6" && env HOME="$HOME6" CLAUDE_PLUGIN_ROOT="$BOGUS_ROOT" \
      TMPDIR="$CALIB_TMPDIR" bash "$CALIB_HELPER" advance "$SOURCE_ID6" "$SHA_A6" "$SHA_B6" \
      "$CTX_ROOT6/research/.discover-inventory.json" >/dev/null 2>&1 ) || true
    if [ -n "$(find "$CALIB_TMPDIR" -mindepth 1 2>/dev/null)" ]; then
      pass "calibration: the same abort without the cleanup trap does leave a temp file, so the check above is watching the right directory"
    else
      fail "calibration: the same abort without the cleanup trap does leave a temp file, so the check above is watching the right directory" \
        "nothing appeared under $CALIB_TMPDIR either way — the no-leak assertion above proves nothing"
    fi
  fi

  # Shape, because the behavioral assertion above is platform-dependent in a
  # way that hid a real leak: whether a function's locals are still readable
  # from an EXIT trap during `set -e` teardown differs by bash version. Under
  # the bash 3.2 macOS ships they are, so a trap over a `local` cleans up and
  # this suite passed locally for as long as the defect existed; under the
  # bash 5 CI runs they are not, the variable expands to empty, and `rm -f ""`
  # succeeds having removed nothing. Asserting the shape catches a regression
  # on the platform the behavior cannot.
  trap_vars="$(grep -oE "trap '[^']*\\\$\{?[A-Za-z_][A-Za-z0-9_]*" "$CACHE_GIT_SH" \
    | grep -oE '[A-Za-z_][A-Za-z0-9_]*$' | sort -u)"
  local_leaks=""
  while IFS= read -r tv; do
    [ -n "$tv" ] || continue
    if grep -qE "^[[:space:]]*local\b[^#]*\b${tv}\b" "$CACHE_GIT_SH"; then
      local_leaks="${local_leaks:+$local_leaks, }$tv"
    fi
  done <<< "$trap_vars"

  if [ -z "$trap_vars" ]; then
    fail "no EXIT trap in cache-git.sh cleans up via a function-local" \
      "no trap referencing a variable was found — the scan is vacuous"
  elif [ -z "$local_leaks" ]; then
    pass "no EXIT trap in cache-git.sh cleans up via a function-local"
  else
    fail "no EXIT trap in cache-git.sh cleans up via a function-local" \
      "declared local and read from a trap: $local_leaks" \
      "under bash 5 the frame is gone when the trap runs, so the cleanup silently no-ops"
  fi
fi

section "must-preserve: advancing one source does not garbage-collect a sibling whose id shares its prefix"

# The GC glob is `-name "<source_id>-*"`, and source_id is validated as
# [a-z0-9-]+ -- so `api` and `api-docs` are both legal ids in the same
# registry, and advancing `api` matched `api-docs-<sha>` and rm -rf'd it.
# The next DISCOVER or REFRESH for api-docs then re-clones from scratch,
# with nothing recording why. 07-monorepo-adapter.md already documents the
# READER side as requiring a bare-hex suffix, "so a sibling id ... is not
# mistaken for the source's own tree"; the deleter side never got the same
# treatment (PR #15 review, finding 15).

if ! $HAVE_RECIPE; then
  fail "advancing one source leaves a prefix-sharing sibling's cache intact" "$NO_RECIPE_REASON"
else
  FX7="$TMPROOT/fx-prefix-gc"
  UPSTREAM7="$FX7/upstream"
  mkdir -p "$FX7"
  SHA_A7="$(upstream_init_commit_a "$UPSTREAM7")"
  HOME7="$FX7/home"
  CACHE_GM7="$HOME7/.cache/skill-engine/git-managed"
  SOURCE_ID7="api"

  if ! seed_cache_shallow "$UPSTREAM7" "$CACHE_GM7" "$SOURCE_ID7" "$SHA_A7"; then
    fail "advancing one source leaves a prefix-sharing sibling's cache intact" \
      "fixture setup failed: could not seed a --depth=1 scratch cache from the scratch upstream"
  else
    SHA_B7="$(upstream_add_commit_b "$UPSTREAM7")"
    # A second, independent source whose id begins with the first one's id
    # plus the same separator the suffix uses.
    SIBLING_DIR7="$CACHE_GM7/api-docs-abc1234def5678"
    mkdir -p "$SIBLING_DIR7"
    printf 'belongs to api-docs\n' > "$SIBLING_DIR7/marker.txt"
    # And one that IS this source's own superseded directory, to keep the
    # GC's actual job asserted alongside what it must not touch.
    STALE_OWN7="$CACHE_GM7/api-0000000000000000000000000000000000000000"
    mkdir -p "$STALE_OWN7"
    printf 'superseded api checkout\n' > "$STALE_OWN7/marker.txt"

    CTX_ROOT7="$FX7/ctxroot"
    mkdir -p "$CTX_ROOT7/research"

    run_recipe "$RECIPE_TEMPLATE" "$HOME7" "$SOURCE_ID7" "$SHA_A7" "$SHA_B7" "$CTX_ROOT7"

    if [ "$RUN_RC" -eq 0 ]; then
      pass "fixture self-check: the advance itself succeeds"
    else
      fail "fixture self-check: the advance itself succeeds" "exit: $RUN_RC" "output:" "$RUN_OUT"
    fi

    if [ -f "$SIBLING_DIR7/marker.txt" ]; then
      pass "advancing 'api' leaves 'api-docs-<sha>' untouched"
    else
      fail "advancing 'api' leaves 'api-docs-<sha>' untouched" \
        "$SIBLING_DIR7 was deleted — the GC glob matched another source's cache directory" \
        "surviving directories:" "$(find "$CACHE_GM7" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)"
    fi

    if [ ! -d "$STALE_OWN7" ]; then
      pass "the source's own superseded directory is still collected"
    else
      fail "the source's own superseded directory is still collected" \
        "$STALE_OWN7 survived — narrowing the glob must not stop the GC doing its job"
    fi

    if [ -d "$CACHE_GM7/${SOURCE_ID7}-${SHA_B7}" ]; then
      pass "the advanced directory for 'api' is present at the new SHA"
    else
      fail "the advanced directory for 'api' is present at the new SHA" \
        "expected: $CACHE_GM7/${SOURCE_ID7}-${SHA_B7}"
    fi
  fi
fi

# ---- DISCOVER cache-hit check: SHA-aware hit/miss decision ---------------
# DISCOVER pre-flight step 6 (cache-and-clone.md) probes for a warm
# git-managed cache directory before offering to clone. Today's fenced
# block picks the first filesystem match (`find ... | head -n1`) and
# checks only that a `.git/` subdirectory exists — it never compares the
# directory's SHA suffix to the SHA already resolved earlier in
# pre-flight, so a stale, superseded directory with a valid `.git/` is
# indistinguishable from a genuine hit, and when two `<source_id>-*/`
# directories coexist the choice is filesystem order, not correctness.
#
# The fix is expected to live in the same fenced block, wrapped in a
# second sentinel pair (this repo's established paired-HTML-comment
# convention, same family as the advance recipe's own sentinel and
# doctrine.sh's `doctrine:sandbox-prose-exempt` / `doctrine:locator-block`):
#
#   <!-- doctrine:discover-cache-hit-check:start -->
#   ...fenced bash block...
#   <!-- doctrine:discover-cache-hit-check:end -->
#
# `<source_id>` is this doc's established placeholder for the source id
# (already used throughout cache-and-clone.md); whichever OTHER single
# `<...>` placeholder the fixed block introduces is treated as "the SHA
# step 5 resolved for this source" — the one new concept this fix
# requires the probe to compare against — detected generically rather
# than assumed by name, since nothing pins one yet.
#
# The probe's own output is frozen as the shell variable `cache_dir`
# (already the name today's block uses for exactly this purpose): expected
# non-empty and pointing at the matching directory on a hit, empty on a
# miss. This harness runs the substituted block plus one appended line
# reporting that variable, rather than assuming any exit code or stdout
# convention the fix does not otherwise need.
CACHE_HIT_SENTINEL_START='<!-- doctrine:discover-cache-hit-check:start -->'
CACHE_HIT_SENTINEL_END='<!-- doctrine:discover-cache-hit-check:end -->'

# Scoped to cache-and-clone.md alone: DISCOVER pre-flight step 6 already
# lives there today and nothing about this fix suggests relocating it —
# unlike the advance recipe (deliberately left ambiguous across four
# files), searching further files here would only manufacture false
# ambiguity.
CACHE_HIT_SCOPE_FILES=(
  "skills/discover/references/cache-and-clone.md"
)

section "cache-hit check present: exactly one sentinel-delimited pre-flight probe in cache-and-clone.md"

HAVE_HIT_CHECK=false
HIT_CHECK_TEMPLATE=""
RESOLVED_SHA_NAME=""

if extract_sentinel_block \
     "cache-hit check present: exactly one sentinel-delimited pre-flight probe in cache-and-clone.md" \
     "$CACHE_HIT_SENTINEL_START" "$CACHE_HIT_SENTINEL_END" "${CACHE_HIT_SCOPE_FILES[@]}"; then
  HIT_CHECK_TEMPLATE="$EXTRACTED_BLOCK"
  other_placeholders="$(grep -oE '<[a-zA-Z_][a-zA-Z0-9_]*>' "$HIT_CHECK_TEMPLATE" | LC_ALL=C sort -u | grep -vFx '<source_id>' || true)"
  other_count="$(printf '%s\n' "$other_placeholders" | grep -c . || true)"
  if [ "$other_count" -eq 1 ]; then
    RESOLVED_SHA_NAME="$(printf '%s\n' "$other_placeholders" | head -n1 | tr -d '<>')"
    HAVE_HIT_CHECK=true
  else
    fail "cache-hit check present: exactly one sentinel-delimited pre-flight probe in cache-and-clone.md" \
      "expected exactly one placeholder besides <source_id> (the resolved-SHA token); found: ${other_placeholders:-<none>}"
  fi
fi

NO_HIT_CHECK_REASON="cannot evaluate — no cache-hit check found (see 'cache-hit check present' section above)"

section "cache-hit check: a SHA-matching directory is a hit, a mismatched one is a miss, and a matching sibling wins over filesystem order"

if ! $HAVE_HIT_CHECK; then
  fail "a SHA-matching cache directory is reported as a hit" "$NO_HIT_CHECK_REASON"
  fail "a SHA-mismatched cache directory is reported as a miss, not a hit" "$NO_HIT_CHECK_REASON"
  fail "when two <source_id>-*/ siblings coexist, the SHA-matching one is used, not filesystem order" "$NO_HIT_CHECK_REASON"
else
  SOURCE_ID3="acme-widgets"
  RESOLVED_SHA3="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  OTHER_SHA3="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  # (a) a single directory whose suffix equals the resolved SHA is a hit.
  HOME3A="$TMPROOT/fx-hit-a/home"
  CGM3A="$HOME3A/.cache/skill-engine/git-managed"
  mk_cache_entry "$CGM3A" "$SOURCE_ID3" "$RESOLVED_SHA3"
  run_hit_check "$HIT_CHECK_TEMPLATE" "$HOME3A" "$SOURCE_ID3" "$RESOLVED_SHA_NAME" "$RESOLVED_SHA3"
  expected3a="$CGM3A/${SOURCE_ID3}-${RESOLVED_SHA3}"
  if [ "$HIT_CHECK_OUT" = "$expected3a" ]; then
    pass "a SHA-matching cache directory is reported as a hit"
  else
    fail "a SHA-matching cache directory is reported as a hit" \
      "expected cache_dir: $expected3a" "got: ${HIT_CHECK_OUT:-<empty>}" "exit: $HIT_CHECK_RC" \
      "$(cat "$TMPROOT/hitcheck-err.txt" 2>/dev/null)"
  fi

  # (b) a single directory whose suffix does NOT equal the resolved SHA is
  # a miss — the must-reject case today's unmodified probe gets wrong: it
  # never compares SHAs at all, so a valid `.git/` alone reads as a hit.
  HOME3B="$TMPROOT/fx-hit-b/home"
  CGM3B="$HOME3B/.cache/skill-engine/git-managed"
  mk_cache_entry "$CGM3B" "$SOURCE_ID3" "$OTHER_SHA3"
  run_hit_check "$HIT_CHECK_TEMPLATE" "$HOME3B" "$SOURCE_ID3" "$RESOLVED_SHA_NAME" "$RESOLVED_SHA3"
  if [ -z "$HIT_CHECK_OUT" ]; then
    pass "a SHA-mismatched cache directory is reported as a miss, not a hit"
  else
    fail "a SHA-mismatched cache directory is reported as a miss, not a hit" \
      "resolved SHA: $RESOLVED_SHA3, directory SHA suffix: $OTHER_SHA3" \
      "expected cache_dir empty, got: $HIT_CHECK_OUT"
  fi

  # (c) two coexisting <source_id>-*/ siblings, one matching and one not —
  # the matching one must be used, not filesystem order. The mismatched
  # one is created first and sorts first alphabetically, so a blind
  # `find | head -n1` selection would pick it.
  HOME3C="$TMPROOT/fx-hit-c/home"
  CGM3C="$HOME3C/.cache/skill-engine/git-managed"
  mk_cache_entry "$CGM3C" "$SOURCE_ID3" "$OTHER_SHA3"
  mk_cache_entry "$CGM3C" "$SOURCE_ID3" "$RESOLVED_SHA3"
  run_hit_check "$HIT_CHECK_TEMPLATE" "$HOME3C" "$SOURCE_ID3" "$RESOLVED_SHA_NAME" "$RESOLVED_SHA3"
  expected3c="$CGM3C/${SOURCE_ID3}-${RESOLVED_SHA3}"
  if [ "$HIT_CHECK_OUT" = "$expected3c" ]; then
    pass "when two <source_id>-*/ siblings coexist, the SHA-matching one is used, not filesystem order"
  else
    fail "when two <source_id>-*/ siblings coexist, the SHA-matching one is used, not filesystem order" \
      "expected: $expected3c" "got: ${HIT_CHECK_OUT:-<empty>}"
  fi
fi

# ---- doc consistency: no fresh-clone-then-GC framing; routers untouched --
# Prose-shaped, so wrap-normalized: a paragraph's line breaks can move
# under re-wrapping without changing its meaning, and this check must
# survive that.

section "doc consistency: docs/03-engine.md's cache-lifecycle bullet no longer describes fresh-clone-then-GC"

# find_paragraph_from <file> <anchor-fixed-string> — the anchor line and
# every following line up to (not including) the next blank line or the
# next top-level bullet ("* **"), wrap-normalized to one space-joined
# line.
find_paragraph_from() {
  local file="$1" anchor="$2"
  awk -v anchor="$anchor" '
    BEGIN { found = 0 }
    index($0, anchor) > 0 && !found { found = 1; print; next }
    found && ($0 ~ /^[[:space:]]*$/ || $0 ~ /^\* \*\*/) { exit }
    found { print }
  ' "$file" | tr '\n' ' ' | tr -s '[:space:]' ' '
}

engine_doc="$PLUGIN_ROOT/docs/03-engine.md"
gc_bullet="$(find_paragraph_from "$engine_doc" 'REFRESH GC')"
if [ -z "$gc_bullet" ]; then
  fail "the cache-lifecycle bullet list no longer describes fresh-clone-then-GC (in-place-advance language present)" \
    "anchor 'REFRESH GC' not found in $engine_doc — has the cache-lifecycle bullet list structure changed?"
else
  gc_bullet_lower="$(printf '%s' "$gc_bullet" | tr '[:upper:]' '[:lower:]')"
  if printf '%s' "$gc_bullet_lower" | grep -qE 'in[- ]place' \
     || { printf '%s' "$gc_bullet_lower" | grep -q 'advanc' && printf '%s' "$gc_bullet_lower" | grep -q 'fetch'; }; then
    pass "the cache-lifecycle bullet list no longer describes fresh-clone-then-GC (in-place-advance language present)"
  else
    fail "the cache-lifecycle bullet list no longer describes fresh-clone-then-GC (in-place-advance language present)" \
      "bullet text: $gc_bullet"
  fi
fi

# The "routers stay byte-identical to the baseline" check that lived here
# (PR #14, v0.8.0) pinned an invariant scoped to that PR's own feature.md
# ("this feature" in the removed comment meant v0.8.0's, not any future
# one). v0.9.0's many-sources chunk 07 (Fork E: staged archive detection)
# intentionally edits both routers' "does NOT do" sentences; each router's
# own byte-neutral-or-smaller ceiling is enforced going forward by
# chunk 07's own oracle (plugin/skill-engine/tests/archive-detection/) and
# by doctrine checks 18/24, so removing this pin doesn't drop coverage —
# it retires an invariant that no longer holds by design.

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

[ "$fail_count" -eq 0 ]
