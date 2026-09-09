#!/usr/bin/env bash
# Feature-scoped test runner for the shipped cache-mutating git surface:
#
#   1. every shipped cache-writing recipe honors an overridden cache root
#      (SKILL_ENGINE_CACHE_ROOT), never writing under a literal
#      $HOME/.cache/skill-engine path;
#   2. doctrine's git-verb-scan check (tests/doctrine.sh check 4) accepts a
#      -C target spelled with the ${SKILL_ENGINE_CACHE_ROOT:-...} override
#      form for the verbs it already exempts (fetch, sparse-checkout,
#      checkout), and still rejects a target that is neither that form nor
#      the literal $HOME/~ spelling;
#   3. cited_paths.py's git-managed-source resolution agrees with
#      permalink_density.py's accepted_hosts(), including when a registry
#      is present but its `sources` field is not a list;
#   4. every shipped since-last-check code path reports a genuine deletion
#      between two commits, and none emits a constant "changes": 1
#      placeholder;
#   5. cited_paths.py's candidate-set computation stays fast at a fixture
#      scale where a naive O(refs x changed-paths x cites) shape is slow;
#      and
#   6. bin/cache-git.sh's own sparse-clone mechanics -- the four clone
#      flags, the three cache-scoped post-clone invocations, and the
#      post-clone validator -- are pinned on the shipped helper, with every
#      pin mutation-calibrated.
#
# ---------------------------------------------------------------------------
# Section 1 (recipes). This repo's reference docs narrate a workflow an
# agent runs step by step, substituting angle-bracket prose placeholders
# (<source_id>, <url>, ...) textually into a fenced block before running it
# fresh — there is no continuous shell session across steps, so a
# placeholder is never read back as an inherited environment variable (the
# same contract tests/cache-advance/run.sh and tests/sparse-clone/run.sh
# already rely on). This file extracts every fenced ```bash block from the
# three declared reference docs, keeps the ones that carry a candidate
# cache-mutating git verb (clone/fetch/sparse-checkout/checkout, via the
# same tests/lib/git_verb_scan.sh extractor doctrine.sh itself uses) or that
# invoke a cache-git helper script by name, and runs each of those with its
# known placeholders substituted, HOME pointed at a scratch directory, and
# SKILL_ENGINE_CACHE_ROOT pointed at a second, separate scratch directory.
# This is a structural filter, not an enumeration: a later recipe this file
# has never seen is caught the same way, and if a doc ever stops naming a
# candidate recipe at all (three current docs each still carry one today),
# the "at least one recipe found" assertion below fails loudly rather than
# passing vacuously.
#
# Section 2 (git-verb-scan) reuses the scratch-markdown-fixture technique
# tests/git-verb-cache-scope/run.sh established, under its own scratch
# filename so the two runners never collide.
#
# Section 3 (registry resolution) and section 5 (candidate-set timing) drive
# Python fixtures via the sibling fixtures.py, always through a named public
# function (permalink_density.accepted_hosts()) or a shipped CLI
# (cited_paths.py), never a private helper — see fixtures.py's own header.
#
# Section 4 (since-last-check) builds one small git fixture with a genuine
# file deletion between two commits and drives it through every
# since-last-check code path this repo ships today.
#
# -e is intentionally omitted: every assertion runs and reports, not abort
# at the first red one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_ROOT/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

SCANNER="$TESTS_ROOT/lib/git_verb_scan.sh"
CI_LOCAL="$REPO_ROOT/scripts/ci-local.sh"
CITED_PATHS_PY="$TESTS_ROOT/cited_paths.py"
DISCOVER_INVENTORY_PY="$TESTS_ROOT/discover_inventory.py"
FIXTURES_PY="$SCRIPT_DIR/fixtures.py"

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

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/cache-git-helper.XXXXXX")"
SCRATCH_FILE="$PLUGIN_ROOT/skills/.oracle-cache-git-helper-scratch.md"
cleanup() {
  rm -rf "$TMPROOT"
  rm -f "$SCRATCH_FILE"
}
trap cleanup EXIT

# ===========================================================================
# Section 1 — cache-writing recipes honor SKILL_ENGINE_CACHE_ROOT
# ===========================================================================

section "cache-writing recipes honor an overridden cache root, not a literal \$HOME path"

RECIPE_DOCS=(
  "skills/engine-bootstrap/references/cache-seeding.md"
  "skills/discover/references/cache-and-clone.md"
  "skills/refresh/references/tool-and-output-mechanics.md"
)

# extract_bash_fences <file> <outdir> — writes each ```bash ... ``` fenced
# block in <file> to <outdir>/block-<N>.sh (1-indexed, document order).
# Prints the count.
extract_bash_fences() {
  local file="$1" outdir="$2"
  mkdir -p "$outdir"
  awk -v outdir="$outdir" '
    /^[[:space:]]*```bash[[:space:]]*$/ { n++; infence=1; buf=""; next }
    /^[[:space:]]*```[[:space:]]*$/ {
      if (infence) {
        outfile = outdir "/block-" n ".sh"
        printf "%s", buf > outfile
        close(outfile)
        infence = 0
      }
      next
    }
    infence { buf = buf $0 "\n" }
    END { print n + 0 }
  ' "$file"
}

# block_candidate_verbs <block-file> — candidate git verbs (field 3 of
# git_verb_scan.sh's own output) found inside one extracted block.
block_candidate_verbs() {
  bash "$SCANNER" --root "" "$1" 2>/dev/null | awk -F: '{print $3}'
}

# is_cache_writing_block <block-file> — true if the block carries a
# candidate cache-mutating git verb, or names a cache-git helper script by
# convention (so a future recipe that delegates to a shipped helper instead
# of invoking git directly is still picked up as a candidate).
is_cache_writing_block() {
  local block="$1" verbs
  verbs="$(block_candidate_verbs "$block")"
  if printf '%s\n' "$verbs" | grep -qE '^(clone|fetch|sparse-checkout|checkout)$'; then
    return 0
  fi
  grep -qF 'cache-git.sh' "$block" 2>/dev/null
}

