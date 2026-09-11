#!/usr/bin/env bash
# Black-box oracle for crawling a promoted monorepo slice from a sparse
# working tree scoped to its own paths, with per-slice findings merging into
# one staged proposal.
#
# THE INVARIANTS.
#   - A promoted slice's crawl reads a sparse checkout of the parent at the
#     parent's current commit, scoped to the slice's own path patterns, under
#     the engine's cache root -- never a full working tree of the parent.
#   - Running the checkout recipe against a real multi-slice repository
#     produces, for one slice, a working tree that holds that slice's files
#     and no file that belongs only to a sibling slice.
#   - Two slices sharing a parent may be checked out together with a unioned
#     pattern set when clustered; run independently (the common case, and the
#     only one a deterministic fixture can force), neither slice's working
#     tree ever contains a file that belongs only to the other.
#   - After crawling every promoted slice, one staged proposal holds all of
#     it: one $CTX_PROPOSED tree, one manifest.json, one REVIEW.md. The
#     post-run summary groups findings by slice id, and the per-slice cache
#     record captures the SHA that was actually crawled.
#   - A per-slice CLAUDE.md is documented as opt-in context-shaping the
#     engine itself never reads -- Claude Code's native nested-context
#     loading is what delivers it -- sized at roughly 30-100 lines.
#   - No whole-tree clone or checkout of the parent monorepo appears in the
#     cache at any point during a sliced crawl -- every cached directory a
#     sliced crawl touches is, observably, a sparse checkout.
#
# THIS ORACLE HAS TWO HALVES: prose assertions against the reference docs
# (wrap-normalized -- see norm() below; these are hand-wrapped Markdown
# files, and a naive line-oriented grep silently misses a phrase that
# happens to cross a line break), and an executed half against a real git
# repository built fresh in a tmpdir with real commits.
#
# THE EXECUTED HALF'S EXTRACTION CONTRACT (this oracle's own interpretive
# choice -- spec prose does not pin an exact block name or calling
# convention, so this is flagged for the plan gate rather than treated as
# settled). Wherever `discover/references/cache-and-clone.md` carries the
# slice-checkout recipe as a fenced shell block delimited by the sentinel
# pair
#
#   <!-- doctrine:slice-sparse-checkout:start -->
#   ```bash
#   ...
#   ```
#   <!-- doctrine:slice-sparse-checkout:end -->
#
# (following the `doctrine:slice-source-entries` / `doctrine:clone-consent-
# guard` / `doctrine:discover-cache-hit-check` precedent already in that same
# file), this runner extracts the block and runs it as
#
#   bash <extracted-block> <source_id> <url> <ref> -- <pattern>...
#
# with $CLAUDE_PLUGIN_ROOT exported to this repo's plugin root (the same
# convention every other extracted recipe in this codebase already assumes).
# The block's own job, observably, is: produce a sparse checkout of <url> at
# <ref> under the engine's cache root, scoped to <pattern>..., the same
# outcome `bin/cache-git.sh sparse-clone` already produces for a
# `files_of_interest`-scoped source (v0.8.0's chunk owns that recipe; this
# feature only ever activates it from a slice's own paths) -- this oracle
# does not care whether the block calls that helper directly or reimplements
# the three `git sparse-checkout` steps inline, only what lands on disk.
#
# Right now no such marker, and no such block, exists anywhere in
# cache-and-clone.md -- every extraction below comes back empty and every
# assertion that depends on it fails for that reason: the behavior is
# absent, not the harness broken. That absence is itself the expected red
# this oracle exists to turn green later.
#
# -e is intentionally omitted: every assertion runs and reports, not abort
# at the first failing one. Every tmpdir this file creates is removed on
# exit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_ROOT/.." && pwd)"

CACHE_AND_CLONE="$PLUGIN_ROOT/skills/discover/references/cache-and-clone.md"
TOOL_AND_OUTPUT="$PLUGIN_ROOT/skills/refresh/references/tool-and-output-mechanics.md"
MONOREPO_DOC="$PLUGIN_ROOT/docs/07-monorepo-adapter.md"
CACHE_GIT_SH="$PLUGIN_ROOT/bin/cache-git.sh"

for f in "$CACHE_AND_CLONE" "$TOOL_AND_OUTPUT" "$MONOREPO_DOC" "$CACHE_GIT_SH"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: expected surface is missing entirely: $f" >&2
    exit 69
  fi
