#!/usr/bin/env bash
# Black-box oracle for treating a declared monorepo slice as its own in-scope
# freshness unit: DISCOVER pre-flight reads research/monorepo-config.json (when
# present) and stages one sources[] entry per slice into the proposal's
# source-paths.json, each slice becomes independent of its siblings for the
# cache/no-op gate, the parent monorepo is excluded from crawling while it has
# applied slices, STATUS renders slices grouped under their parent, and
# DISCOVER's Coverage report groups findings by slice id.
#
# THE INVARIANTS.
#   - A three-slice monorepo-config.json, matched by url against a registered
#     git-managed source, derives exactly three sources[] entries: one per
#     slice, each carrying id = "<parent id>-<slice id>", slice_of = the
#     parent's url, slice_id = the slice's id, slice_paths = the slice's own
#     path list verbatim, and the parent's kind/branch/url inherited.
#   - A monorepo-config.json entry whose url matches no registered source's
#     url halts the derivation with a non-zero exit and a diagnostic naming
#     the offending url — no partial output.
#   - No monorepo-config.json at all (or one with no monorepos) derives zero
#     entries and changes nothing else — the pre-adapter behavior, unchanged.
#   - While at least one derived/applied slice entry names a parent, that
#     parent is excluded from whatever mechanism actually re-reads or crawls
#     a git-managed source's tree in DISCOVER and in REFRESH, and a one-line
#     summary names the parent and its slice count.
#   - STATUS renders each slice under its parent with its own freshness line;
#     a contextualizer with no slices renders exactly as it does today.
#   - DISCOVER's Coverage report groups findings by slice id where slices
#     exist.
#   - discover/SKILL.md and refresh/SKILL.md — the two router-ceiling files —
#     stay byte-identical to their pre-existing content; nothing here should
#     ever need to touch them.
#
# THIS IS A PROSE-HEAVY ORACLE, PLUS ONE EXECUTED HALF. The staging,
# in-scope-filtering, and STATUS-rendering behavior above is a model reading
# Markdown references and executing prose-described bash at runtime, not a
# standalone program a fixture can invoke — so most of this file greps the
# reference docs for the documented contract, wrap-normalized (collapse
# newlines and whitespace runs before matching; these are hand-wrapped
# Markdown files, and a naive line-oriented grep silently misses a phrase
# that happens to cross a line break). The one piece that IS executable is
# the config-to-entries derivation: wherever a reference carries it as a
# fenced shell block delimited by the sentinel pair
#
#   <!-- doctrine:slice-source-entries:start -->
#   ```bash
#   ...
#   ```
#   <!-- doctrine:slice-source-entries:end -->
#
# (exactly one such pair, in discover/references/cache-and-clone.md — the
# convention is invented here, following the existing
# doctrine:clone-consent-guard / doctrine:discover-cache-hit-check precedent
# in the same file), this runner extracts the block and runs it as
#
#   bash <extracted-block> <monorepo-config.json path> <source-paths.json path>
#
# — two positional file paths, received as the block's own "$@", no
# angle-bracket placeholder substitution (the block reads real files, it
# does not have per-source tokens to interpolate). Contract:
#
#   - stdout is a JSON array of ONLY the derived slice entries (not the
#     merged source-paths.json — merging into $CTX_PROPOSED/research/
#     source-paths.json is documented prose, reusing the existing
#     copy-on-write recipe; it is not part of this block's job). Per entry:
#     id ("<parent id>-<slice id>"), slice_of (parent url), slice_id,
#     slice_paths (the slice's path array, copied verbatim), kind (the
#     parent's), branch (the parent's, or absent/null when the parent has
#     none — never the literal string "HEAD"; an empty-string branch is
#     schema-equivalent to absent per source-paths.schema.json but this
#     oracle only fixtures the absent case), url (the parent's), and a
#     non-empty status plus lifecycle.state (exact inherited values left to
#     the plan — see this oracle's own report for that open question).
#   - exit 0, stdout "[]", when: the config path does not exist, or the
#     config parses but declares no monorepos.
#   - exit non-zero, stdout empty, one stderr line naming the offending url,
#     when ANY monorepos[].url matches no registered sources[].url — a
#     whole-run halt, not a per-monorepo skip: one dangling url stops the
#     whole invocation before any entry is printed, even if other monorepos
#     in the same file would otherwise resolve cleanly.
#
# Right now no such marker, and no such block, exists anywhere in
# cache-and-clone.md — every extraction below comes back empty and every
# assertion that depends on it fails for that reason: the behavior is
# absent, not the harness broken. That absence is itself the expected red
# this oracle exists to turn green later.
#
# PRESERVATION CHECKS RUN UNGATED. "Absent monorepo-config.json changes
# nothing" and "discover/SKILL.md and refresh/SKILL.md are unchanged" are
# already true today, before any edit — those assertions run directly
# against the current files and are expected to PASS right now. They keep
# passing after slices land only if that implementation leaves the
# unrelated wording, and both router files, alone.
#
# -e is intentionally omitted (see set -uo pipefail below): every assertion
# runs and reports, not abort at the first failing one. Every tmpdir this
# file creates is removed on exit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_ROOT/.." && pwd)"

CACHE_AND_CLONE="$PLUGIN_ROOT/skills/discover/references/cache-and-clone.md"
PROPOSAL_POST_RUN="$PLUGIN_ROOT/skills/discover/references/proposal-and-post-run.md"
DRIFT_PHASES="$PLUGIN_ROOT/skills/refresh/references/drift-detection-and-phases.md"
STATUS_SKILL="$PLUGIN_ROOT/skills/status/SKILL.md"
MONOREPO_DOC="$PLUGIN_ROOT/docs/07-monorepo-adapter.md"
DISCOVER_SKILL="$PLUGIN_ROOT/skills/discover/SKILL.md"
REFRESH_SKILL="$PLUGIN_ROOT/skills/refresh/SKILL.md"
BASELINE_DISCOVER_SKILL="$SCRIPT_DIR/fixtures/baseline/discover-SKILL.md"
BASELINE_REFRESH_SKILL="$SCRIPT_DIR/fixtures/baseline/refresh-SKILL.md"