# sweep_block_for_bare_home <block-file> — lines inside the block that
# spell .cache/skill-engine without SKILL_ENGINE_CACHE_ROOT anywhere on the
# same line (the override's own default arm,
# ${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}, mentions the literal
# path text too, so requiring the variable name alongside it is what tells
# the override spelling apart from a bare hard-coded one).
sweep_block_for_bare_home() {
  awk '
    /\.cache\/skill-engine/ && !/SKILL_ENGINE_CACHE_ROOT/ { print NR": "$0 }
  ' "$1"
}

# Shared upstream fixture: a two-commit local "remote" (no network needed).
# Commit A adds two tracked files plus a docs/ file (so a files_of_interest
# scope of docs/** has something to materialize); commit B modifies one,
# deletes another, and adds a third — an unambiguous change set under any
# name-status diff, and (reused by section 4 below) a genuine deletion.
RCP_UPSTREAM="$TMPROOT/rcp-upstream"
git init -q "$RCP_UPSTREAM"
git -C "$RCP_UPSTREAM" checkout -q -b main >/dev/null 2>&1
mkdir -p "$RCP_UPSTREAM/docs"
printf 'keep\n' > "$RCP_UPSTREAM/keep.txt"
printf 'drop\n' > "$RCP_UPSTREAM/dropped.txt"
printf 'doc\n' > "$RCP_UPSTREAM/docs/x.md"
git -C "$RCP_UPSTREAM" add -A
git -C "$RCP_UPSTREAM" -c user.email=oracle@example.invalid -c user.name=oracle \
  commit -q -m "commit A"
RCP_SHA_A="$(git -C "$RCP_UPSTREAM" rev-parse HEAD)"

# Pre-seed the override root's stale clone for the in-place-advance recipe,
# captured before upstream moves to B — the state a maintainer who has
# already been using SKILL_ENGINE_CACHE_ROOT would be in when drift lands.
RCP_ADVANCE_SEED="$TMPROOT/rcp-advance-seed"
mkdir -p "$RCP_ADVANCE_SEED/git-managed"
git clone -q --depth=1 "file://$RCP_UPSTREAM" \
  "$RCP_ADVANCE_SEED/git-managed/widget-src-$RCP_SHA_A" >/dev/null 2>&1
git -C "$RCP_ADVANCE_SEED/git-managed/widget-src-$RCP_SHA_A" \
  checkout -q --detach HEAD >/dev/null 2>&1

printf 'keep\nmore\n' > "$RCP_UPSTREAM/keep.txt"
rm -f "$RCP_UPSTREAM/dropped.txt"
printf 'new\n' > "$RCP_UPSTREAM/new.txt"
git -C "$RCP_UPSTREAM" add -A
git -C "$RCP_UPSTREAM" -c user.email=oracle@example.invalid -c user.name=oracle \
  commit -q -m "commit B"
RCP_SHA_B="$(git -C "$RCP_UPSTREAM" rev-parse HEAD)"

# run_candidate_recipe <label> <block-file> <ctx-root> <home> <override-root>
#   <expected-populated-dir> <sed-args...>
# Substitutes <sed-args...> into <block-file>, refuses to run (and fails
# both outcome assertions) if any <...>-shaped placeholder survives
# substitution outside a comment, then runs the result with HOME and
# SKILL_ENGINE_CACHE_ROOT set to two distinct scratch directories. Asserts
# the override root ends up populated at <expected-populated-dir>/.git and
# that nothing appears under the literal $HOME cache path.
run_candidate_recipe() {
  local label="$1" block="$2" ctx_root="$3" home="$4" override_root="$5" expected_dir="$6"
  shift 6
  local script
  # No trailing suffix after the X's: BSD mktemp (macOS) only recognizes a
  # trailing-X template, so "exec-XXXXXX.sh" would create the literal,
  # unexpanded file "exec-XXXXXX.sh" once and then collide on every later call.
  script="$(mktemp "$TMPROOT/exec-XXXXXX")"
  sed "$@" "$block" > "$script"
  local leftover
  leftover="$(sed 's/#.*$//' "$script" | grep -oE '<[^>]+>' | sort -u | tr '\n' ' ')"
  if [ -n "$leftover" ]; then
    fail "$label: recipe substitutes cleanly with the known placeholder tokens" \
      "unsubstituted placeholder(s) remain: $leftover"
    fail "$label: the overridden cache root ends up populated" \
      "cannot evaluate — substitution left unknown placeholders (see above)"
    fail "$label: nothing is written under the literal \$HOME cache path" \
      "cannot evaluate — substitution left unknown placeholders (see above)"
    return
  fi
  mkdir -p "$ctx_root"
  local out rc
  out="$(cd "$ctx_root" && env HOME="$home" SKILL_ENGINE_CACHE_ROOT="$override_root" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$script" 2>&1)"
  rc=$?
  if [ -d "$expected_dir/.git" ]; then
    pass "$label: the overridden cache root ends up populated"
  else
    fail "$label: the overridden cache root ends up populated" \
      "expected: $expected_dir/.git" "recipe exit: $rc" "recipe output: $out"
  fi
  if [ ! -e "$home/.cache/skill-engine" ]; then
    pass "$label: nothing is written under the literal \$HOME cache path"
  else
    fail "$label: nothing is written under the literal \$HOME cache path" \
      "found: $home/.cache/skill-engine"
  fi
}

RECIPE_LABELS=()
RECIPE_BLOCKS=()

for doc_rel in "${RECIPE_DOCS[@]}"; do
  doc_abs="$PLUGIN_ROOT/$doc_rel"
  outdir="$TMPROOT/extract-$(printf '%s' "$doc_rel" | tr '/.' '__')"
  n="$(extract_bash_fences "$doc_abs" "$outdir")"
  doc_candidates=0
  if [ "$n" -ge 1 ]; then
    for i in $(seq 1 "$n"); do
      block="$outdir/block-$i.sh"
      if is_cache_writing_block "$block"; then
        doc_candidates=$((doc_candidates + 1))
        RECIPE_LABELS+=("$doc_rel #$doc_candidates")
        RECIPE_BLOCKS+=("$block")
      fi
    done
  fi
  if [ "$doc_candidates" -ge 1 ]; then
    pass "$doc_rel carries at least one cache-mutating-git-verb fenced recipe"
  else
    fail "$doc_rel carries at least one cache-mutating-git-verb fenced recipe" \
      "found 0 fenced \`\`\`bash blocks containing clone/fetch/sparse-checkout/checkout or a cache-git.sh call"
  fi