done

WORK="$(mktemp -d -t skill-engine-slice-sparse-crawl.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass_count=0
fail_count=0

section() { printf '\n── %s ──\n' "$1"; }

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

# ---------------------------------------------------------------------------
# Text-matching helpers (wrap-normalized prose assertions).
# ---------------------------------------------------------------------------

norm() { tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }
norm_file() { norm < "$1"; }

extract_heading_section() {
  awk -v want="$1" '
    /^###? / {
      if (found) exit
      title = $0
      sub(/^###?[ \t]*/, "", title)
      if (index(title, want) == 1) { found = 1; print; next }
      next
    }
    found { print }
  ' "$2"
}

# near <text> <anchor-ere> <needle-ere> <window> — true when <needle> occurs
# within <window> characters of some occurrence of <anchor> in <text>.
near() {
  local text="$1" anchor="$2" needle="$3" window="$4"
  # `grep -c ... > /dev/null`, not `grep -q`: -q exits at its first match,
  # SIGPIPE-ing the upstream -o while it is still writing remaining windows,
  # which under `pipefail` can misreport a real match as a miss.
  printf '%s' "$text" \
    | grep -oiE ".{0,${window}}${anchor}.{0,${window}}" \
    | grep -ciE -- "$needle" > /dev/null
}

near_all() {
  local text="$1" anchor="$2" window="$3"
  shift 3
  local needle
  for needle in "$@"; do
    near "$text" "$anchor" "$needle" "$window" || return 1
  done
  return 0
}

assert_contains() {
  local label="$1" text="$2" lit="$3"
  if printf '%s' "$text" | grep -qF -- "$lit"; then
    pass "$label"
  else
    fail "$label" "string not found: $lit"
  fi
}

# ===========================================================================
# Section A — the slice sparse-checkout recipe: extraction contract.
# ===========================================================================
section "slice sparse-checkout recipe — extraction from cache-and-clone.md"

MARKER_START='<!-- doctrine:slice-sparse-checkout:start -->'
MARKER_END='<!-- doctrine:slice-sparse-checkout:end -->'

EXTRACTED_RECIPE=""
extract_recipe_block() {
  local label="$1" file="$2"
  EXTRACTED_RECIPE=""
  local s_count e_count sl el
  s_count="$(grep -c -F -- "$MARKER_START" "$file")"
  e_count="$(grep -c -F -- "$MARKER_END" "$file")"

  if [ "$s_count" -eq 0 ] && [ "$e_count" -eq 0 ]; then
    fail "$label" "no ${MARKER_START} / ${MARKER_END} pair found in $file"
    return 1
  fi
  if [ "$s_count" -ne 1 ] || [ "$e_count" -ne 1 ]; then
    fail "$label" "$s_count start / $e_count end sentinels in $file (need exactly one of each)"
    return 1
  fi

  sl="$(grep -n -F -- "$MARKER_START" "$file" | head -n1 | cut -d: -f1)"
  el="$(grep -n -F -- "$MARKER_END" "$file" | head -n1 | cut -d: -f1)"
  if [ "$sl" -ge "$el" ]; then
    fail "$label" "end sentinel is not after start sentinel in $file"
    return 1
  fi

  local body
  body="$(sed -n "$((sl + 1)),$((el - 1))p" "$file" | grep -vE '^[[:space:]]*```')"
  if [ -z "${body//[$'\t\r\n ']/}" ]; then
    fail "$label" "sentinel pair found in $file but the block between them is empty"
    return 1
  fi

  local outfile syntax_err
  outfile="$(mktemp "$WORK/recipe-block-XXXXXX")"
  printf '%s\n' "$body" > "$outfile"
  syntax_err="$(mktemp "$WORK/recipe-syntax-err-XXXXXX")"
  if ! bash -n "$outfile" 2>"$syntax_err"; then
    fail "$label" "extracted block from $file is not valid shell:" "$(cat "$syntax_err")"
    return 1
  fi

  pass "$label"
  EXTRACTED_RECIPE="$outfile"
  return 0
}

RECIPE_BLOCK=""
if extract_recipe_block "slice-sparse-checkout block: present, well-formed, exactly one pair" "$CACHE_AND_CLONE"; then
  RECIPE_BLOCK="$EXTRACTED_RECIPE"
fi

NO_BLOCK_REASON="cannot evaluate — no slice-sparse-checkout block found (see the extraction result above)"