for f in "$CACHE_AND_CLONE" "$PROPOSAL_POST_RUN" "$DRIFT_PHASES" "$STATUS_SKILL" "$MONOREPO_DOC" \
         "$DISCOVER_SKILL" "$REFRESH_SKILL" "$BASELINE_DISCOVER_SKILL" "$BASELINE_REFRESH_SKILL"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: expected surface is missing entirely: $f" >&2
    exit 69
  fi
done

WORK="$(mktemp -d -t skill-engine-slice-units.XXXXXX)"
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

# norm — collapse every run of whitespace, newlines included, to one space,
# then trim the ends. Every multi-word phrase assertion below runs against
# normalized text so a hand-wrapped line break can never hide a phrase from
# a naive line-oriented grep.
norm() { tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }
norm_file() { norm < "$1"; }

# extract_heading_section <heading-text-prefix> <file> — the "##"/"###"
# heading whose text (after the leading hashes) starts with the given
# prefix, through (not including) the next such heading, or EOF.
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
# within <window> characters of some occurrence of <anchor> in <text>. 200,
# not more: some grep implementations reject an interval bound above 255,
# and the window applies on both sides of the anchor.
near() {
  local text="$1" anchor="$2" needle="$3" window="$4"
  # `grep -c ... > /dev/null`, not `grep -q`: -q exits at its first match,
  # SIGPIPE-ing the upstream -o while it is still writing remaining windows.
  # Under `set -o pipefail` the pipeline then reports 141 and a needle that
  # WAS found reads as a miss. -c drains to EOF so the verdict never depends
  # on the anchor's frequency.
  printf '%s' "$text" \
    | grep -oiE ".{0,${window}}${anchor}.{0,${window}}" \
    | grep -ciE -- "$needle" > /dev/null
}

# near_all <text> <anchor-ere> <window> <needle-ere>... — true when EVERY
# given needle occurs somewhere within <window> characters of some
# occurrence of <anchor> (not necessarily the same occurrence).
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
# Section A — the config-to-entries derivation block: extraction contract.
# ===========================================================================
section "derivation block — extraction from cache-and-clone.md"

MARKER_START='<!-- doctrine:slice-source-entries:start -->'
MARKER_END='<!-- doctrine:slice-source-entries:end -->'

EXTRACTED_DERIVATION=""
extract_derivation_block() {
  local label="$1" file="$2"
  EXTRACTED_DERIVATION=""
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
  outfile="$(mktemp "$WORK/derivation-block-XXXXXX")"
  printf '%s\n' "$body" > "$outfile"
  syntax_err="$(mktemp "$WORK/derivation-syntax-err-XXXXXX")"
  if ! bash -n "$outfile" 2>"$syntax_err"; then
    fail "$label" "extracted block from $file is not valid shell:" "$(cat "$syntax_err")"
    return 1
  fi

  pass "$label"
  EXTRACTED_DERIVATION="$outfile"
  return 0
}

DERIVATION_BLOCK=""
if extract_derivation_block "slice-source-entries block: present, well-formed, exactly one pair" "$CACHE_AND_CLONE"; then
  DERIVATION_BLOCK="$EXTRACTED_DERIVATION"
fi

NO_BLOCK_REASON="cannot evaluate — no slice-source-entries block found (see the extraction result above)"

# run_derivation <config-file> <sources-file> — runs the extracted block as
# `bash <block> <config> <sources>`, mirroring the guard block's own "$@"
# convention. Sets DERIVE_RC / DERIVE_OUT / DERIVE_ERR.
DERIVE_RC=0
DERIVE_OUT=""
DERIVE_ERR=""
run_derivation() {
  local outfile errfile
  outfile="$(mktemp "$WORK/derive-run-out-XXXXXX")"
  errfile="$(mktemp "$WORK/derive-run-err-XXXXXX")"
  bash "$DERIVATION_BLOCK" "$@" >"$outfile" 2>"$errfile"
  DERIVE_RC=$?
  DERIVE_OUT="$(cat "$outfile")"
  DERIVE_ERR="$(cat "$errfile")"
}

# ===========================================================================
# Section B — fixtures: a three-slice config over a two-source registry.
# ===========================================================================
section "fixtures — three-slice config, two-source registry"

PARENT_URL="https://example.com/acme/big-monorepo"
PARENT_ID="acme-monorepo"
PARENT_BRANCH="release/v2"
DISTRACTOR_URL="https://example.com/acme/unrelated-repo"
DISTRACTOR_ID="acme-unrelated"

main_config="$WORK/monorepo-config.json"
cat > "$main_config" <<EOF
{
  "version": "1.0",
  "monorepos": [
    {
      "url": "$PARENT_URL",
      "type": "internal-repo",
      "slices": [
        {"id": "billing", "paths": ["packages/billing/**", "shared/billing-types/**"]},
        {"id": "auth",    "paths": ["packages/auth/**", "services/auth-api/**"]},
        {"id": "reports", "paths": ["apps/reports-dashboard/**"]}
      ]
    }
  ]
}
EOF

main_sources="$WORK/source-paths.json"
jq -n --arg purl "$PARENT_URL" --arg pid "$PARENT_ID" --arg pbranch "$PARENT_BRANCH" \
      --arg durl "$DISTRACTOR_URL" --arg did "$DISTRACTOR_ID" '
{
  schema_version: 1,
  sources: [
    {
      id: $pid, kind: "git-managed", url: $purl, branch: $pbranch,
      status: "confirmed", archived: false,
      lifecycle: {state: "reachable", last_checked: "2026-09-06", last_checked_sha: "abc1234", proposed_url: null},
      discovered_via: null
    },
    {
      id: $did, kind: "git-managed", url: $durl,
      status: "confirmed", archived: false,
      lifecycle: {state: "reachable", last_checked: "2026-09-06", last_checked_sha: "def5678", proposed_url: null},
      discovered_via: null
    }
  ]
}' > "$main_sources"