done

section "cache-writing recipes spell the cache root through \$SKILL_ENGINE_CACHE_ROOT, never a bare \$HOME/~ literal"

sweep_hits=""
for idx in "${!RECIPE_BLOCKS[@]}"; do
  hits="$(sweep_block_for_bare_home "${RECIPE_BLOCKS[$idx]}")"
  if [ -n "$hits" ]; then
    while IFS= read -r hit; do
      sweep_hits="${sweep_hits}${RECIPE_LABELS[$idx]}: ${hit}"$'\n'
    done <<< "$hits"
  fi
done
if [ -z "$sweep_hits" ]; then
  pass "no cache-writing recipe spells .cache/skill-engine without SKILL_ENGINE_CACHE_ROOT on the same line"
else
  fail "no cache-writing recipe spells .cache/skill-engine without SKILL_ENGINE_CACHE_ROOT on the same line" \
    "$sweep_hits"
fi

section "each cache-writing recipe, executed literally under a fake HOME and an overridden cache root"

for idx in "${!RECIPE_BLOCKS[@]}"; do
  label="${RECIPE_LABELS[$idx]}"
  block="${RECIPE_BLOCKS[$idx]}"
  home="$TMPROOT/exec-home-$idx"
  override_root="$TMPROOT/exec-override-$idx"
  ctx="$TMPROOT/exec-ctx-$idx"
  mkdir -p "$home" "$ctx"

  if grep -qF '<old_sha>' "$block" && grep -qF '<new_sha>' "$block"; then
    # In-place-advance shaped: needs a pre-existing clone under the
    # override root to advance, at the SHA the recipe is told is "old".
    mkdir -p "$override_root/git-managed"
    cp -R "$RCP_ADVANCE_SEED/git-managed/widget-src-$RCP_SHA_A" \
      "$override_root/git-managed/widget-src-$RCP_SHA_A"
    run_candidate_recipe "$label (in-place advance)" "$block" "$ctx" "$home" "$override_root" \
      "$override_root/git-managed/widget-src-$RCP_SHA_B" \
      -e "s#<source_id>#widget-src#g" \
      -e "s#<old_sha>#$RCP_SHA_A#g" \
      -e "s#<new_sha>#$RCP_SHA_B#g"
  else
    # Fresh-clone shaped: clones the shared upstream at its current HEAD
    # (commit B) into a directory that does not exist yet.
    run_candidate_recipe "$label (fresh clone)" "$block" "$ctx" "$home" "$override_root" \
      "$override_root/git-managed/widget-src-$RCP_SHA_B" \
      -e "s#<source_id>#widget-src#g" \
      -e "s#<url>#file://$RCP_UPSTREAM#g" \
      -e "s#<ref>#HEAD#g" \
      -e 's#<files_of_interest entries\.\.\.>#"docs/**"#g'
  fi
done

# ===========================================================================
# Section 2 — git-verb-scan accepts the override spelling for exempted verbs
# ===========================================================================

section "git-verb-scan accepts the \${SKILL_ENGINE_CACHE_ROOT:-...} override spelling for exempted verbs"

VSCAN_SCRATCH_REL="skills/.oracle-cache-git-helper-scratch.md"
VSCAN_SCRATCH_LINE=4

VSCAN_DOCTRINE_OUT=""
VSCAN_DOCTRINE_EXIT=0
with_scratch_fixture() {
  {
    printf '%s\n' '# Scratch'
    printf '\n'
    printf '%s\n' '```bash'
    printf '%s\n' "$1"
    printf '%s\n' '```'
  } > "$SCRATCH_FILE"
  VSCAN_DOCTRINE_OUT="$(bash "$CI_LOCAL" doctrine 2>&1)"
  VSCAN_DOCTRINE_EXIT=$?
  rm -f "$SCRATCH_FILE"
}

# override_line <verb-and-args> — a realistic cache-scoped invocation
# spelled with the ${SKILL_ENGINE_CACHE_ROOT:-...} override form.
override_line() {
  printf 'git -C "${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}/git-managed/${source_id}-${sha}" %s' "$1"
}

# wrong_var_line <verb-and-args> — the same override shape, spelled with a
# variable name that is not SKILL_ENGINE_CACHE_ROOT.
wrong_var_line() {
  printf 'git -C "${OTHER_ROOT:-$HOME/.cache/skill-engine}/git-managed/${source_id}-${sha}" %s' "$1"
}

# wrong_subdir_line <verb-and-args> — the correctly-spelled override,
# targeting a path outside git-managed/ or web-doc/.
wrong_subdir_line() {
  printf 'git -C "${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}/other/${source_id}-${sha}" %s' "$1"
}

# bogus_path_line <verb-and-args> — neither the literal $HOME/~ spelling nor
# the override form: an arbitrary path that happens to contain
# "git-managed/".
bogus_path_line() {
  printf 'git -C "/some/other/path/git-managed/${source_id}-${sha}" %s' "$1"
}

# Scanner-level sanity first: the accept assertion below is meaningless if
# the scanner itself never reports this invocation as a candidate at all
# (a line the scanner cannot see reports "no violation" for the wrong
# reason — the trap tests/git-verb-cache-scope/run.sh exists to catch).
vscan_probe="$TMPROOT/vscan-probe.sh"
override_line 'fetch --depth=1 origin "$new_sha"' > "$vscan_probe"
vscan_raw="$(bash "$SCANNER" --root "$TMPROOT/" "$vscan_probe" 2>/dev/null)"
vscan_verb="$(printf '%s\n' "$vscan_raw" | awk -F: '{print $3}')"
vscan_ctarget="$(printf '%s\n' "$vscan_raw" | awk -F: '{print $4}')"
if [ "$vscan_verb" = "fetch" ] && printf '%s' "$vscan_ctarget" | grep -qF 'SKILL_ENGINE_CACHE_ROOT'; then
  pass "the scanner reports a fetch against the override-spelled -C target (not swallowed as a quoted literal)"