# run_recipe <source_id> <url> <ref> <pattern>... — runs the extracted block
# as `CLAUDE_PLUGIN_ROOT=<repo plugin root> bash <block> <source_id> <url>
# <ref> -- <pattern>...`, mirroring this oracle's own documented contract.
# Sets RECIPE_RC / RECIPE_OUT / RECIPE_ERR.
RECIPE_RC=0
RECIPE_OUT=""
RECIPE_ERR=""
run_recipe() {
  local source_id="$1" url="$2" ref="$3"
  shift 3
  local outfile errfile
  outfile="$(mktemp "$WORK/recipe-run-out-XXXXXX")"
  errfile="$(mktemp "$WORK/recipe-run-err-XXXXXX")"
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" SKILL_ENGINE_CACHE_ROOT="$SLICE_CACHE_ROOT" \
    bash "$RECIPE_BLOCK" "$source_id" "$url" "$ref" -- "$@" >"$outfile" 2>"$errfile"
  RECIPE_RC=$?
  RECIPE_OUT="$(cat "$outfile")"
  RECIPE_ERR="$(cat "$errfile")"
}

# ===========================================================================
# Section B — fixtures: a real three-slice monorepo, one parent, real
# commits, cloned from a real (local) bare remote.
# ===========================================================================
section "fixtures — a real three-slice monorepo repository"

SRC_TREE="$WORK/src"
mkdir -p \
  "$SRC_TREE/packages/billing" "$SRC_TREE/shared/billing-types" \
  "$SRC_TREE/packages/auth" "$SRC_TREE/services/auth-api" \
  "$SRC_TREE/apps/reports-dashboard"

printf 'def charge():\n    pass\n' > "$SRC_TREE/packages/billing/main.py"
printf 'class Invoice:\n    pass\n' > "$SRC_TREE/shared/billing-types/types.py"
printf 'def login():\n    pass\n' > "$SRC_TREE/packages/auth/main.py"
printf 'def token():\n    pass\n' > "$SRC_TREE/services/auth-api/api.py"
printf 'def render():\n    pass\n' > "$SRC_TREE/apps/reports-dashboard/main.py"
printf '# big monorepo\n' > "$SRC_TREE/README.md"

git -C "$SRC_TREE" init -q -b main
git -C "$SRC_TREE" config user.email 'fixture@example.com'
git -C "$SRC_TREE" config user.name 'fixture'
git -C "$SRC_TREE" add -A
GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com \
  GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com \
  git -C "$SRC_TREE" commit -q -m 'seed three-slice monorepo'
PARENT_SHA="$(git -C "$SRC_TREE" rev-parse HEAD)"

PARENT_BARE="$WORK/bare-monorepo.git"
git clone -q --bare "$SRC_TREE" "$PARENT_BARE" >/dev/null 2>&1

if [ -n "$PARENT_SHA" ] && [ -d "$PARENT_BARE" ]; then
  pass "fixture: a real parent monorepo repo exists with a resolvable HEAD SHA and a clonable bare remote"
else
  fail "fixture: a real parent monorepo repo exists with a resolvable HEAD SHA and a clonable bare remote"
fi

PARENT_ID="bigmono"
BILLING_ID="${PARENT_ID}-billing"
AUTH_ID="${PARENT_ID}-auth"
REPORTS_ID="${PARENT_ID}-reports"

# Path patterns taken verbatim from 07-monorepo-adapter.md §7.3's own
# illustrative schema example (billing / auth / reports), not invented here.
BILLING_PATTERNS=("packages/billing/**" "shared/billing-types/**")
AUTH_PATTERNS=("packages/auth/**" "services/auth-api/**")
REPORTS_PATTERNS=("apps/reports-dashboard/**")

# Exclusive on-disk files per slice — used below to detect cross-slice leakage.
BILLING_FILES=("packages/billing/main.py" "shared/billing-types/types.py")
AUTH_FILES=("packages/auth/main.py" "services/auth-api/api.py")
REPORTS_FILES=("apps/reports-dashboard/main.py")

# Same files, flattened and tagged by owning slice ("<path>|<slice tag>") —
# used by Section E to count how many distinct slices a cached directory's
# on-disk contents span, without per-slice array indirection.
TAGGED_SLICE_FILES=(
  "packages/billing/main.py|billing"
  "shared/billing-types/types.py|billing"
  "packages/auth/main.py|auth"
  "services/auth-api/api.py|auth"
  "apps/reports-dashboard/main.py|reports"
)