jq empty "$main_config" 2>/dev/null && jq empty "$main_sources" 2>/dev/null \
  && pass "fixtures parse as well-formed JSON" \
  || fail "fixtures parse as well-formed JSON"

# ===========================================================================
# Section C — executed: the three-slice / two-source derivation.
# ===========================================================================
section "derivation block — three slices over a matched parent, distractor untouched"

if [ -n "$DERIVATION_BLOCK" ]; then
  run_derivation "$main_config" "$main_sources"

  if [ "$DERIVE_RC" -eq 0 ]; then
    pass "derivation exits 0 against a config whose monorepo url matches a registered source"
  else
    fail "derivation exits 0 against a config whose monorepo url matches a registered source" \
      "rc=$DERIVE_RC stderr: $DERIVE_ERR"
  fi

  if printf '%s' "$DERIVE_OUT" | jq -e 'type == "array"' >/dev/null 2>&1; then
    pass "derivation stdout is a JSON array"
  else
    fail "derivation stdout is a JSON array" "stdout: $DERIVE_OUT"
  fi

  if printf '%s' "$DERIVE_OUT" | jq -e 'length == 3' >/dev/null 2>&1; then
    pass "derivation emits exactly three entries (one per declared slice), not four (the distractor source contributes none)"
  else
    fail "derivation emits exactly three entries (one per declared slice), not four (the distractor source contributes none)" \
      "stdout: $DERIVE_OUT"
  fi

  if printf '%s' "$DERIVE_OUT" | jq -e --arg did "$DISTRACTOR_ID" \
      '[.[] | select(.id | startswith($did))] | length == 0' >/dev/null 2>&1; then
    pass "no derived entry is prefixed by the distractor source's id"
  else
    fail "no derived entry is prefixed by the distractor source's id" "stdout: $DERIVE_OUT"
  fi

  expected_ids='["acme-monorepo-billing","acme-monorepo-auth","acme-monorepo-reports"]'
  if printf '%s' "$DERIVE_OUT" | jq -e --argjson want "$expected_ids" \
      '([.[].id] | sort) == ($want | sort)' >/dev/null 2>&1; then
    pass "derived ids follow <parent id>-<slice id> for all three slices"
  else
    fail "derived ids follow <parent id>-<slice id> for all three slices" "stdout: $DERIVE_OUT"
  fi

  # Per-entry field checks against the billing slice specifically: slice_of,
  # slice_id, slice_paths (verbatim array, not joined/reformatted), and the
  # parent's kind/branch inherited.
  billing_ok=1
  billing_check="$(printf '%s' "$DERIVE_OUT" | jq -e --arg purl "$PARENT_URL" --arg pbranch "$PARENT_BRANCH" '
    map(select(.id == "acme-monorepo-billing"))[0] as $e
    | ($e != null)
    and ($e.slice_of == $purl)
    and ($e.slice_id == "billing")
    and ($e.slice_paths == ["packages/billing/**", "shared/billing-types/**"])
    and ($e.kind == "git-managed")
    and ($e.branch == $pbranch)
  ' 2>&1)" || billing_ok=0
  if [ "$billing_ok" -eq 1 ] && [ "$billing_check" = "true" ]; then
    pass "the billing slice entry carries slice_of/slice_id/slice_paths verbatim plus the parent's inherited kind and branch"
  else
    fail "the billing slice entry carries slice_of/slice_id/slice_paths verbatim plus the parent's inherited kind and branch" \
      "jq result: $billing_check -- stdout: $DERIVE_OUT"
  fi

  # A git-managed sources[] entry needs *some* url for Check 2 to even
  # consider it well-formed; the natural inherited value is the parent's own
  # url (07-monorepo-adapter.md §7.7's illustrative resource reuses the
  # parent url for a slice resource the same way). The spec does not state
  # this outright, so this is this oracle's own interpretive choice, flagged
  # in the final report as a plan-gate question rather than treated as
  # settled.
  url_ok="$(printf '%s' "$DERIVE_OUT" | jq -e --arg purl "$PARENT_URL" '
    all(.[]; .url == $purl)
  ' 2>&1)"
  if [ "$url_ok" = "true" ]; then
    pass "every derived entry inherits the parent's url"
  else
    fail "every derived entry inherits the parent's url" "jq result: $url_ok -- stdout: $DERIVE_OUT"
  fi

  # status / lifecycle.state must be PRESENT and non-empty (Check 2 requires
  # both on every entry). The exact inherited value (e.g. copy the parent's
  # own status/lifecycle.state verbatim, vs. always "confirmed"/"reachable"
  # for a freshly-derived slice) is a plan-gate question this oracle leaves
  # open rather than guesses at -- it only pins presence and non-emptiness.
  status_ok="$(printf '%s' "$DERIVE_OUT" | jq -e '
    all(.[]; (.status | type == "string" and length > 0)
        and (.lifecycle.state | type == "string" and length > 0))
  ' 2>&1)"
  if [ "$status_ok" = "true" ]; then
    pass "every derived entry carries a non-empty status and lifecycle.state (exact inherited value left open)"
  else
    fail "every derived entry carries a non-empty status and lifecycle.state (exact inherited value left open)" \
      "jq result: $status_ok -- stdout: $DERIVE_OUT"
  fi

  # Distinct ids -> distinct future .discover-cache.json enrichments.<id>
  # keys: since each derived entry's id becomes the enrichments.<source_id>
  # key (09-discover-config.md's existing keying convention), pairwise-
  # distinct ids is exactly what guarantees no two slices ever collapse
  # onto the same cache entry, independent of their siblings.
  enrichments_ok="$(printf '%s' "$DERIVE_OUT" | jq -e '
    (map(.id) | unique | length) == length
  ' 2>&1)"
  if [ "$enrichments_ok" = "true" ]; then
    pass "the three derived ids are pairwise distinct, so each would occupy its own .discover-cache.json enrichments key independent of its siblings"
  else
    fail "the three derived ids are pairwise distinct, so each would occupy its own .discover-cache.json enrichments key independent of its siblings" \
      "jq result: $enrichments_ok -- stdout: $DERIVE_OUT"
  fi