else
  fail "the scanner reports a fetch against the override-spelled -C target (not swallowed as a quoted literal)" \
    "verb: ${vscan_verb:-<none>}" "ctarget: ${vscan_ctarget:-<none>}"
fi

for verb_args in \
  'fetch:fetch --depth=1 origin "$sha"' \
  'sparse-checkout:sparse-checkout set "$pattern"' \
  'checkout:checkout "$sha"'
do
  verb="${verb_args%%:*}"
  args="${verb_args#*:}"
  with_scratch_fixture "$(override_line "$args")"
  reported="$(printf '%s\n' "$VSCAN_DOCTRINE_OUT" | grep -F "$VSCAN_SCRATCH_REL:$VSCAN_SCRATCH_LINE" || true)"
  if [ -z "$reported" ]; then
    pass "$verb against the \${SKILL_ENGINE_CACHE_ROOT:-...} override spelling passes check 4"
  else
    fail "$verb against the \${SKILL_ENGINE_CACHE_ROOT:-...} override spelling passes check 4" \
      "doctrine reported a violation:" "$reported"
  fi
done

expect_reject() {
  local label="$1" line="$2" verb="$3" hit
  with_scratch_fixture "$line"
  hit="$(printf '%s\n' "$VSCAN_DOCTRINE_OUT" | grep -F "$VSCAN_SCRATCH_REL:$VSCAN_SCRATCH_LINE" | grep -F "git $verb" || true)"
  if [ "$VSCAN_DOCTRINE_EXIT" -ne 0 ] && [ -n "$hit" ]; then
    pass "$label"
  else
    fail "$label" "exit: $VSCAN_DOCTRINE_EXIT" "matching line: ${hit:-<none>}"
  fi
}

expect_reject \
  "a checkout against the override form spelled with the wrong variable name still fails check 4" \
  "$(wrong_var_line 'checkout "$sha"')" 'checkout'
expect_reject \
  "a checkout against the correctly-spelled override targeting outside git-managed/ or web-doc/ still fails check 4" \
  "$(wrong_subdir_line 'checkout "$sha"')" 'checkout'
expect_reject \
  "a checkout against a bogus literal path (neither \$HOME/~ nor the override form) still fails check 4" \
  "$(bogus_path_line 'checkout "$sha"')" 'checkout'

vscan_baseline_out="$(bash "$CI_LOCAL" doctrine 2>&1)"
vscan_baseline_rc=$?
if [ "$vscan_baseline_rc" -eq 0 ]; then
  pass "doctrine passes on the repo as it stands, with no scratch fixture present"
else
  fail "doctrine passes on the repo as it stands, with no scratch fixture present" \
    "exit: $vscan_baseline_rc" "$vscan_baseline_out"
fi

# ===========================================================================
# Section 3 — cited_paths.py's git-managed resolution agrees with
# permalink_density.accepted_hosts()
# ===========================================================================

section "cited_paths.py's git-managed-source resolution agrees with accepted_hosts()"

REG_ROOT="$TMPROOT/registry-resolution"
reg_setup_out="$(python3 "$FIXTURES_PY" registry-resolution-fixture "$REG_ROOT" 2>&1)"
reg_setup_rc=$?
if [ "$reg_setup_rc" -ne 0 ]; then
  fail "registry-resolution fixture builds" "$reg_setup_out"
else
  reg_get() { printf '%s' "$reg_setup_out" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"$1\"])"; }
  m_refs="$(reg_get malformed_references_dir)"
  m_inv="$(reg_get malformed_inventory)"
  c_refs="$(reg_get control_references_dir)"
  c_inv="$(reg_get control_inventory)"

  # probe_hosts <refs-dir> — "true"/"false" for whether accepted_hosts()
  # read past a malformed proposed override to the live registry.
  probe_hosts() {
    python3 "$FIXTURES_PY" probe-accepted-hosts "$1" \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['probe_host_present'])"
  }
  # resolved_in_candidates <refs-dir> <inventory> — "true"/"false" for
  # whether cited_paths.py's own CLI resolved the widget-ref.md citation to
  # source_id "acme" (i.e., candidates carries a non-empty acme entry for
  # it) under --changed.
  resolved_in_candidates() {
    python3 "$CITED_PATHS_PY" "$1" --changed "$2" 2>/dev/null \
      | python3 -c "
import json, sys
d = json.load(sys.stdin)
entry = d.get('candidates', {}).get('widget-ref.md', {}).get('acme', [])
print(bool(entry))
"
  }

  m_hosts="$(probe_hosts "$m_refs")"
  m_cited="$(resolved_in_candidates "$m_refs" "$m_inv")"
  c_hosts="$(probe_hosts "$c_refs")"
  c_cited="$(resolved_in_candidates "$c_refs" "$c_inv")"

  if [ "$c_hosts" = "True" ] && [ "$c_cited" = "True" ]; then
    pass "positive control: with no proposed override present, both accepted_hosts() and cited_paths.py resolve the live registry"
  else
    fail "positive control: with no proposed override present, both accepted_hosts() and cited_paths.py resolve the live registry" \
      "accepted_hosts() read live: $c_hosts, cited_paths.py resolved: $c_cited"
  fi

  if [ "$m_hosts" = "$m_cited" ]; then
    pass "with a proposed override whose sources field is not a list, accepted_hosts() and cited_paths.py fall back the same way"
  else
    fail "with a proposed override whose sources field is not a list, accepted_hosts() and cited_paths.py fall back the same way" \
      "accepted_hosts() read past the malformed override to live: $m_hosts" \
      "cited_paths.py resolved the citation to source_id acme (i.e. also read past it): $m_cited" \
      "these must agree — either both read past the malformed override, or neither does"
  fi

  section "accepted_hosts()'s other known consumers still run cleanly against the same registry shape"

  # permalink_density.py's own CLI (SELF-AUDIT Check 7) is accepted_hosts()'s
  # original, defining consumer — it must keep crediting a forge-scoped
  # citation the same way regardless of how cited_paths.py's own resolution
  # is reshaped.
  c_ctx="$(dirname "$c_refs")"
  pd_out="$(python3 "$TESTS_ROOT/permalink_density.py" "$c_refs" 2>&1)"
  pd_rc=$?
  if [ "$pd_rc" -eq 0 ]; then
    pass "permalink_density.py's own CLI (Check 7) still runs cleanly against this registry shape"
  else
    fail "permalink_density.py's own CLI (Check 7) still runs cleanly against this registry shape" \
      "exit: $pd_rc" "$pd_out"
  fi

  # grounded_rate.py (SELF-AUDIT Check 8) calls
  # build_permalink_res(accepted_hosts(...)) unconditionally, even under
  # --dry-run (no API key, no network) — see permalink-forges/run.sh's own
  # header. An empty research/ directory (no eval-prompts.json) is a
  # legitimate [N/A], not a crash; a crash here would mean this consumer's
  # accepted_hosts() call started raising against a registry shape it used
  # to tolerate.
  gr_out="$(python3 "$TESTS_ROOT/grounded_rate.py" "$c_ctx" --dry-run 2>&1)"
  gr_rc=$?
  if [ "$gr_rc" -eq 0 ]; then
    pass "grounded_rate.py's --dry-run path (Check 8) still runs cleanly against this registry shape"
  else
    fail "grounded_rate.py's --dry-run path (Check 8) still runs cleanly against this registry shape" \
      "exit: $gr_rc" "$gr_out"
  fi