SLICE_CACHE_ROOT="$WORK/cache-root"
mkdir -p "$SLICE_CACHE_ROOT"

# on_disk_files <dir> — every regular file under <dir>, excluding .git/,
# relative to <dir>. Deliberately NOT `git ls-files`: the sparse-checkout
# index still tracks every path in the whole repo even when the working
# tree materializes only the sparse subset (independently confirmed below,
# and in this oracle's own report), so only a real filesystem walk tells
# the truth about what actually landed on disk.
on_disk_files() {
  find "$1" -type f -not -path '*/.git/*' 2>/dev/null | sed "s#^$1/##" | sort
}

contains_line() {
  local haystack="$1" needle="$2"
  printf '%s\n' "$haystack" | grep -qxF -- "$needle"
}

# ===========================================================================
# Section C — executed: the billing slice's checkout holds only billing
# files, under the cache root, at the parent's current SHA.
# ===========================================================================
section "executed — a promoted slice's checkout holds only its own files"

if [ -n "$RECIPE_BLOCK" ]; then
  run_recipe "$BILLING_ID" "$PARENT_BARE" "HEAD" "${BILLING_PATTERNS[@]}"

  if [ "$RECIPE_RC" -eq 0 ]; then
    pass "the recipe exits 0 for a promoted slice against a real parent repo"
  else
    fail "the recipe exits 0 for a promoted slice against a real parent repo" \
      "rc=$RECIPE_RC stdout: $RECIPE_OUT stderr: $RECIPE_ERR"
  fi

  EXPECTED_BILLING_DIR="$SLICE_CACHE_ROOT/git-managed/${BILLING_ID}-${PARENT_SHA}"
  if [ -d "$EXPECTED_BILLING_DIR" ]; then
    pass "the checkout lands under the cache root, named <source_id>-<parent SHA>"
  else
    fail "the checkout lands under the cache root, named <source_id>-<parent SHA>" \
      "expected directory: $EXPECTED_BILLING_DIR" \
      "cache root contents: $(find "$SLICE_CACHE_ROOT" -maxdepth 3 2>&1)"
  fi

  if [ -d "$EXPECTED_BILLING_DIR" ]; then
    billing_on_disk="$(on_disk_files "$EXPECTED_BILLING_DIR")"
    expected_billing="$(printf '%s\n' "${BILLING_FILES[@]}" | sort)"
    if [ "$billing_on_disk" = "$expected_billing" ]; then
      pass "the billing checkout's working tree is exactly the billing slice's files — nothing more, nothing less"
    else
      fail "the billing checkout's working tree is exactly the billing slice's files — nothing more, nothing less" \
        "expected:" "$expected_billing" "got:" "$billing_on_disk"
    fi

    leak=0
    for f in "${AUTH_FILES[@]}" "${REPORTS_FILES[@]}"; do
      if contains_line "$billing_on_disk" "$f"; then
        leak=1
        fail "the billing checkout contains no file belonging only to a sibling slice" "found sibling file: $f"
      fi
    done
    [ "$leak" -eq 0 ] && pass "the billing checkout contains no file belonging only to a sibling slice"

    if git -C "$EXPECTED_BILLING_DIR" sparse-checkout list >"$WORK/sc-list.out" 2>/dev/null; then
      sc_list="$(cat "$WORK/sc-list.out")"
      sc_ok=1
      for p in "${BILLING_PATTERNS[@]}"; do
        contains_line "$sc_list" "$p" || sc_ok=0
      done
      if [ "$sc_ok" -eq 1 ]; then
        pass "the billing checkout's sparse-checkout pattern set is exactly the billing slice's slice_paths"
      else
        fail "the billing checkout's sparse-checkout pattern set is exactly the billing slice's slice_paths" \
          "expected patterns: ${BILLING_PATTERNS[*]}" "sparse-checkout list: $sc_list"
      fi
    else
      fail "the billing checkout's sparse-checkout pattern set is exactly the billing slice's slice_paths" \
        "\`git sparse-checkout list\` failed — this worktree is not even sparse"
    fi

    billing_head="$(git -C "$EXPECTED_BILLING_DIR" rev-parse HEAD 2>/dev/null || true)"
    if [ "$billing_head" = "$PARENT_SHA" ]; then
      pass "the checkout is at the parent's current commit"
    else
      fail "the checkout is at the parent's current commit" \
        "parent HEAD: $PARENT_SHA, checkout HEAD: $billing_head"
    fi
  fi