else
  for label in \
    "derivation exits 0 against a config whose monorepo url matches a registered source" \
    "derivation stdout is a JSON array" \
    "derivation emits exactly three entries (one per declared slice), not four (the distractor source contributes none)" \
    "no derived entry is prefixed by the distractor source's id" \
    "derived ids follow <parent id>-<slice id> for all three slices" \
    "the billing slice entry carries slice_of/slice_id/slice_paths verbatim plus the parent's inherited kind and branch" \
    "every derived entry inherits the parent's url" \
    "every derived entry carries a non-empty status and lifecycle.state (exact inherited value left open)" \
    "the three derived ids are pairwise distinct, so each would occupy its own .discover-cache.json enrichments key independent of its siblings"; do
    fail "$label" "$NO_BLOCK_REASON"
  done
fi

# ===========================================================================
# Section D — executed: branch-absent inheritance (no literal "HEAD" string).
# ===========================================================================
section "derivation block — an absent parent branch is inherited as absent, never the literal string HEAD"

nobranch_url="https://example.com/acme/no-branch-monorepo"
nobranch_id="acme-nobranch"
nobranch_config="$WORK/monorepo-config-nobranch.json"
cat > "$nobranch_config" <<EOF
{
  "version": "1.0",
  "monorepos": [
    {
      "url": "$nobranch_url",
      "type": "internal-repo",
      "slices": [
        {"id": "onlyslice", "paths": ["packages/only/**"]}
      ]
    }
  ]
}
EOF

nobranch_sources="$WORK/source-paths-nobranch.json"
jq -n --arg url "$nobranch_url" --arg id "$nobranch_id" '
{
  schema_version: 1,
  sources: [
    {
      id: $id, kind: "git-managed", url: $url,
      status: "confirmed", archived: false,
      lifecycle: {state: "reachable", last_checked: "2026-09-06", last_checked_sha: "aaa1111", proposed_url: null},
      discovered_via: null
    }
  ]
}' > "$nobranch_sources"