fi

# ===========================================================================
# Section 4 — every shipped since-last-check path reports a deletion, with
# no "changes": 1 placeholder
# ===========================================================================

section "since-last-check reports a genuine deletion between two commits"

# Reuses section 1's shared upstream fixture (RCP_UPSTREAM, RCP_SHA_A,
# RCP_SHA_B): commit B deletes dropped.txt relative to commit A.

# --- entry point: discover_inventory.py --last-checked-sha -----------------

SLC_HELP="$(python3 "$DISCOVER_INVENTORY_PY" --help 2>&1 || true)"
if printf '%s' "$SLC_HELP" | grep -qF -- '--last-checked-sha'; then
  slc_out="$(python3 "$DISCOVER_INVENTORY_PY" "$RCP_UPSTREAM" --last-checked-sha "$RCP_SHA_A" 2>&1)"
  slc_paths="$(printf '%s' "$slc_out" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print('')
    raise SystemExit
print(' '.join(f.get('path', '') for f in d.get('since_last_check', {}).get('files', [])))
" 2>/dev/null)"
  if printf '%s' "$slc_paths" | tr ' ' '\n' | grep -qx 'dropped.txt'; then
    pass "discover_inventory.py --last-checked-sha reports the deleted file"
  else
    fail "discover_inventory.py --last-checked-sha reports the deleted file" \
      "since_last_check.files paths: ${slc_paths:-<none>}" "raw output: $slc_out"
  fi
  if printf '%s' "$slc_out" | grep -qF '"changes": 1'; then
    fail "discover_inventory.py --last-checked-sha emits no \"changes\": 1 placeholder" \
      "found the literal placeholder in: $slc_out"
  else
    pass "discover_inventory.py --last-checked-sha emits no \"changes\": 1 placeholder"
  fi
else
  echo "  SKIP  discover_inventory.py no longer ships --last-checked-sha (consolidation may have removed it) — not asserted"
fi

# --- entry point: the discover-workflow's own since-last-check pipeline ----
# Extracted dynamically by content (a fenced ```bash block containing both
# --name-status and from_sha), never assumed to live at a fixed line, so a
# doc reflow or a move into a shipped helper is tolerated the same way.

find_since_check_block() {
  local file="$1" outdir="$2" n i
  outdir="$(mktemp -d "$TMPROOT/slc-extract-XXXXXX")"
  n="$(extract_bash_fences "$file" "$outdir")"
  [ "$n" -ge 1 ] || return 1
  for i in $(seq 1 "$n"); do
    if grep -qF -- '--name-status' "$outdir/block-$i.sh" && grep -qF 'from_sha' "$outdir/block-$i.sh"; then
      printf '%s' "$outdir/block-$i.sh"
      return 0
    fi
  done
  return 1
}

# run_since_check_pipeline <label> <block> <var-preamble> <ctx-root> <home>
#   [sed-args...]
# <var-preamble> covers a block that reads real shell variables directly
# (cache-and-clone.md's pipeline: $cache_dir, $last_checked_sha); trailing
# [sed-args...] cover a block that instead carries literal <angle-bracket>
# placeholders substituted textually before it ever runs (the in-place
# advance recipe's own <source_id>/<old_sha>/<new_sha>). <home> is always a
# fresh scratch directory, even for a block that never reads $HOME, so a
# future revision that starts referencing it cannot silently touch the
# real cache.
run_since_check_pipeline() {
  local label="$1" block="$2" var_preamble="$3" ctx_root="$4" home="$5"
  shift 5
  local script out rc
  script="$(mktemp "$TMPROOT/slc-run-XXXXXX")"
  {
    printf '%s\n' "$var_preamble"
    if [ "$#" -gt 0 ]; then
      sed "$@" "$block"
    else
      cat "$block"
    fi
  } > "$script"
  local leftover
  leftover="$(sed 's/#.*$//' "$script" | grep -oE '<[^>]+>' | sort -u | tr '\n' ' ')"
  if [ -n "$leftover" ]; then
    fail "$label reports the deleted file" \
      "unsubstituted placeholder(s) remain: $leftover"
    fail "$label emits no \"changes\": 1 placeholder" \
      "cannot evaluate — substitution left unknown placeholders (see above)"
    return
  fi
  mkdir -p "$ctx_root" "$home"
  out="$(cd "$ctx_root" && env HOME="$home" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$script" 2>&1)"
  rc=$?
  # The since-computation's result lands one of two ways depending on which
  # recipe this is: printed as the trailing line of stdout (the
  # discover-workflow pipeline, which ends by calling discover_inventory.py
  # directly), or merged into research/.discover-inventory.json under the
  # scratch contextualizer root (the in-place-advance recipe, which folds
  # its own result into that file rather than printing it). Whichever one
  # exists after the run is the one to read.
  local paths result_text inv_file
  inv_file="$ctx_root/research/.discover-inventory.json"
  if [ -f "$inv_file" ]; then
    result_text="$(cat "$inv_file")"
    paths="$(python3 -c "