else
  for label in \
    "the recipe exits 0 for a promoted slice against a real parent repo" \
    "the checkout lands under the cache root, named <source_id>-<parent SHA>" \
    "the billing checkout's working tree is exactly the billing slice's files — nothing more, nothing less" \
    "the billing checkout contains no file belonging only to a sibling slice" \
    "the billing checkout's sparse-checkout pattern set is exactly the billing slice's slice_paths" \
    "the checkout is at the parent's current commit"; do
    fail "$label" "$NO_BLOCK_REASON"
  done
fi

# ===========================================================================
# Section D — executed: slices processed independently (unclustered — the
# only deterministic case a fixture can force) never see a sibling's files,
# in either direction.
# ===========================================================================
section "executed — independent slices never see a sibling's files"

if [ -n "$RECIPE_BLOCK" ]; then
  run_recipe "$AUTH_ID" "$PARENT_BARE" "HEAD" "${AUTH_PATTERNS[@]}"
  auth_run_ok=$([ "$RECIPE_RC" -eq 0 ] && echo 1 || echo 0)

  EXPECTED_AUTH_DIR="$SLICE_CACHE_ROOT/git-managed/${AUTH_ID}-${PARENT_SHA}"
  EXPECTED_BILLING_DIR="$SLICE_CACHE_ROOT/git-managed/${BILLING_ID}-${PARENT_SHA}"

  if [ "$auth_run_ok" = "1" ] && [ -d "$EXPECTED_AUTH_DIR" ]; then
    auth_on_disk="$(on_disk_files "$EXPECTED_AUTH_DIR")"
    leak=0
    for f in "${BILLING_FILES[@]}" "${REPORTS_FILES[@]}"; do
      contains_line "$auth_on_disk" "$f" && leak=1
    done
    if [ "$leak" -eq 0 ]; then
      pass "the auth slice's independent checkout contains no billing or reports file"
    else
      fail "the auth slice's independent checkout contains no billing or reports file" "on disk: $auth_on_disk"
    fi
  else
    fail "the auth slice's independent checkout contains no billing or reports file" "$NO_BLOCK_REASON (or the run failed: rc=$RECIPE_RC stderr=$RECIPE_ERR)"
  fi

  if [ -d "$EXPECTED_BILLING_DIR" ]; then
    billing_on_disk_after="$(on_disk_files "$EXPECTED_BILLING_DIR")"
    leak=0
    for f in "${AUTH_FILES[@]}"; do
      contains_line "$billing_on_disk_after" "$f" && leak=1
    done
    if [ "$leak" -eq 0 ]; then
      pass "crawling the auth slice afterward does not retroactively add auth files to the billing checkout"
    else
      fail "crawling the auth slice afterward does not retroactively add auth files to the billing checkout" "on disk: $billing_on_disk_after"
    fi
  else
    fail "crawling the auth slice afterward does not retroactively add auth files to the billing checkout" "$NO_BLOCK_REASON"
  fi
else
  fail "the auth slice's independent checkout contains no billing or reports file" "$NO_BLOCK_REASON"
  fail "crawling the auth slice afterward does not retroactively add auth files to the billing checkout" "$NO_BLOCK_REASON"
fi

# ===========================================================================
# Section E — executed: no whole-tree clone or checkout of the parent ever
# appears in the cache. Checked as observable disk state, not as "did code
# path X run": every cached git-managed directory this run produced must
# itself be a genuine sparse checkout, and none may hold files from more
# than one slice's exclusive set (the direct fingerprint of a full clone).
# ===========================================================================
section "executed — no whole-tree clone or checkout of the parent occurs"

