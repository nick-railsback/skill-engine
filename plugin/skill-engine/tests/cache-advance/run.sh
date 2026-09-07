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
# is free to shell out to. HOME and CLAUDE_PLUGIN_ROOT are the only
# genuinely-environment-variable values in this contract — every other
# reference doc in scope follows the identical split.
#
# The recipe owns writing the bare relative path
# `research/.discover-inventory.json` — no `$CTX_PROPOSED` (or
# `$CTX_ROOT`) prefix: cache-and-clone.md step 7 documents this file as
# gitignored runtime state, "not a reference artifact, and not subject to
# any verify.sh check", re-derived and fully overwritten every run — unlike
# `source-paths.json`, it is never copy-on-write staged, and every mention
# of it anywhere in this codebase uses the same bare relative form. So
# this harness runs the recipe with its current working directory at a
# scratch contextualizer root and reads the file back from
# `<that root>/research/.discover-inventory.json` — there is no staging
# layer for this file to route around. The recipe is expected to
# `mkdir -p research` itself, same as the lifecycle-transition example
# already in cache-and-clone.md does for its own (genuinely staged)
# write. The file's content is asserted only by outcome, in the shape
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

# run_recipe <template> <home> <source_id> <old_sha> <new_sha> <cwd_root>
# — the frozen invocation contract: substitute the prose placeholders with
# this call's concrete values, then run the result with its current
# working directory at <cwd_root> (a scratch stand-in for the
# contextualizer root a real invocation runs from — where the recipe's
# bare-relative-path `research/.discover-inventory.json` write actually
# lands) and only HOME and CLAUDE_PLUGIN_ROOT as real environment
# variables. Sets RUN_OUT (combined stdout+stderr) and RUN_RC (exit code).
RUN_OUT=""
RUN_RC=0
run_recipe() {
  local template="$1" home="$2" source_id="$3" old_sha="$4" new_sha="$5" cwd_root="$6"
  local invocation
  # No trailing suffix after the X's: BSD mktemp (macOS) only recognizes a
  # trailing-X template, so "invoke-XXXXXX.sh" creates the literal,
  # unexpanded file "invoke-XXXXXX.sh" once and then collides on every
  # later call. Bash does not need a .sh extension to execute the file.
  invocation="$(mktemp "$TMPROOT/invoke-XXXXXX")"
  substitute_placeholders "$template" "$invocation" "$source_id" "$old_sha" "$new_sha"
  RUN_OUT="$(cd "$cwd_root" && env HOME="$home" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "$invocation" 2>&1)"
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
    # A scratch stand-in for the contextualizer root the recipe actually
    # runs from — where its bare-relative-path `research/...` write lands.
    # Not a staging directory: research/.discover-inventory.json is never
    # copy-on-write staged, unlike source-paths.json.
    CTX_ROOT1="$FX1/ctxroot"
    mkdir -p "$CTX_ROOT1"
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
    if printf '%s\n' "$recipe_verbs" | grep -qx 'fetch'; then
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
    # A scratch stand-in for the contextualizer root the recipe runs from
    # — see CTX_ROOT1 above for why this is not a staging directory.
    CTX_ROOT2="$FX2/ctxroot"
    mkdir -p "$CTX_ROOT2"

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

section "doc consistency: refresh/SKILL.md and discover/SKILL.md stay byte-identical to the baseline"

# Frozen at authoring time: feature.md's byte-ceiling constraint excludes
# both routers from this feature entirely, so any change at all — from
# this fix or anything else — is a regression, not a legitimate edit.
REFRESH_SKILL_SHA256="d5c3a569b61feb20a4f34df059c2dfb59d513161bb8e8380405807b63e2f4f8b"
DISCOVER_SKILL_SHA256="18097c0f3855886eef3502426c76700cb39b97793f8ac572f463c4f9ca951e2e"

refresh_skill="$PLUGIN_ROOT/skills/refresh/SKILL.md"
discover_skill="$PLUGIN_ROOT/skills/discover/SKILL.md"

if [ -f "$refresh_skill" ] && [ "$(sha256_of_file "$refresh_skill")" = "$REFRESH_SKILL_SHA256" ]; then
  pass "refresh/SKILL.md is byte-identical to the baseline"
else
  fail "refresh/SKILL.md is byte-identical to the baseline" \
    "expected sha256: $REFRESH_SKILL_SHA256" \
    "got: $([ -f "$refresh_skill" ] && sha256_of_file "$refresh_skill" || echo "<file missing>")"
fi

if [ -f "$discover_skill" ] && [ "$(sha256_of_file "$discover_skill")" = "$DISCOVER_SKILL_SHA256" ]; then
  pass "discover/SKILL.md is byte-identical to the baseline"
else
  fail "discover/SKILL.md is byte-identical to the baseline" \
    "expected sha256: $DISCOVER_SKILL_SHA256" \
    "got: $([ -f "$discover_skill" ] && sha256_of_file "$discover_skill" || echo "<file missing>")"
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

[ "$fail_count" -eq 0 ]