import json
with open('$inv_file', encoding='utf-8') as fh:
    d = json.load(fh)
paths = []
for entry in d.values():
    since = (entry or {}).get('since_last_check') or {}
    paths.extend(f.get('path', '') for f in since.get('files', []))
print(' '.join(paths))
" 2>/dev/null)"
  else
    result_text="$out"
    paths="$(printf '%s' "$out" | python3 -c "
import json, sys
text = sys.stdin.read()
try:
    d = json.loads(text.strip().splitlines()[-1]) if text.strip() else {}
except ValueError:
    print('')
    raise SystemExit
print(' '.join(f.get('path', '') for f in d.get('since_last_check', {}).get('files', [])))
" 2>/dev/null)"
  fi
  if printf '%s' "$paths" | tr ' ' '\n' | grep -qx 'dropped.txt'; then
    pass "$label reports the deleted file"
  else
    fail "$label reports the deleted file" \
      "exit: $rc" "reported paths: ${paths:-<none>}" "output: $out"
  fi
  if printf '%s' "$result_text" | grep -qF '"changes": 1'; then
    fail "$label emits no \"changes\": 1 placeholder" "found the literal placeholder in: $result_text"
  else
    pass "$label emits no \"changes\": 1 placeholder"
  fi
}

exercised_since_check_paths=0

cc_block="$(find_since_check_block "$PLUGIN_ROOT/skills/discover/references/cache-and-clone.md" "$TMPROOT/slc-cc" || true)"
if [ -n "$cc_block" ]; then
  exercised_since_check_paths=$((exercised_since_check_paths + 1))
  run_since_check_pipeline "the discover-workflow pre-flight since-last-check pipeline" \
    "$cc_block" "$(printf 'cache_dir=%q\nlast_checked_sha=%q' "$RCP_UPSTREAM" "$RCP_SHA_A")" \
    "$TMPROOT/slc-cc-ctx" "$TMPROOT/slc-cc-home"
else
  echo "  SKIP  no since-last-check pipeline found in cache-and-clone.md (may have moved into a shipped helper) — not asserted"
fi

to_block="$(find_since_check_block "$PLUGIN_ROOT/skills/refresh/references/tool-and-output-mechanics.md" "$TMPROOT/slc-to" || true)"
if [ -n "$to_block" ]; then
  exercised_since_check_paths=$((exercised_since_check_paths + 1))
  # This recipe reads $HOME/.cache/skill-engine/... directly, so the
  # pre-existing stale clone it is meant to advance has to be seeded there
  # (in the fake, scratch HOME below) rather than under any override root.
  slc_to_home="$TMPROOT/slc-to-home"
  mkdir -p "$slc_to_home/.cache/skill-engine/git-managed"
  cp -R "$RCP_ADVANCE_SEED/git-managed/widget-src-$RCP_SHA_A" \
    "$slc_to_home/.cache/skill-engine/git-managed/widget-src-$RCP_SHA_A"
  run_since_check_pipeline "the refresh-workflow's in-place-advance since-last-check computation" \
    "$to_block" "" "$TMPROOT/slc-to-ctx" "$slc_to_home" \
    -e "s#<source_id>#widget-src#g" -e "s#<old_sha>#$RCP_SHA_A#g" -e "s#<new_sha>#$RCP_SHA_B#g"
else
  echo "  SKIP  no since-last-check computation found in tool-and-output-mechanics.md (may have moved into a shipped helper) — not asserted"
fi

if printf '%s' "$SLC_HELP" | grep -qF -- '--last-checked-sha'; then
  exercised_since_check_paths=$((exercised_since_check_paths + 1))
fi

if [ "$exercised_since_check_paths" -ge 1 ]; then
  pass "at least one shipped since-last-check code path was exercised"
else
  fail "at least one shipped since-last-check code path was exercised" \
    "found none of: discover_inventory.py --last-checked-sha, cache-and-clone.md's pipeline, tool-and-output-mechanics.md's pipeline"
fi

section "no shipped since-last-check code path emits the \"changes\": 1 placeholder field"

placeholder_hits="$(grep -rn '"changes": 1' "$PLUGIN_ROOT" \
  --include='*.py' --include='*.md' --include='*.sh' 2>/dev/null \
  | grep -v "^$SCRIPT_DIR/" || true)"
if [ -z "$placeholder_hits" ]; then
  pass "no file under plugin/skill-engine (excluding this suite's own fixtures) contains the literal placeholder \"changes\": 1"
else
  fail "no file under plugin/skill-engine (excluding this suite's own fixtures) contains the literal placeholder \"changes\": 1" \
    "$placeholder_hits"
fi

section "since-last-check calibration: a shallow clone and a detached-HEAD merge commit"

# Calibration 1 — a --depth 1 clone of the fixture's final state. The old
# SHA is not reachable in a shallow store of ONLY the final commit, so
# compute_since_last_check_git's own cat-file -e guard is expected to
# return None and omit since_last_check entirely — a finding to report,
# not a pass/fail on its own.
CAL_SHALLOW="$TMPROOT/cal-shallow"
git clone -q --depth 1 "file://$RCP_UPSTREAM" "$CAL_SHALLOW" >/dev/null 2>&1
cal_shallow_out="$(python3 "$DISCOVER_INVENTORY_PY" "$CAL_SHALLOW" --last-checked-sha "$RCP_SHA_A" 2>&1)"
cal_shallow_has_slc="$(printf '%s' "$cal_shallow_out" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print('parse-error')
    raise SystemExit
print('present' if 'since_last_check' in d else 'omitted')
" 2>/dev/null)"
echo "  CALIBRATION  --depth 1 clone of the fixture: since_last_check is $cal_shallow_has_slc"