if [ -n "$RECIPE_BLOCK" ]; then
  run_recipe "$REPORTS_ID" "$PARENT_BARE" "HEAD" "${REPORTS_PATTERNS[@]}"

  if [ -d "$SLICE_CACHE_ROOT/git-managed" ]; then
    non_sparse_found=0
    cross_slice_found=0
    while IFS= read -r -d '' dir; do
      if ! git -C "$dir" sparse-checkout list >/dev/null 2>&1; then
        non_sparse_found=1
        fail "every cached git-managed directory is a genuine sparse checkout (a full clone fails \`git sparse-checkout list\`)" \
          "non-sparse directory: $dir"
      fi
      dir_files="$(on_disk_files "$dir")"
      slice_tags=""
      for tagged in "${TAGGED_SLICE_FILES[@]}"; do
        f="${tagged%%|*}"
        tag="${tagged##*|}"
        if contains_line "$dir_files" "$f"; then
          slice_tags="$slice_tags $tag"
        fi
      done
      slices_present="$(printf '%s\n' $slice_tags | sort -u | grep -c .)"
      if [ "$slices_present" -gt 1 ]; then
        cross_slice_found=1
        fail "no single cached directory holds more than one slice's files (the fingerprint of a whole-tree checkout)" \
          "directory $dir holds files from $slices_present slices: $dir_files"
      fi
    done < <(find "$SLICE_CACHE_ROOT/git-managed" -mindepth 1 -maxdepth 1 -type d -print0)

    [ "$non_sparse_found" -eq 0 ] && pass "every cached git-managed directory is a genuine sparse checkout (a full clone fails \`git sparse-checkout list\`)"
    [ "$cross_slice_found" -eq 0 ] && pass "no single cached directory holds more than one slice's files (the fingerprint of a whole-tree checkout)"
  else
    fail "every cached git-managed directory is a genuine sparse checkout (a full clone fails \`git sparse-checkout list\`)" "$NO_BLOCK_REASON"
    fail "no single cached directory holds more than one slice's files (the fingerprint of a whole-tree checkout)" "$NO_BLOCK_REASON"
  fi
else
  fail "every cached git-managed directory is a genuine sparse checkout (a full clone fails \`git sparse-checkout list\`)" "$NO_BLOCK_REASON"
  fail "no single cached directory holds more than one slice's files (the fingerprint of a whole-tree checkout)" "$NO_BLOCK_REASON"
fi

# ===========================================================================
# Section F — prose: cache-and-clone.md documents a slice source activating
# the same sparse-checkout recipe files_of_interest already uses, fed from
# slice_paths instead.
# ===========================================================================
section "cache-and-clone.md — slice_paths activates the existing sparse-checkout recipe"

CACHE_TEXT="$(norm_file "$CACHE_AND_CLONE")"

if near_all "$CACHE_TEXT" 'slice_paths' 250 '(files_of_interest|sparse.checkout|sparse.clone)'; then
  pass "cache-and-clone.md documents slice_paths driving the same sparse-checkout recipe files_of_interest uses"
else
  fail "cache-and-clone.md documents slice_paths driving the same sparse-checkout recipe files_of_interest uses" \
    "expected 'slice_paths' documented near 'files_of_interest' or a sparse-checkout/sparse-clone phrase"
fi

if near_all "$CACHE_TEXT" 'cache-git\.sh' 200 'sparse.clone'; then
  pass "cache-and-clone.md still documents cache-git.sh's sparse-clone verb as the mechanism (preserved, not replaced)"
else
  fail "cache-and-clone.md still documents cache-git.sh's sparse-clone verb as the mechanism (preserved, not replaced)" \
    "expected 'cache-git.sh' documented near 'sparse-clone'"
fi

# Preservation: the existing files_of_interest-scoped invocation line must
# still be present verbatim — this chunk activates the recipe from a second
# input, it does not own or replace it.
assert_contains "cache-and-clone.md preserves the existing files_of_interest-scoped cache-git.sh invocation verbatim" \
  "$(cat "$CACHE_AND_CLONE")" \
  '"$CLAUDE_PLUGIN_ROOT/bin/cache-git.sh" sparse-clone "<source_id>" "<url>" "<ref>" -- <files_of_interest entries...>'

# ===========================================================================
# Section G — prose: clustering is documented as an allowed (not required)
# grouping of slices sharing a parent, gated on the model's own context
# judgment — and the sibling-isolation invariant holds regardless.
# ===========================================================================
section "cache-and-clone.md — clustering is documented as optional, isolation as unconditional"

if near_all "$CACHE_TEXT" '(cluster|clustering)' 250 '(parent|slice)'; then
  pass "cache-and-clone.md documents that slices sharing a parent may be clustered into one sparse tree"
else
  fail "cache-and-clone.md documents that slices sharing a parent may be clustered into one sparse tree" \
    "expected 'cluster'/'clustering' documented near 'parent' or 'slice'"
fi