if [ -n "$DERIVATION_BLOCK" ]; then
  run_derivation "$nobranch_config" "$nobranch_sources"
  nobranch_ok="$(printf '%s' "$DERIVE_OUT" | jq -e '
    (length == 1) and ((.[0].branch // null) == null) and (.[0].branch != "HEAD")
  ' 2>&1)"
  if [ "$DERIVE_RC" -eq 0 ] && [ "$nobranch_ok" = "true" ]; then
    pass "a parent with no branch field yields a slice entry whose branch is absent/null, not the literal string HEAD"
  else
    fail "a parent with no branch field yields a slice entry whose branch is absent/null, not the literal string HEAD" \
      "rc=$DERIVE_RC jq result: $nobranch_ok -- stdout: $DERIVE_OUT stderr: $DERIVE_ERR"
  fi
else
  fail "a parent with no branch field yields a slice entry whose branch is absent/null, not the literal string HEAD" "$NO_BLOCK_REASON"
fi

# ===========================================================================
# Section E — executed: dangling slice_of url halts with a named error.
# ===========================================================================
section "derivation block — a monorepo url matching no registered source halts, naming the url"

DANGLING_URL="https://example.com/NOT-REGISTERED-ANYWHERE"
dangling_config="$WORK/monorepo-config-dangling.json"
cat > "$dangling_config" <<EOF
{
  "version": "1.0",
  "monorepos": [
    {
      "url": "$DANGLING_URL",
      "type": "internal-repo",
      "slices": [
        {"id": "orphan", "paths": ["packages/orphan/**"]}
      ]
    }
  ]
}
EOF

if [ -n "$DERIVATION_BLOCK" ]; then
  run_derivation "$dangling_config" "$main_sources"
  if [ "$DERIVE_RC" -ne 0 ]; then
    pass "a monorepo url matching no registered source exits non-zero"
  else
    fail "a monorepo url matching no registered source exits non-zero" "rc=$DERIVE_RC stdout: $DERIVE_OUT"
  fi

  if printf '%s' "$DERIVE_ERR" | grep -qF -- "$DANGLING_URL"; then
    pass "the halt diagnostic names the offending dangling url"
  else
    fail "the halt diagnostic names the offending dangling url" "stderr: $DERIVE_ERR"
  fi

  if [ -z "${DERIVE_OUT//[$'\t\r\n ']/}" ]; then
    pass "stdout is empty on the halt path (no partial entries emitted before the failing monorepo)"
  else
    fail "stdout is empty on the halt path (no partial entries emitted before the failing monorepo)" "stdout: $DERIVE_OUT"
  fi
else
  fail "a monorepo url matching no registered source exits non-zero" "$NO_BLOCK_REASON"
  fail "the halt diagnostic names the offending dangling url" "$NO_BLOCK_REASON"
  fail "stdout is empty on the halt path (no partial entries emitted before the failing monorepo)" "$NO_BLOCK_REASON"
fi

# ===========================================================================
# Section E2 — executed: the derivation is idempotent across applies, and a
# monorepo carrying no url at all halts like a dangling one.
#
# Section C runs the derivation exactly once, against a registry holding
# only the parent. That is the FIRST run. Every run after the first reads a
# registry that also holds the slices a previous /skill-engine:apply
# promoted -- and every one of those slices carries the parent's own url,
# because the derivation stamps `url: $m.url` onto each entry it emits. A
# parent lookup written as a jq generator therefore binds once per matching
# entry rather than once, and the comprehension emits matches x slices.
# (PR #16 review, finding 1.)
# ===========================================================================
section "derivation block — a post-apply registry derives no duplicate and no phantom entry"

# The registry as it stands after one apply: the parent plus the two slices
# derived from this same config, each carrying the parent's url verbatim.
reapply_config="$WORK/monorepo-config-reapply.json"
cat > "$reapply_config" <<EOF
{
  "version": "1.0",
  "monorepos": [
    {
      "url": "$PARENT_URL",
      "type": "internal-repo",
      "slices": [
        {"id": "billing", "paths": ["packages/billing/**"]},
        {"id": "reports", "paths": ["apps/reports-dashboard/**"]}
      ]
    }
  ]
}
EOF

reapply_sources="$WORK/source-paths-postapply.json"
jq --arg purl "$PARENT_URL" --arg pid "$PARENT_ID" --arg pbranch "$PARENT_BRANCH" '
  .sources += [
    {
      id: ($pid + "-billing"), kind: "git-managed", url: $purl, branch: $pbranch,
      slice_of: $purl, slice_id: "billing", slice_paths: ["packages/billing/**"],
      status: "confirmed", archived: false,
      lifecycle: {state: "reachable", last_checked: "2026-09-08", last_checked_sha: "aaa1111", proposed_url: null}
    },
    {
      id: ($pid + "-reports"), kind: "git-managed", url: $purl, branch: $pbranch,
      slice_of: $purl, slice_id: "reports", slice_paths: ["apps/reports-dashboard/**"],
      status: "confirmed", archived: false,
      lifecycle: {state: "reachable", last_checked: "2026-09-08", last_checked_sha: "bbb2222", proposed_url: null}
    }
  ]
' "$main_sources" > "$reapply_sources"

if [ -n "$DERIVATION_BLOCK" ]; then
  run_derivation "$reapply_config" "$reapply_sources"

  if [ "$DERIVE_RC" -eq 0 ]; then
    # Every emitted id must be one the registry does not already carry, and
    # no id may repeat within the emission. A generator-bound parent fails
    # both at once: it re-emits acme-monorepo-billing / -reports AND invents
    # acme-monorepo-billing-billing and three more like it.
    reapply_new="$(printf '%s' "$DERIVE_OUT" | jq -e --slurpfile reg "$reapply_sources" '
      ([$reg[0].sources[].id]) as $live
      | map(.id) as $emitted
      | ($emitted | map(select(. as $i | $live | index($i)))) as $dupes
      | ($emitted | group_by(.) | map(select(length > 1) | .[0])) as $repeats
      | {dupes: $dupes, repeats: $repeats}
    ' 2>&1)"
    if printf '%s' "$reapply_new" | jq -e '.dupes == [] and .repeats == []' >/dev/null 2>&1; then
      pass "a second run over an applied registry emits no id the registry already carries and no repeat"
    else
      fail "a second run over an applied registry emits no id the registry already carries and no repeat" \
        "collisions: $reapply_new" "stdout: $DERIVE_OUT"
    fi

    # The phantom shape is what a generator-bound parent produces and a
    # lookup cannot: an id built by concatenating a slice id onto an id
    # that already ends in one.
    if printf '%s' "$DERIVE_OUT" | jq -e '
      map(select(.id | test("-(billing|reports)-(billing|reports)$"))) | length == 0
    ' >/dev/null 2>&1; then
      pass "no derived id concatenates a slice id onto an already-sliced id (no <parent>-<slice>-<slice> phantom)"
    else
      fail "no derived id concatenates a slice id onto an already-sliced id (no <parent>-<slice>-<slice> phantom)" \
        "stdout: $DERIVE_OUT"
    fi

    # A third run compounds it: the phantoms from run 2 are themselves
    # url-matching sources by then. Fan-out must not grow with each apply.
    reapply_sources3="$WORK/source-paths-postapply3.json"
    jq --slurpfile derived <(printf '%s' "$DERIVE_OUT") '.sources += $derived[0]' \
      "$reapply_sources" > "$reapply_sources3" 2>/dev/null
    run_derivation "$reapply_config" "$reapply_sources3"
    if [ "$DERIVE_RC" -eq 0 ] && printf '%s' "$DERIVE_OUT" | jq -e 'length <= 2' >/dev/null 2>&1; then
      pass "a third run emits at most one entry per declared slice (fan-out does not grow with each apply)"
    else
      fail "a third run emits at most one entry per declared slice (fan-out does not grow with each apply)" \
        "rc=$DERIVE_RC count: $(printf '%s' "$DERIVE_OUT" | jq -r 'length' 2>&1) -- stdout: $DERIVE_OUT"
    fi
  else
    fail "a second run over an applied registry emits no id the registry already carries and no repeat" \
      "rc=$DERIVE_RC stderr: $DERIVE_ERR"
    fail "no derived id concatenates a slice id onto an already-sliced id (no <parent>-<slice>-<slice> phantom)" \
      "rc=$DERIVE_RC stderr: $DERIVE_ERR"
    fail "a third run emits at most one entry per declared slice (fan-out does not grow with each apply)" \
      "rc=$DERIVE_RC stderr: $DERIVE_ERR"
  fi
else
  fail "a second run over an applied registry emits no id the registry already carries and no repeat" "$NO_BLOCK_REASON"
  fail "no derived id concatenates a slice id onto an already-sliced id (no <parent>-<slice>-<slice> phantom)" "$NO_BLOCK_REASON"
  fail "a third run emits at most one entry per declared slice (fan-out does not grow with each apply)" "$NO_BLOCK_REASON"
fi

# ===========================================================================
section "derivation block — a monorepo entry carrying no url halts like a dangling one"

# §7.3's five rules require url UNIQUENESS, not presence, and the
# monorepo-config check passes a url-less entry -- so the derivation's own
# dangling-url guard is the only thing standing between a typo'd config and
# a silent zero-slice run. `map(select(...)) | (.[0].url // empty)` selects
# the entry and then reports nothing about it, which is the same as not
# selecting it.
for urlless_shape in absent null; do
  urlless_config="$WORK/monorepo-config-urlless-$urlless_shape.json"
  if [ "$urlless_shape" = "absent" ]; then
    url_field=""
  else
    url_field='"url": null,'
  fi
  cat > "$urlless_config" <<EOF
{
  "version": "1.0",
  "monorepos": [
    {
      $url_field
      "type": "internal-repo",
      "slices": [
        {"id": "billing", "paths": ["packages/billing/**"]},
        {"id": "reports", "paths": ["apps/reports-dashboard/**"]}
      ]
    }
  ]
}
EOF

  if [ -n "$DERIVATION_BLOCK" ]; then
    run_derivation "$urlless_config" "$main_sources"
    if [ "$DERIVE_RC" -ne 0 ] && [ -n "${DERIVE_ERR//[$'\t\r\n ']/}" ]; then
      pass "a monorepos[] entry whose url is $urlless_shape halts non-zero with a diagnostic"
    else
      fail "a monorepos[] entry whose url is $urlless_shape halts non-zero with a diagnostic" \
        "rc=$DERIVE_RC stdout: $DERIVE_OUT stderr: $DERIVE_ERR"
    fi
  else
    fail "a monorepos[] entry whose url is $urlless_shape halts non-zero with a diagnostic" "$NO_BLOCK_REASON"
  fi
done

# ===========================================================================
# Section F — executed: absent-config backward compat (the implicit
# criterion the Goal statement's "when present" clause implies).
# ===========================================================================
section "derivation block — absent config file, and a config with zero monorepos, both derive nothing"

absent_config_path="$WORK/does-not-exist-monorepo-config.json"
empty_monorepos_config="$WORK/monorepo-config-empty.json"
printf '{"version": "1.0", "monorepos": []}' > "$empty_monorepos_config"

if [ -n "$DERIVATION_BLOCK" ]; then
  run_derivation "$absent_config_path" "$main_sources"
  absent_ok="$(printf '%s' "$DERIVE_OUT" | jq -e '. == []' 2>&1)"
  if [ "$DERIVE_RC" -eq 0 ] && [ "$absent_ok" = "true" ]; then
    pass "an absent monorepo-config.json path derives an empty array and exits 0 (no error)"
  else
    fail "an absent monorepo-config.json path derives an empty array and exits 0 (no error)" \
      "rc=$DERIVE_RC jq result: $absent_ok -- stdout: $DERIVE_OUT stderr: $DERIVE_ERR"
  fi

  run_derivation "$empty_monorepos_config" "$main_sources"
  empty_ok="$(printf '%s' "$DERIVE_OUT" | jq -e '. == []' 2>&1)"
  if [ "$DERIVE_RC" -eq 0 ] && [ "$empty_ok" = "true" ]; then
    pass "a config declaring zero monorepos derives an empty array and exits 0"
  else
    fail "a config declaring zero monorepos derives an empty array and exits 0" \
      "rc=$DERIVE_RC jq result: $empty_ok -- stdout: $DERIVE_OUT stderr: $DERIVE_ERR"
  fi
else
  fail "an absent monorepo-config.json path derives an empty array and exits 0 (no error)" "$NO_BLOCK_REASON"
  fail "a config declaring zero monorepos derives an empty array and exits 0" "$NO_BLOCK_REASON"
fi

# ===========================================================================
# Section G — prose: DISCOVER pre-flight reads the config and stages into
# the proposal's source-paths.json, recorded modified in the manifest.
# ===========================================================================
section "cache-and-clone.md — pre-flight documents reading the config and staging into the proposal"

PREFLIGHT_TEXT="$(norm_file "$CACHE_AND_CLONE")"

if near_all "$PREFLIGHT_TEXT" 'monorepo-config\.json' 200 'research/' '(read|reads|present)'; then
  pass "pre-flight documents reading research/monorepo-config.json when present"
else
  fail "pre-flight documents reading research/monorepo-config.json when present" \
    "expected 'monorepo-config.json' documented near 'research/' and a read/present phrase"
fi

# Both documented locations, not just the canonical one. §7.3 declares two
# and verify.sh's monorepo-config check inspects both (its elif branch); a
# step 1.7 that names only research/ hands the engine-self-contextualizer a
# green verify, a validated config naming its slices, and a run that stages
# zero of them -- the absent-file branch is a documented no-op, so nothing
# is printed. (PR #16 review, finding 1c.)
if near_all "$PREFLIGHT_TEXT" 'monorepo-config\.json' 250 'CTX_ROOT/monorepo-config\.json' '(precedence|falling back|falls back)'; then
  pass "pre-flight names both documented config locations and their precedence"
else
  fail "pre-flight names both documented config locations and their precedence" \
    "expected \$CTX_ROOT/monorepo-config.json documented alongside the research/ location, with the precedence between them stated"
fi

if near_all "$PREFLIGHT_TEXT" 'monorepo-config\.json' 250 'CTX_PROPOSED' 'source-paths\.json'; then
  pass "pre-flight documents staging derived slice entries into \$CTX_PROPOSED/research/source-paths.json"
else
  fail "pre-flight documents staging derived slice entries into \$CTX_PROPOSED/research/source-paths.json" \
    "expected monorepo-config.json documented near CTX_PROPOSED and source-paths.json"
fi

if near_all "$PREFLIGHT_TEXT" 'source-paths\.json' 200 'manifest' 'modified' 'slice'; then
  pass "pre-flight documents the manifest recording source-paths.json as modified when slices are staged"
else
  fail "pre-flight documents the manifest recording source-paths.json as modified when slices are staged" \
    "expected source-paths.json documented near 'manifest', 'modified', AND 'slice' (the existing lifecycle-transition manifest sentence alone must not satisfy this)"
fi

# ===========================================================================
# Section H — prose: dangling url halts pre-flight (the must-reject input),
# named in the reference doc, not just the executed block.
# ===========================================================================
section "cache-and-clone.md — a config naming an unregistered url halts pre-flight, documented in prose"

NO_MATCH_RE='(no (registered|matching) source|matches no|unregistered|not registered|does.?n.t match any|matches none|does not match any)'
if near_all "$PREFLIGHT_TEXT" 'monorepo-config\.json' 250 '(halt|abort|error|fail)' "$NO_MATCH_RE"; then
  pass "pre-flight documents that a monorepo url matching no registered source halts with an error"
else
  fail "pre-flight documents that a monorepo url matching no registered source halts with an error" \
    "expected monorepo-config.json documented near a halt/error phrase and a no-match phrase"
fi

# ===========================================================================
# Section I — prose: each slice is its own freshness/cache unit, independent
# of its siblings (ties to the existing enrichments.<source_id> convention).
# ===========================================================================
section "cache-and-clone.md — each slice is an independent .discover-cache.json unit"

if near_all "$PREFLIGHT_TEXT" '\.discover-cache\.json' 250 'slice' '(own|independent|per.slice|each slice)'; then
  pass "the idempotency/cache-key area documents that each slice carries its own .discover-cache.json key"
else
  fail "the idempotency/cache-key area documents that each slice carries its own .discover-cache.json key" \
    "expected .discover-cache.json documented near 'slice' and an own/independent/per-slice phrase"
fi

# DISCOVER writes the key and REFRESH writes it too; both must spell the
# SAME key, and it must be the one Cache GC keeps. 09-discover-config.md's
# GC enumerates the active set of source_ids from source-paths.json and
# drops every enrichments.<source_id> entry not in it. A slice's slice_id
# ("billing") is never a source_id ("bigmono-billing"), so a key spelled
# enrichments.<slice_id> is deleted by the very next invocation's GC and
# every slice becomes a permanent cache miss -- silent, because a miss is
# indistinguishable from a first run. (PR #16 review, finding 4.)
mechanics_text="$(norm_file "$PLUGIN_ROOT/skills/refresh/references/tool-and-output-mechanics.md")"

for cache_key_file in "cache-and-clone.md:$PREFLIGHT_TEXT" "tool-and-output-mechanics.md:$mechanics_text"; do
  ck_label="${cache_key_file%%:*}"
  ck_text="${cache_key_file#*:}"
  if printf '%s' "$ck_text" | grep -qF 'enrichments.<slice_id>'; then
    fail "$ck_label keys a slice's .discover-cache.json entry on its source_id, not its slice_id" \
      "found 'enrichments.<slice_id>' — Cache GC (09-discover-config.md) drops every enrichments key that is not an active source_id, and a slice_id never is one"
  elif printf '%s' "$ck_text" | grep -qF 'enrichments.<source_id>'; then
    pass "$ck_label keys a slice's .discover-cache.json entry on its source_id, not its slice_id"
  else
    fail "$ck_label keys a slice's .discover-cache.json entry on its source_id, not its slice_id" \
      "neither 'enrichments.<source_id>' nor 'enrichments.<slice_id>' appears — the key must be stated"
  fi
done

# And REFRESH must say which id that is, so "source_id" cannot be read as
# the parent's.
if near_all "$mechanics_text" 'enrichments\.<source_id>' 250 'slice' '(own derived|derived id|its own id|slice.s own)'; then
  pass "tool-and-output-mechanics.md names the key as the slice's OWN derived id, not its parent's"
else
  fail "tool-and-output-mechanics.md names the key as the slice's OWN derived id, not its parent's" \
    "expected enrichments.<source_id> documented near 'slice' and a derived/own-id phrase"
fi

# ===========================================================================
# Section J — prose: the parent is excluded from whatever mechanism actually
# re-reads/crawls a git-managed source, in BOTH DISCOVER and REFRESH, plus a
# one-line summary naming the parent and its slice count.
#
# NOTE ON PHASE NUMBERING (a plan-gate question, flagged rather than
# silently resolved): this does NOT anchor on the literal tokens "Phase 2" /
# "Phase 3". In
# drift-detection-and-phases.md those numbers name Phase 2 (web-doc decay
# check) and Phase 3 (web-doc re-crawl apply) — never a git-managed source.
# The mechanism that actually re-reads/crawls a git-managed monorepo parent
# in that file is the unnumbered "Re-read scoping (git-managed)" section
# (and the Phase 1 promotion list feeding it); in cache-and-clone.md it is
# the in-scope filter / cache-miss-and-clone steps. This oracle asserts
# against those mechanisms instead.
# ===========================================================================
section "parent exclusion while slices exist, in both DISCOVER and REFRESH"

REFRESH_TEXT="$(norm_file "$DRIFT_PHASES")"

EXCLUDE_RE='(exclud|skip|omit|not.{0,20}(re-?read|crawl)|removed from|no whole.tree)'

if near_all "$PREFLIGHT_TEXT" '(parent|slice_of)' 250 "$EXCLUDE_RE" 'slice'; then
  pass "cache-and-clone.md documents excluding a slice's parent from crawling while it has applied slices"
else
  fail "cache-and-clone.md documents excluding a slice's parent from crawling while it has applied slices" \
    "expected exclusion language near 'parent'/'slice_of' and 'slice' in cache-and-clone.md"
fi

if near_all "$REFRESH_TEXT" '(parent|slice_of)' 250 "$EXCLUDE_RE" 'slice'; then
  pass "drift-detection-and-phases.md documents excluding a slice's parent from re-read/crawl while it has applied slices"
else
  fail "drift-detection-and-phases.md documents excluding a slice's parent from re-read/crawl while it has applied slices" \
    "expected exclusion language near 'parent'/'slice_of' and 'slice' in drift-detection-and-phases.md, in the git-managed re-read/promotion area (not the web-doc-only Phase 2/3 sections)"
fi

SUMMARY_LINE_RE='(parent|slice_of)'
COUNT_RE='(<N>|<[a-z]*count[a-z]*>|[0-9]+ slices?|slice count|count of slices)'
if near_all "$PREFLIGHT_TEXT" 'slice' 250 "$SUMMARY_LINE_RE" '(one.line|summary)' "$COUNT_RE"; then
  pass "cache-and-clone.md documents a one-line pre-flight summary naming the excluded parent and its slice count"
else
  fail "cache-and-clone.md documents a one-line pre-flight summary naming the excluded parent and its slice count" \
    "expected a one-line/summary phrase, a count placeholder, documented near 'slice' and 'parent'/'slice_of'"
fi

if near_all "$REFRESH_TEXT" 'slice' 250 "$SUMMARY_LINE_RE" '(one.line|summary)' "$COUNT_RE"; then
  pass "drift-detection-and-phases.md documents a one-line summary naming the excluded parent and its slice count"
else
  fail "drift-detection-and-phases.md documents a one-line summary naming the excluded parent and its slice count" \
    "expected a one-line/summary phrase, a count placeholder, documented near 'slice' and 'parent'/'slice_of'"
fi

# ===========================================================================
# Section K — prose: STATUS groups slices under their parent, with their own
# freshness, AND the no-slices rendering path is preserved verbatim.
# ===========================================================================
section "status/SKILL.md — slices grouped under parent; the no-slices path is untouched"

STATUS_TEXT="$(norm_file "$STATUS_SKILL")"

if near_all "$STATUS_TEXT" '(slice_id|slice id|slice)' 250 '(group|grouped|under (its |their )?parent|nested under)' '(fresh|freshness|stale|last.checked)'; then
  pass "STATUS documents rendering each slice grouped under its parent with its own freshness"
else
  fail "STATUS documents rendering each slice grouped under its parent with its own freshness" \
    "expected slice-grouping language near a grouping phrase and a freshness phrase"
fi

# Preservation: the existing per-source importance rendering (the closest
# thing today's STATUS has to a "no slices" render path) must still be
# emitted unchanged -- quoting the exact existing literal.
assert_contains "STATUS preserves the existing per-source importance table header verbatim" \
  "$(cat "$STATUS_SKILL")" "print('| id | importance |')"

assert_contains "STATUS preserves the existing 'probe_budget not set' line verbatim" \
  "$(cat "$STATUS_SKILL")" "probe_budget not set: all {k} in-scope sources are probed every refresh."

assert_contains "STATUS preserves the existing pending-proposal summary printf verbatim (the bash block nearest where a slice-rendering edit would tempt a change)" \
  "$(cat "$STATUS_SKILL")" 'Pending proposal: %s.proposed/  (%s added, %s modified, %s removed)'

# Regression backstop: adding slice rendering as a NEW bash fence in
# status/SKILL.md would silently break tests/status-decay/run.sh, which
# concatenates every ```bash fence (except the one in the probe-mentioning
# section) into one script. The bash-fence count frozen here (captured from
# the pre-slice file, commit 6b6f4aa on this branch) must not grow; new
# rendering belongs in prose or in a non-swept fence type instead.
BASELINE_BASH_FENCES=4
live_bash_fences="$(grep -c '^```bash' "$STATUS_SKILL")"
if [ "$live_bash_fences" -eq "$BASELINE_BASH_FENCES" ]; then
  pass "status/SKILL.md's \`\`\`bash fence count is unchanged ($BASELINE_BASH_FENCES) -- new slice rendering did not add one, which would silently break tests/status-decay/run.sh's fence sweep"
else
  fail "status/SKILL.md's \`\`\`bash fence count is unchanged ($BASELINE_BASH_FENCES) -- new slice rendering did not add one, which would silently break tests/status-decay/run.sh's fence sweep" \
    "baseline=$BASELINE_BASH_FENCES live=$live_bash_fences"
fi

# ===========================================================================
# Section L — prose: DISCOVER's Coverage report groups findings by slice id.
# ===========================================================================
section "proposal-and-post-run.md — Coverage report groups findings by slice id"

coverage_section="$(awk '
  /^1\. \*\*Coverage report\.\*\*/ { f = 1 }
  f && /^2\. \*\*Skip-reasoning\.\*\*/ { exit }
  f { print }
' "$PROPOSAL_POST_RUN")"
coverage_text="$(printf '%s' "$coverage_section" | norm)"

if [ -z "$coverage_section" ]; then
  fail "the Coverage report component (component 1 of the post-run summary) is locatable by its numbered heading" \
    "expected a '1. **Coverage report.**' ... '2. **Skip-reasoning.**' span in $PROPOSAL_POST_RUN"
else
  pass "the Coverage report component (component 1 of the post-run summary) is locatable by its numbered heading"
fi

if near_all "$coverage_text" '(slice_id|slice id|slice)' 250 '(group|grouped|by slice)'; then
  pass "the Coverage report documents grouping findings by slice id when slices exist"
else
  fail "the Coverage report documents grouping findings by slice id when slices exist" \
    "expected slice-grouping language within the Coverage report component"
fi

# ===========================================================================
# Section M — preservation: 07-monorepo-adapter.md §7.7's existing backward
# compat paragraph is untouched.
# ===========================================================================
section "07-monorepo-adapter.md — §7.7 backward-compat paragraph preserved verbatim"

section_77="$(extract_heading_section '7.7' "$MONOREPO_DOC")"
assert_contains "§7.7 still states a config with zero monorepos (or no file at all) emits no *-slice entries" \
  "$section_77" \
  "Backward compat: a contextualizer that has zero monorepos in \`monorepo-config.json\` (or no file at all) emits no \`*-slice\` entries; the state schema is unchanged from the pre-adapter shape."

# ===========================================================================
# Section N — byte-identity regression backstop: discover/SKILL.md and
# refresh/SKILL.md must never need touching by this work.
# ===========================================================================
section "router ceilings — discover/SKILL.md and refresh/SKILL.md byte-identical to baseline"

if cmp -s "$DISCOVER_SKILL" "$BASELINE_DISCOVER_SKILL"; then
  pass "discover/SKILL.md is byte-identical to its frozen baseline"
else
  fail "discover/SKILL.md is byte-identical to its frozen baseline" \
    "$(diff "$BASELINE_DISCOVER_SKILL" "$DISCOVER_SKILL" 2>&1 | head -20)"
fi

if cmp -s "$REFRESH_SKILL" "$BASELINE_REFRESH_SKILL"; then
  pass "refresh/SKILL.md is byte-identical to its frozen baseline"
else
  fail "refresh/SKILL.md is byte-identical to its frozen baseline" \
    "$(diff "$BASELINE_REFRESH_SKILL" "$REFRESH_SKILL" 2>&1 | head -20)"
fi

# ----- summary -------------------------------------------------------------

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