# Calibration 2 — HEAD detached at a synthetic merge commit. A two-tree
# diff is topology-agnostic, so the deletion should still be reported
# regardless of HEAD being a merge commit.
CAL_MERGE="$TMPROOT/cal-merge"
git clone -q "file://$RCP_UPSTREAM" "$CAL_MERGE" >/dev/null 2>&1
git -C "$CAL_MERGE" checkout -q -b side "$RCP_SHA_A" >/dev/null 2>&1
printf 'side\n' > "$CAL_MERGE/side.txt"
git -C "$CAL_MERGE" add -A
git -C "$CAL_MERGE" -c user.email=oracle@example.invalid -c user.name=oracle \
  commit -q -m "side commit"
git -C "$CAL_MERGE" checkout -q main >/dev/null 2>&1
git -C "$CAL_MERGE" -c user.email=oracle@example.invalid -c user.name=oracle \
  merge -q --no-ff -m "synthetic merge" side >/dev/null 2>&1
git -C "$CAL_MERGE" checkout -q --detach HEAD >/dev/null 2>&1
cal_merge_out="$(python3 "$DISCOVER_INVENTORY_PY" "$CAL_MERGE" --last-checked-sha "$RCP_SHA_A" 2>&1)"
cal_merge_paths="$(printf '%s' "$cal_merge_out" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print('')
    raise SystemExit
print(' '.join(f.get('path', '') for f in d.get('since_last_check', {}).get('files', [])))
" 2>/dev/null)"
if printf '%s' "$cal_merge_paths" | tr ' ' '\n' | grep -qx 'dropped.txt'; then
  echo "  CALIBRATION  detached HEAD at a synthetic merge commit: deletion still reported"
else
  echo "  CALIBRATION  detached HEAD at a synthetic merge commit: deletion NOT reported (paths: ${cal_merge_paths:-<none>})"
fi

# ===========================================================================
# Section 5 — cited_paths.py's candidate-set computation stays fast at scale
# ===========================================================================

section "cited_paths.py's candidate-set computation completes with margin at 2,000 refs x 20 cites x 5,000 changed paths"

TIMING_ROOT="$TMPROOT/timing"
timing_setup_out="$(python3 "$FIXTURES_PY" candidate-set-timing-fixture "$TIMING_ROOT" 2000 20 5000 2>&1)"
timing_setup_rc=$?
if [ "$timing_setup_rc" -ne 0 ]; then
  fail "candidate-set timing fixture builds" "$timing_setup_out"
else
  timing_refs="$(printf '%s' "$timing_setup_out" | python3 -c "import json,sys; print(json.load(sys.stdin)['references_dir'])")"
  timing_inv="$(printf '%s' "$timing_setup_out" | python3 -c "import json,sys; print(json.load(sys.stdin)['inventory'])")"

  bare_start=$(python3 -c 'import time; print(time.monotonic())')
  python3 "$CITED_PATHS_PY" "$timing_refs" > /dev/null 2>&1
  bare_end=$(python3 -c 'import time; print(time.monotonic())')
  bare_seconds=$(python3 -c "print(f'{$bare_end - $bare_start:.3f}')")

  changed_start=$(python3 -c 'import time; print(time.monotonic())')
  python3 "$CITED_PATHS_PY" "$timing_refs" --changed "$timing_inv" > "$TMPROOT/timing-out.json" 2>&1
  changed_rc=$?
  changed_end=$(python3 -c 'import time; print(time.monotonic())')
  changed_seconds=$(python3 -c "print(f'{$changed_end - $changed_start:.3f}')")
  delta_seconds=$(python3 -c "print(f'{$changed_end - $changed_start - ($bare_end - $bare_start):.3f}')")

  echo "  MEASURED  bare scan (no --changed): ${bare_seconds}s"
  echo "  MEASURED  --changed (full candidate-set computation): ${changed_seconds}s"
  echo "  MEASURED  delta attributable to candidate-set computation: ${delta_seconds}s"

  if [ "$changed_rc" -ne 0 ]; then
    fail "cited_paths.py --changed exits 0 on the timing fixture" \
      "exit: $changed_rc" "$(cat "$TMPROOT/timing-out.json" 2>/dev/null)"
  fi

  # 3s bound per the acceptance target, with no extra slack layered on top:
  # a correctly-linearized computation over this fixture is expected to
  # finish in well under a second, leaving ample headroom for CI-runner
  # variance without the bound itself being noise-sensitive.
  bound_ok="$(python3 -c "print('yes' if $changed_seconds < 3.0 else 'no')")"
  if [ "$bound_ok" = "yes" ]; then
    pass "cited_paths.py --changed completes in under 3 seconds at this fixture size (${changed_seconds}s)"
  else
    fail "cited_paths.py --changed completes in under 3 seconds at this fixture size" \
      "measured: ${changed_seconds}s"
  fi
fi

# ===========================================================================
# Section 6 — bin/cache-git.sh's sparse-clone mechanics, pinned on the
# shipped helper and calibrated by mutation
# ===========================================================================
#
# These properties used to be pinned by tests/sparse-clone/run.sh, by
# grepping the two reference docs for the raw git invocation they spelled
# out. Chunk 08 moved that invocation into this helper, and the doc-level
# checks -- with no raw git line left to inspect -- were bypassed under a
# `delegates=1` flag whose comment said the helper's own oracle pinned them
# instead. It did not: nothing in this suite mentioned --filter=blob:none,
# --no-checkout, --single-branch, --no-cone or -maxdepth 2, and
# sparse-clone/run.sh was the repo's only pin on that flag set. Eleven
# assertions printed as passes while asserting nothing (PR #15 review,
# finding 2). This section is where those claims become true again, made
# against real code rather than against prose describing it.
#
# Every pin here is a PRESERVATION assertion: it says a property the helper
# already has must keep holding. No red->green step calibrates one -- the
# property is present before and after any change that does not target it,
# so an assertion that never fires is indistinguishable from one that
# cannot. Each pin is therefore run twice: once against the real helper,
# and once against a copy with exactly that property removed, where it must
# report failure. A pin that passes its own mutant is the vacuous green
# this section exists to prevent.

section "bin/cache-git.sh's sparse-clone mechanics are pinned on the shipped helper"