if near_all "$CACHE_TEXT" 'slice' 250 '(sibling)' '(unless|only when|clustered)'; then
  pass "cache-and-clone.md documents that a slice never sees a sibling's files unless clustered"
else
  fail "cache-and-clone.md documents that a slice never sees a sibling's files unless clustered" \
    "expected 'sibling' and an 'unless/only when ... clustered' phrase documented near 'slice'"
fi

# ===========================================================================
# Section H — prose: one proposal for every promoted slice, grouped by slice
# id in the post-run summary, with each crawled slice's SHA recorded.
# ===========================================================================
section "tool-and-output-mechanics.md — one proposal per run, grouped and SHA-recorded by slice"

TOOL_TEXT="$(norm_file "$TOOL_AND_OUTPUT")"

if near_all "$TOOL_TEXT" 'slice' 250 'CTX_PROPOSED' '(one|single)'; then
  pass "tool-and-output-mechanics.md documents every promoted slice's findings landing in one \$CTX_PROPOSED"
else
  fail "tool-and-output-mechanics.md documents every promoted slice's findings landing in one \$CTX_PROPOSED" \
    "expected 'slice' documented near 'CTX_PROPOSED' and a one/single phrase"
fi

if near_all "$TOOL_TEXT" 'slice' 250 'manifest\.json' 'REVIEW\.md'; then
  pass "tool-and-output-mechanics.md documents one manifest.json and one REVIEW.md across every promoted slice"
else
  fail "tool-and-output-mechanics.md documents one manifest.json and one REVIEW.md across every promoted slice" \
    "expected 'slice' documented near both 'manifest.json' and 'REVIEW.md'"
fi

if near_all "$TOOL_TEXT" '(Coverage report|coverage)' 250 '(slice_id|slice id|slice)' '(group|grouped|by slice)'; then
  pass "the post-run summary documents grouping findings by slice id"
else
  fail "the post-run summary documents grouping findings by slice id" \
    "expected Coverage-report language documented near a slice-grouping phrase"
fi

if near_all "$TOOL_TEXT" '\.discover-cache\.json' 250 'slice' '(sha|SHA)'; then
  pass "tool-and-output-mechanics.md documents recording each crawled slice's SHA in its .discover-cache.json key"
else
  fail "tool-and-output-mechanics.md documents recording each crawled slice's SHA in its .discover-cache.json key" \
    "expected '.discover-cache.json' documented near 'slice' and 'SHA'"
fi

# ===========================================================================
# Section I — prose + preservation: per-slice CLAUDE.md is documented in
# cache-and-clone.md as opt-in, engine-unread context, ~30-100 lines — and
# 07-monorepo-adapter.md §7.8's own paragraph making the same promise stays
# untouched.
# ===========================================================================
section "per-slice CLAUDE.md — documented in cache-and-clone.md as opt-in; §7.8 preserved"

if near_all "$CACHE_TEXT" 'CLAUDE\.md' 250 '(opt.in)' '(never reads|does not read|doesn.t read)'; then
  pass "cache-and-clone.md documents per-slice CLAUDE.md as opt-in context the engine itself never reads"
else
  fail "cache-and-clone.md documents per-slice CLAUDE.md as opt-in context the engine itself never reads" \
    "expected 'CLAUDE.md' documented near an opt-in phrase and a never-reads phrase"
fi

if near_all "$CACHE_TEXT" 'CLAUDE\.md' 250 '(30.{0,3}100|thirty.{0,3}(one hundred|100))'; then
  pass "cache-and-clone.md documents the 30-100 line guidance for a per-slice CLAUDE.md"
else
  fail "cache-and-clone.md documents the 30-100 line guidance for a per-slice CLAUDE.md" \
    "expected 'CLAUDE.md' documented near a 30-100 line range phrase"
fi

section_78="$(extract_heading_section '7.8' "$MONOREPO_DOC")"
assert_contains "§7.8 still states authoring a per-slice CLAUDE.md is opt-in and the engine reads none itself" \
  "$section_78" \
  "**Authoring a per-slice CLAUDE.md is opt-in.** The engine doesn't read CLAUDE.md directly — Claude Code does."

assert_contains "§7.8 still states a reasonable per-slice CLAUDE.md runs 30-100 lines" \
  "$section_78" \
  "A reasonable per-slice CLAUDE.md is 30–100 lines."

# ----- summary -------------------------------------------------------------

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