CACHE_GIT_SH="$PLUGIN_ROOT/bin/cache-git.sh"

# extract_fn <file> <fn-name> — one shell function's body, from its opening
# line through the first bare closing brace.
extract_fn() {
  awk -v fn="$2" '
    index($0, fn "() {") == 1 { inside = 1 }
    inside { print }
    inside && $0 == "}" { exit }
  ' "$1"
}

# every_clone_carries <body> <flag> — every `git clone` line in <body>
# carries <flag>. A body with no clone line at all fails: a predicate that
# has lost its subject must report absence, not vacuous truth.
every_clone_carries() {
  local body="$1" flag="$2" line seen=0
  while IFS= read -r line; do
    case "$line" in
      *"git clone"*)
        seen=$((seen + 1))
        printf '%s' "$line" | grep -qF -- "$flag" || return 1
        ;;
    esac
  done <<< "$body"
  [ "$seen" -ge 1 ]
}

# scoped_verb <body> <verb-ere> — <body> invokes <verb> with a -C target
# spelled through the ${SKILL_ENGINE_CACHE_ROOT:-...} override under
# git-managed/. One predicate for the three claims the doc-level oracle made
# separately (the verb is present, it carries -C, the recipe is cache-
# scoped): in real code they are one line to inspect.
scoped_verb() {
  printf '%s\n' "$1" \
    | grep -E "$2" \
    | grep -F -- '-C "${SKILL_ENGINE_CACHE_ROOT:-' \
    | grep -qF '/git-managed/'
}

pin_label() {
  case "$1" in
    depth)          printf '%s' 'every sparse clone carries --depth=1' ;;
    single-branch)  printf '%s' 'every sparse clone carries --single-branch' ;;
    blob-filter)    printf '%s' 'every sparse clone carries --filter=blob:none' ;;
    no-checkout)    printf '%s' 'every sparse clone carries --no-checkout' ;;
    sparse-init)    printf '%s' 'sparse-checkout init --no-cone runs against a cache-scoped -C target' ;;
    sparse-set)     printf '%s' 'sparse-checkout set runs against a cache-scoped -C target' ;;
    bare-checkout)  printf '%s' 'a bare checkout (not sparse-checkout) runs against a cache-scoped -C target' ;;
    sibling-depth)  printf '%s' "the post-clone validator's sibling lookup searches to -maxdepth 2" ;;
    reject-wording) printf '%s' "the post-clone validator's diagnostic says an entry resolved no files" ;;
  esac
}

check_pin() {
  local body="$1" key="$2"
  case "$key" in
    depth)          every_clone_carries "$body" '--depth=1' ;;
    single-branch)  every_clone_carries "$body" '--single-branch' ;;
    blob-filter)    every_clone_carries "$body" '--filter=blob:none' ;;
    no-checkout)    every_clone_carries "$body" '--no-checkout' ;;
    sparse-init)    scoped_verb "$body" 'sparse-checkout[[:space:]]+init[[:space:]]+--no-cone' ;;
    sparse-set)     scoped_verb "$body" 'sparse-checkout[[:space:]]+set' ;;
    bare-checkout)  scoped_verb "$body" '(^|[[:space:]])checkout([[:space:]]|$)' ;;
    sibling-depth)  printf '%s\n' "$body" | grep -qF -- '-maxdepth 2' ;;
    reject-wording) printf '%s\n' "$body" | grep -qF 'resolved no files' ;;
    *)              return 2 ;;
  esac
}

# mutation_sed <key> — a sed program that removes exactly the property
# <key> pins, and nothing else it is asked to assert about.
mutation_sed() {
  case "$1" in
    depth)          printf '%s' 's/ --depth=1//g' ;;
    single-branch)  printf '%s' 's/ --single-branch//g' ;;
    blob-filter)    printf '%s' 's/ --filter=blob:none//g' ;;
    no-checkout)    printf '%s' 's/ --no-checkout//g' ;;
    sparse-init)    printf '%s' 's/ --no-cone//g' ;;
    sparse-set)     printf '%s' '/sparse-checkout set/d' ;;
    bare-checkout)  printf '%s' 's/" checkout ;/" ;/' ;;
    sibling-depth)  printf '%s' 's/-maxdepth 2/-maxdepth 9/' ;;
    reject-wording) printf '%s' 's/resolved no files/found nothing/' ;;
  esac
}

CACHE_GIT_PINS=(depth single-branch blob-filter no-checkout sparse-init
  sparse-set bare-checkout sibling-depth reject-wording)

helper_body="$(extract_fn "$CACHE_GIT_SH" cmd_sparse_clone)"
if [ -z "$helper_body" ]; then
  fail "bin/cache-git.sh: cmd_sparse_clone is extractable" \
    "found no cmd_sparse_clone() { ... } block — every pin below would be vacuous"
else
  pass "bin/cache-git.sh: cmd_sparse_clone is extractable"

  for pin_key in "${CACHE_GIT_PINS[@]}"; do
    if check_pin "$helper_body" "$pin_key"; then
      pass "bin/cache-git.sh: $(pin_label "$pin_key")"
    else
      fail "bin/cache-git.sh: $(pin_label "$pin_key")"
    fi
  done

  section "each pin above is mutation-calibrated: remove the property, the pin must report it"

  for pin_key in "${CACHE_GIT_PINS[@]}"; do
    mutant="$TMPROOT/mutant-$pin_key.sh"
    sed "$(mutation_sed "$pin_key")" "$CACHE_GIT_SH" > "$mutant"
    if cmp -s "$mutant" "$CACHE_GIT_SH"; then
      fail "calibration: $(pin_label "$pin_key")" \
        "the mutation left bin/cache-git.sh unchanged — it no longer removes the property it is calibrating, so this pin is uncalibrated"
    elif check_pin "$(extract_fn "$mutant" cmd_sparse_clone)" "$pin_key"; then
      fail "calibration: $(pin_label "$pin_key")" \
        "the pin passed a helper with that property removed — it asserts nothing"
    else
      pass "calibration: $(pin_label "$pin_key") fails on a helper with that property removed"
    fi
  done
fi

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"

[ "$fail_count" -eq 0 ]
