#!/usr/bin/env bash
# Feature-scoped test runner for chunk 04-cited-paths-candidate-set: the
# script that maps each reference's SHA-pinned permalinks to the repository
# paths they cite, intersects those paths with a source's since_last_check
# changed-path list, and reports the re-emit candidate set plus the changed
# paths nobody cites.
#
# This is a FROZEN oracle written from spec.md alone, black-box throughout:
# CLI invocation, stdout JSON, and prose greps against the two refresh
# references and review/SKILL.md — never internal function names of
# cited_paths.py itself. It is written before cited_paths.py exists, so
# every FEATURE assertion in criteria 1, 2, 3 and 6 is expected to FAIL
# right now — there is no script to invoke, so every jq_check against its
# stdout sees empty input and every exit-code check sees Python's own
# "can't open file" rc=2. Criteria 4 and 5 (prose) are also expected to
# FAIL: the current checked-in text of drift-detection-and-phases.md,
# tool-and-output-mechanics.md, and review/SKILL.md carries none of the new
# instructions or report lines yet (confirmed by hand before writing this
# file — see the grep audit this header stands in for). Expected to PASS
# today: the fixture self-checks, the Coverage-report anchor precondition,
# the permalink-forges regression guard, and criterion 6's read-only check
# (vacuously true — a script that does not exist writes nothing either).
# None of those test the unbuilt feature; they test this file's own
# fixtures and already-shipped, unrelated behavior.
#
# Design decisions pinned where spec.md is silent on an operational detail
# (asserted, and re-explained, at each site below):
#   1. Base-scan JSON keys are paths relative to the <references-dir>
#      argument itself (POSIX "/"), e.g. "sub/nested.md" — see criterion 1.
#   2. --changed's top-level shape is
#        {"candidates": {<ref>: {<source_id>: [<changed path>...]}},
#         "uncited_changes": {"count": <int>, "paths": [...]}}
#      replacing (not augmenting) the plain per-file map criterion 1 defines
#      — one script, one shape per mode. A candidate's per-source_id array
#      lists the source(s) its citations resolve to, nested rather than a
#      single "source_id" field, because spec.md's own wording ("the
#      source(s) its permalinks are scoped to") is plural — see criterion 2.
#   3. A citation resolves to a source_id by matching against that source's
#      registered `url` in source-paths.json (the same registry
#      permalink_density.py's accepted_hosts() reads), not merely by host —
#      two sources could share a host. This fixture keeps every source on
#      its own host so the assertions don't depend on which of those two
#      granularities an implementation picks; the cross-source-must-reject
#      case only proves resolution is per-registered-source, not per-host.
#      See criterion 2.
#   4. "The matching paths listed" (criterion 2) means the CHANGED paths
#      that satisfied the match, not the reference's own cited path/
#      directory — that's the information a reviewer needs to know what
#      changed. See criterion 2's directory-prefix case, where the cited
#      directory "src" surfaces both changed files it covers.
#   5. Directory-prefix matching requires a '/' boundary: cited dir D
#      matches changed path P iff P == D or P.startswith(D + "/"). A raw
#      string prefix with no boundary (cited "src" vs. changed
#      "srcbackup/file.py") does not match. See criterion 3.
#   6. uncited_changes is one flat, corpus-wide sorted list of paths plus a
#      count — not grouped by source. See criterion 3.
#   7. "--changed points at a file without since_last_check" (criterion 6)
#      is read as: no source_id anywhere in the file carries the key at all
#      (the shape a DISCOVER-only inventory has, per spec.md's own "Out of
#      scope: DISCOVER" note) — not a partial file where only some sources
#      carry it. See criterion 6.
#   8. An Azure DevOps permalink's path lives in a query parameter with a
#      leading "/" (?path=/src/widget.py); the extracted path has that
#      slash stripped so it can ever intersect with since_last_check's
#      repo-relative paths. See criterion 1's forge fixture.
#
# Two portability traps this file routes around, worth knowing before
# editing it: (a) macOS's default /bin/bash is 3.2, which mis-parses a
# heredoc body as needing quote-balance when the heredoc sits inside a
# `$(...)` command substitution — an apostrophe in a `<<'PYEOF'` comment
# breaks the whole script's parse (see cp_err below for why stderr capture
# routes through a temp file instead of a `2>&1 1>/dev/null` swap, and keep
# heredoc bodies apostrophe-free); (b) BSD/macOS grep -E rejects a `{m,n}`
# interval bound above 255, so proximity windows below are capped at 250.
#
# -e is intentionally omitted: every assertion runs and reports, not abort
# at the first red one. Every tmpdir this file creates is removed on exit.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CITED_PATHS="$PLUGIN_ROOT/tests/cited_paths.py"
DRIFT_PHASES="$PLUGIN_ROOT/skills/refresh/references/drift-detection-and-phases.md"
TOOL_MECHANICS="$PLUGIN_ROOT/skills/refresh/references/tool-and-output-mechanics.md"
REVIEW_SKILL="$PLUGIN_ROOT/skills/review/SKILL.md"
PERMALINK_FORGES_ORACLE="$PLUGIN_ROOT/tests/permalink-forges/run.sh"

pass_count=0
fail_count=0

WORK="$(mktemp -d -t skill-engine-cited-paths.XXXXXX)"
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
# where the phrase happened to break across lines. spec.md's own test-paths
# note calls for exactly this against the refresh references and
# review/SKILL.md.
normalize() {
  printf '%s' "$1" | tr -s '[:space:]' ' '
}

# jq_check <json> <jq-boolean-program> [--arg name value ...] — true (rc 0)
# only when the input is valid JSON AND the boolean program evaluates true.
jq_check() {
  local json="$1" program="$2"
  shift 2
  printf '%s' "$json" | jq -e "$@" "$program" >/dev/null 2>&1
}

sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# dir_fingerprint <dir> — content fingerprint (path + sha256) of every
# regular file under <dir>. Used to prove a read-only claim: nothing on
# disk moved between two snapshots.
dir_fingerprint() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo "MISSING"
    return
  fi
  ( cd "$dir" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s ' "$f"
      sha256_of_file "$f"
    done ) | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}'
}

# repeat_hex <2-hex-char pair> <count> — a syntactically valid, obviously
# fake 40-char commit SHA (never a real object anywhere), built by literal
# repetition so its length is correct by construction rather than
# hand-counted in a string literal.
repeat_hex() {
  local pair="$1" count="$2" result="" i
  for ((i = 0; i < count; i++)); do
    result="${result}${pair}"
  done
  printf '%s' "$result"
}

# cp_out <args...> — cited_paths.py's stdout, stderr discarded. The
# function's own exit status is python3's exit status: callers capture it
# via `out="$(cp_out ...)"; rc=$?` immediately after, never through a global
# — a global written inside a function called as `$(fn ...)` is written in
# that command substitution's subshell and never reaches the parent shell.
cp_out() {
  python3 "$CITED_PATHS" "$@" 2>/dev/null
}

# cp_err <args...> — cited_paths.py's stderr only, stdout discarded, routed
# through a throwaway file rather than a `2>&1 1>/dev/null` swap (the
# correct order for that trick reads as a mistake to a static checker).
# Same rc-capture contract as cp_out above.
cp_err() {
  local errfile rc
  errfile="$(mktemp)"
  python3 "$CITED_PATHS" "$@" >/dev/null 2>"$errfile"
  rc=$?
  cat "$errfile"
  rm -f "$errfile"
  return "$rc"
}

# write_ref <file> <citation-url> [citation-url-2 ...] — one prose
# paragraph followed by each citation on its own line, the same shape the
# sibling permalink-forges suite's write_pinned_corpus uses. Density is not
# this script's concern, so there is no need to clear the 80% bar here.
write_ref() {
  local file="$1"
  shift
  local url
  mkdir -p "$(dirname "$file")"
  {
    printf 'A claim this reference documents, backed by the following citation(s).\n'
    for url in "$@"; do
      printf '%s\n' "$url"
    done
  } > "$file"
}

# ----- fixture data: hosts, a fake 40-hex SHA per role, citation URLs ----

CITE_SHA="$(repeat_hex "a1" 20)"
FROM_SHA_1="$(repeat_hex "b2" 20)"
TO_SHA_1="$(repeat_hex "c3" 20)"
FROM_SHA_2="$(repeat_hex "d4" 20)"
TO_SHA_2="$(repeat_hex "e5" 20)"

GHES_HOST="git.enterprise.example"
GHES_REPO_PATH="acme/widgets"
GHES_SRC="https://$GHES_HOST/$GHES_REPO_PATH"

GL_HOST="gitlab.example.com"
GL_REPO_PATH="acme/platform/widgets"
GL_SRC="https://$GL_HOST/$GL_REPO_PATH"

# github.com is deliberately left UNREGISTERED in this fixture's
# source-paths.json (only the two sources above are registered): a citation
# on it is still accepted by permalink_density.py's always-on github.com
# fallback (so it belongs in the base scan), but it resolves to no
# source_id and so can never be a --changed candidate.
GH_HOST="github.com"
GH_REPO_PATH="acme/gizmos"

CITE_GHES_WIDGET="https://$GHES_HOST/$GHES_REPO_PATH/blob/$CITE_SHA/src/widget.py#L1-L5"
# Branch-pinned (unpinned): must NOT be captured, on any invocation.
CITE_GHES_WIDGET2_BRANCH="https://$GHES_HOST/$GHES_REPO_PATH/blob/main/src/widget2.py"
CITE_GHES_TREE_SRC="https://$GHES_HOST/$GHES_REPO_PATH/tree/$CITE_SHA/src"
CITE_GHES_UNRELATED="https://$GHES_HOST/$GHES_REPO_PATH/blob/$CITE_SHA/docs/unrelated.md#L1-L2"
# Same repo/source as CITE_GHES_WIDGET above, different path — used to prove
# per-source isolation (design decision 3).
CITE_GHES_LIBUTIL="https://$GHES_HOST/$GHES_REPO_PATH/blob/$CITE_SHA/lib/util.py#L1-L2"
CITE_GHES_NESTED="https://$GHES_HOST/$GHES_REPO_PATH/blob/$CITE_SHA/nested/thing.py#L1-L2"
CITE_GL_LIBUTIL="https://$GL_HOST/$GL_REPO_PATH/-/blob/$CITE_SHA/lib/util.py#L1-L2"
CITE_GH_GUIDE="https://$GH_HOST/$GH_REPO_PATH/blob/$CITE_SHA/docs/guide.md#L1-L3"
# Stable-tag-pinned (v1.2.3): github.com's one accepted alternative to a SHA
# in permalink_density.py's own grammar — "the same per-forge grammar
# permalink_density.py credits" (criterion 1) should extract this too.
CITE_GH_GUIDE_TAG="https://$GH_HOST/$GH_REPO_PATH/blob/v1.2.3/docs/guide-v2.md#L1-L2"

# The three remaining forge grammars, each with a differently-positioned
# path — only these three (not github/gitlab, already covered above)
# exercise extraction shapes that actually differ from "path segment right
# after the SHA": Bitbucket Server puts the SHA in a query parameter with
# the path (if any) BEFORE it in the URL path; Bitbucket Cloud puts the
# path after the SHA like github/gitlab; Azure DevOps puts the path in a
# query parameter with a leading "/" that has no equivalent in a repo-
# relative changed-path list. A separate fixture, criterion-1-only: no
# --changed candidacy is asserted for these, so there is no need to also
# invent since_last_check entries and a plausible-but-unrequired
# registered-source/no-inventory-entry ambiguity for them.
BBS_HOST="bitbucket.example.com"
BBS_SRC="https://$BBS_HOST/projects/ACME/repos/widgets"
CITE_BBS_THING="https://$BBS_HOST/projects/ACME/repos/widgets/browse/src/thing.py?at=$CITE_SHA"

BBC_HOST="bitbucket.example.org"
BBC_SRC="https://$BBC_HOST/acme/widgets"
CITE_BBC_THING="https://$BBC_HOST/acme/widgets/src/$CITE_SHA/lib/thing.py"

ADO_HOST="ado.example.com"
ADO_SRC="https://$ADO_HOST/acme/platform/_git/widgets"
# Design decision 8 (see header): the query parameter carries a
# leading "/" ("/src/widget.py") that since_last_check's repo-relative
# paths never do; the extracted path must have it stripped.
CITE_ADO_WIDGET="https://$ADO_HOST/acme/platform/_git/widgets?path=/src/widget.py&version=GC$CITE_SHA"

# build_forge_fixture — a 3-file references/ corpus, one per remaining
# grammar, plus a source-paths.json registering their three hosts. Echoes
# the fixture ROOT.
build_forge_fixture() {
  local root="$WORK/forges"
  mkdir -p "$root/references" "$root/research"

  write_ref "$root/references/bitbucket-server.md" "$CITE_BBS_THING"
  write_ref "$root/references/bitbucket-cloud.md" "$CITE_BBC_THING"
  write_ref "$root/references/azure-devops.md" "$CITE_ADO_WIDGET"

  cat > "$root/research/source-paths.json" <<EOF
{
  "schema_version": 1,
  "sources": [
    {
      "id": "widgets-bbs",
      "kind": "git-managed",
      "url": "$BBS_SRC",
      "status": "confirmed",
      "archived": false,
      "lifecycle": {"state": "reachable", "last_checked": "2026-09-03", "last_checked_sha": "$CITE_SHA", "proposed_url": null},
      "discovered_via": null
    },
    {
      "id": "widgets-bbc",
      "kind": "git-managed",
      "url": "$BBC_SRC",
      "status": "confirmed",
      "archived": false,
      "lifecycle": {"state": "reachable", "last_checked": "2026-09-03", "last_checked_sha": "$CITE_SHA", "proposed_url": null},
      "discovered_via": null
    },
    {
      "id": "widgets-ado",
      "kind": "git-managed",
      "url": "$ADO_SRC",
      "status": "confirmed",
      "archived": false,
      "lifecycle": {"state": "reachable", "last_checked": "2026-09-03", "last_checked_sha": "$CITE_SHA", "proposed_url": null},
      "discovered_via": null
    }
  ]
}
EOF

  printf '%s' "$root"
}

# build_shared_fixture — an 8-file references/ corpus plus a
# research/source-paths.json registering the two git-managed sources above.
# Echoes the fixture ROOT (parent of references/ and research/).
build_shared_fixture() {
  local root="$WORK/shared"
  mkdir -p "$root/references" "$root/research"

  write_ref "$root/references/candidate-ghes.md" "$CITE_GHES_WIDGET" "$CITE_GHES_WIDGET2_BRANCH"
  write_ref "$root/references/candidate-dir-prefix.md" "$CITE_GHES_TREE_SRC"
  write_ref "$root/references/non-candidate.md" "$CITE_GHES_UNRELATED"
  write_ref "$root/references/candidate-gitlab.md" "$CITE_GL_LIBUTIL"
  write_ref "$root/references/cross-source-must-reject.md" "$CITE_GHES_LIBUTIL"
  write_ref "$root/references/multi-source-candidate.md" "$CITE_GHES_WIDGET" "$CITE_GL_LIBUTIL"
  write_ref "$root/references/github-mix.md" "$CITE_GH_GUIDE" "$CITE_GH_GUIDE_TAG"
  write_ref "$root/references/sub/nested.md" "$CITE_GHES_NESTED"

  cat > "$root/research/source-paths.json" <<EOF
{
  "schema_version": 1,
  "sources": [
    {
      "id": "widgets-ghes",
      "kind": "git-managed",
      "url": "$GHES_SRC",
      "status": "confirmed",
      "archived": false,
      "lifecycle": {"state": "reachable", "last_checked": "2026-09-03", "last_checked_sha": "$TO_SHA_1", "proposed_url": null},
      "discovered_via": null
    },
    {
      "id": "platform-gitlab",
      "kind": "git-managed",
      "url": "$GL_SRC",
      "status": "confirmed",
      "archived": false,
      "lifecycle": {"state": "reachable", "last_checked": "2026-09-03", "last_checked_sha": "$TO_SHA_2", "proposed_url": null},
      "discovered_via": null
    }
  ]
}
EOF

  printf '%s' "$root"
}

# build_inventory_file — the real multi-source research/.discover-
# inventory.json shape: an object keyed by source_id, each value the exact
# discover_inventory.py output object (file_counts_by_dir, largest_files,
# doc_roots, inventory_source, and a since_last_check carrying from_sha/
# to_sha/files verbatim from --since-json) that chunk 02's cache-advance
# recipe writes via `.[$sid] = $entry` in
# tool-and-output-mechanics.md's fenced doctrine:cache-advance-recipe block.
# Echoes the file path.
build_inventory_file() {
  local file="$WORK/inventory.json"
  jq -n \
    --arg from1 "$FROM_SHA_1" --arg to1 "$TO_SHA_1" \
    --arg from2 "$FROM_SHA_2" --arg to2 "$TO_SHA_2" \
    '{
      "widgets-ghes": {
        "file_counts_by_dir": {"src": 2, "docs": 1, "config": 1, "srcbackup": 1},
        "largest_files": [],
        "doc_roots": [],
        "inventory_source": "cache",
        "since_last_check": {
          "from_sha": $from1,
          "to_sha": $to1,
          "files": [
            {"path": "src/widget.py"},
            {"path": "src/other.py"},
            {"path": "config/settings.yaml"},
            {"path": "srcbackup/file.py"}
          ]
        }
      },
      "platform-gitlab": {
        "file_counts_by_dir": {"lib": 1},
        "largest_files": [],
        "doc_roots": [],
        "inventory_source": "cache",
        "since_last_check": {
          "from_sha": $from2,
          "to_sha": $to2,
          "files": [
            {"path": "lib/util.py"}
          ]
        }
      }
    }' > "$file"
  printf '%s' "$file"
}

SHARED_ROOT="$(build_shared_fixture)"
SHARED_REFS="$SHARED_ROOT/references"
SOURCE_PATHS_FILE="$SHARED_ROOT/research/source-paths.json"
INVENTORY_FILE="$(build_inventory_file)"
FORGE_ROOT="$(build_forge_fixture)"
FORGE_REFS="$FORGE_ROOT/references"

# ============================================================================
# Fixture self-check — verify what was actually built, never trust intent
# ============================================================================
section "fixture self-check"

sha_len_ok=true
for sha_val in "$CITE_SHA" "$FROM_SHA_1" "$TO_SHA_1" "$FROM_SHA_2" "$TO_SHA_2"; do
  [ "${#sha_val}" -eq 40 ] || sha_len_ok=false
done
if $sha_len_ok; then
  pass "every generated fixture SHA is exactly 40 hex characters"
else
  fail "every generated fixture SHA is exactly 40 hex characters" \
    "CITE_SHA=$CITE_SHA FROM_SHA_1=$FROM_SHA_1 TO_SHA_1=$TO_SHA_1 FROM_SHA_2=$FROM_SHA_2 TO_SHA_2=$TO_SHA_2"
fi

md_count="$(find "$SHARED_REFS" -name '*.md' | wc -l | tr -d ' ')"
if [ "$md_count" -eq 8 ]; then
  pass "the shared references corpus has exactly 8 markdown files"
else
  fail "the shared references corpus has exactly 8 markdown files" "found: $md_count"
fi

fixture_pairs=(
  "candidate-ghes.md|$CITE_GHES_WIDGET"
  "candidate-ghes.md|$CITE_GHES_WIDGET2_BRANCH"
  "candidate-dir-prefix.md|$CITE_GHES_TREE_SRC"
  "non-candidate.md|$CITE_GHES_UNRELATED"
  "candidate-gitlab.md|$CITE_GL_LIBUTIL"
  "cross-source-must-reject.md|$CITE_GHES_LIBUTIL"
  "multi-source-candidate.md|$CITE_GHES_WIDGET"
  "multi-source-candidate.md|$CITE_GL_LIBUTIL"
  "github-mix.md|$CITE_GH_GUIDE"
  "github-mix.md|$CITE_GH_GUIDE_TAG"
  "sub/nested.md|$CITE_GHES_NESTED"
)
pairs_ok=true
for pair in "${fixture_pairs[@]}"; do
  pf="${pair%%|*}"
  pu="${pair#*|}"
  if ! grep -qF -- "$pu" "$SHARED_REFS/$pf" 2>/dev/null; then
    pairs_ok=false
    fail "$pf contains the citation it is meant to carry" "expected substring: $pu"
  fi
done
if $pairs_ok; then
  pass "every reference file contains exactly the citation(s) it is meant to carry"
fi

if jq_check "$(cat "$SOURCE_PATHS_FILE")" '
    (.sources | length) == 2
    and (.sources[0].id == "widgets-ghes") and (.sources[0].url == $ghes)
    and (.sources[1].id == "platform-gitlab") and (.sources[1].url == $gl)
' --arg ghes "$GHES_SRC" --arg gl "$GL_SRC"; then
  pass "source-paths.json registers exactly the two intended source ids and URLs"
else
  fail "source-paths.json registers exactly the two intended source ids and URLs" "$(cat "$SOURCE_PATHS_FILE")"
fi

if jq_check "$(cat "$INVENTORY_FILE")" '
    (."widgets-ghes".since_last_check.files | length) == 4
    and (."platform-gitlab".since_last_check.files | length) == 1
    and ((."widgets-ghes".since_last_check.files | map(.path) | sort)
         == ["config/settings.yaml","src/other.py","src/widget.py","srcbackup/file.py"])
    and ((."platform-gitlab".since_last_check.files | map(.path)) == ["lib/util.py"])
'; then
  pass "the multi-source inventory carries exactly the intended since_last_check file lists"
else
  fail "the multi-source inventory carries exactly the intended since_last_check file lists" "$(cat "$INVENTORY_FILE")"
fi

forge_pairs=(
  "bitbucket-server.md|$CITE_BBS_THING"
  "bitbucket-cloud.md|$CITE_BBC_THING"
  "azure-devops.md|$CITE_ADO_WIDGET"
)
forge_pairs_ok=true
for pair in "${forge_pairs[@]}"; do
  pf="${pair%%|*}"
  pu="${pair#*|}"
  if ! grep -qF -- "$pu" "$FORGE_REFS/$pf" 2>/dev/null; then
    forge_pairs_ok=false
    fail "$pf (forge fixture) contains the citation it is meant to carry" "expected substring: $pu"
  fi
done
if $forge_pairs_ok; then
  pass "every forge-fixture reference file contains the citation it is meant to carry"
fi

if jq_check "$(cat "$FORGE_ROOT/research/source-paths.json")" '(.sources | length) == 3'; then
  pass "the forge fixture registers exactly the three remaining-grammar sources"
else
  fail "the forge fixture registers exactly the three remaining-grammar sources" \
    "$(cat "$FORGE_ROOT/research/source-paths.json")"
fi

# ============================================================================
# Criterion 1 — base scan: JSON object mapping each *.md to its cited paths
# ============================================================================
section "criterion 1 — base scan prints {ref: sorted cited paths}, per-forge grammar, tree/<sha>/<dir> contributes a directory"

base_out="$(cp_out "$SHARED_REFS")"
base_rc=$?

# Design decision 1 (see header): keys are relative to the <references-dir>
# argument itself, POSIX "/" separators.
want_base_json="$(jq -n '
{
  "candidate-ghes.md": ["src/widget.py"],
  "candidate-dir-prefix.md": ["src"],
  "non-candidate.md": ["docs/unrelated.md"],
  "candidate-gitlab.md": ["lib/util.py"],
  "cross-source-must-reject.md": ["lib/util.py"],
  "multi-source-candidate.md": ["lib/util.py", "src/widget.py"],
  "github-mix.md": ["docs/guide-v2.md", "docs/guide.md"],
  "sub/nested.md": ["nested/thing.py"]
}
')"

if [ "$base_rc" -eq 0 ] && jq_check "$base_out" '. == $want' --argjson want "$want_base_json"; then
  pass "the base scan's JSON object exactly matches the intended per-file cited-path map"
else
  fail "the base scan's JSON object exactly matches the intended per-file cited-path map" \
    "rc=$base_rc" "$(printf 'want: %s\ngot:  %s' "$want_base_json" "$base_out")"
fi

if jq_check "$base_out" '."candidate-ghes.md" == ["src/widget.py"]'; then
  pass "a SHA-pinned blob permalink contributes its own path; a branch-pinned (unpinned) permalink in the same file is excluded"
else
  fail "a SHA-pinned blob permalink contributes its own path; a branch-pinned (unpinned) permalink in the same file is excluded" "$base_out"
fi

if jq_check "$base_out" '."candidate-dir-prefix.md" == ["src"]'; then
  pass "a tree/<sha>/<dir> permalink contributes the directory path, not a file path"
else
  fail "a tree/<sha>/<dir> permalink contributes the directory path, not a file path" "$base_out"
fi

if jq_check "$base_out" '."multi-source-candidate.md" == ["lib/util.py","src/widget.py"]'; then
  pass "a reference citing two different forges' permalinks is parsed with each forge's own grammar into one sorted set"
else
  fail "a reference citing two different forges' permalinks is parsed with each forge's own grammar into one sorted set" "$base_out"
fi

if jq_check "$base_out" '."github-mix.md" == ["docs/guide-v2.md","docs/guide.md"]'; then
  pass "a github.com stable-tag-pinned permalink (v1.2.3) contributes its path the same as a SHA-pinned one"
else
  fail "a github.com stable-tag-pinned permalink (v1.2.3) contributes its path the same as a SHA-pinned one" "$base_out"
fi

if jq_check "$base_out" '."sub/nested.md" == ["nested/thing.py"]'; then
  pass "a *.md file nested under a subdirectory of the references dir is discovered and keyed by its relative path"
else
  fail "a *.md file nested under a subdirectory of the references dir is discovered and keyed by its relative path" "$base_out"
fi

# The three remaining forge grammars: each puts its path in a different
# position relative to the SHA, so extraction genuinely differs per forge
# rather than reusing one github-shaped offset.
forge_out="$(cp_out "$FORGE_REFS")"
forge_rc=$?

want_forge_json="$(jq -n '
{
  "bitbucket-server.md": ["src/thing.py"],
  "bitbucket-cloud.md": ["lib/thing.py"],
  "azure-devops.md": ["src/widget.py"]
}
')"

if [ "$forge_rc" -eq 0 ] && jq_check "$forge_out" '. == $want' --argjson want "$want_forge_json"; then
  pass "the three remaining forge grammars (bitbucket-server, bitbucket-cloud, azure-devops) each extract their differently-positioned path"
else
  fail "the three remaining forge grammars (bitbucket-server, bitbucket-cloud, azure-devops) each extract their differently-positioned path" \
    "rc=$forge_rc" "$(printf 'want: %s\ngot:  %s' "$want_forge_json" "$forge_out")"
fi

# Design decision 8 (see header): Azure DevOps's ?path=/src/widget.py query
# parameter carries a leading "/" that since_last_check's repo-relative
# paths never do (e.g. "src/widget.py", not "/src/widget.py"); the
# extracted path must have it stripped to ever intersect with a changed-path
# list under --changed.
if jq_check "$forge_out" '."azure-devops.md" == ["src/widget.py"]'; then
  pass "Design decision 8: an Azure DevOps permalink's leading query-parameter slash is stripped from the extracted path"
else
  fail "Design decision 8: an Azure DevOps permalink's leading query-parameter slash is stripped from the extracted path" "$forge_out"
fi

# ============================================================================
# Criterion 2 — --changed: multi-source inventory, per-source intersection
# ============================================================================
section "criterion 2 — --changed reads the multi-source inventory and prints the per-source re-emit candidate set"

changed_out="$(cp_out "$SHARED_REFS" --changed "$INVENTORY_FILE")"
changed_rc=$?

# Design decisions 2-4 (see header): {"candidates": {ref: {source_id:
# [changed paths]}}, "uncited_changes": {...}}; "matching paths" = the
# CHANGED paths that satisfied the match, not the reference's own citation.
want_changed_json="$(jq -n '
{
  "candidates": {
    "candidate-ghes.md": {"widgets-ghes": ["src/widget.py"]},
    "candidate-dir-prefix.md": {"widgets-ghes": ["src/other.py", "src/widget.py"]},
    "candidate-gitlab.md": {"platform-gitlab": ["lib/util.py"]},
    "multi-source-candidate.md": {"widgets-ghes": ["src/widget.py"], "platform-gitlab": ["lib/util.py"]}
  },
  "uncited_changes": {
    "count": 2,
    "paths": ["config/settings.yaml", "srcbackup/file.py"]
  }
}
')"

if [ "$changed_rc" -eq 0 ] && jq_check "$changed_out" '. == $want' --argjson want "$want_changed_json"; then
  pass "--changed output exactly matches the intended candidate-set/uncited-changes shape"
else
  fail "--changed output exactly matches the intended candidate-set/uncited-changes shape" \
    "rc=$changed_rc" "$(printf 'want: %s\ngot:  %s' "$want_changed_json" "$changed_out")"
fi

if jq_check "$changed_out" '.candidates["candidate-ghes.md"]["widgets-ghes"] == ["src/widget.py"]'; then
  pass "outcome: candidate — an exact cited-path match against the source it is scoped to is a candidate"
else
  fail "outcome: candidate — an exact cited-path match against the source it is scoped to is a candidate" "$changed_out"
fi

if jq_check "$changed_out" '.candidates | has("non-candidate.md") | not'; then
  pass "outcome: non-candidate — a reference whose cited paths are all unchanged is absent from the candidate set (the must-reject input)"
else
  fail "outcome: non-candidate — a reference whose cited paths are all unchanged is absent from the candidate set" "$changed_out"
fi

# Design decision 3 (see header): source resolution is per registered
# source, not per host. lib/util.py really did change — but only in
# platform-gitlab, and this citation resolves to widgets-ghes (same repo as
# CITE_GHES_WIDGET), whose changed set does not include it.
if jq_check "$changed_out" '.candidates | has("cross-source-must-reject.md") | not'; then
  pass "per-source isolation: a path string that changed in a DIFFERENT source than the one this citation resolves to does not candidate it"
else
  fail "per-source isolation: a path string that changed in a DIFFERENT source than the one this citation resolves to does not candidate it" "$changed_out"
fi

if jq_check "$changed_out" '(.candidates["candidate-dir-prefix.md"]["widgets-ghes"] | sort) == ["src/other.py","src/widget.py"]'; then
  pass "directory-prefix matching: a cited directory candidates every changed path it properly prefixes, and lists each as a matching path"
else
  fail "directory-prefix matching: a cited directory candidates every changed path it properly prefixes, and lists each as a matching path" "$changed_out"
fi

if jq_check "$changed_out" '
    (.candidates["multi-source-candidate.md"]["widgets-ghes"] == ["src/widget.py"])
    and (.candidates["multi-source-candidate.md"]["platform-gitlab"] == ["lib/util.py"])
'; then
  pass "a reference spanning two sources is candidated under each source it cites, independently"
else
  fail "a reference spanning two sources is candidated under each source it cites, independently" "$changed_out"
fi

# ============================================================================
# Criterion 3 — uncited_changes: changed paths no reference cites, with count
# ============================================================================
section "criterion 3 — uncited_changes names the changed paths nobody cites, with a count"

if jq_check "$changed_out" '.uncited_changes.count == 2'; then
  pass "uncited_changes.count is 2"
else
  fail "uncited_changes.count is 2" "$changed_out"
fi

if jq_check "$changed_out" '(.uncited_changes.paths | sort) == ["config/settings.yaml","srcbackup/file.py"]'; then
  pass "outcome: uncited change — config/settings.yaml, changed but cited by nobody in the corpus, is listed"
else
  fail "outcome: uncited change — config/settings.yaml, changed but cited by nobody in the corpus, is listed" "$changed_out"
fi

# Design decision 5 (see header): a '/'-boundary is required. srcbackup/
# file.py shares only a raw string prefix with the cited directory "src"
# (candidate-dir-prefix.md), not a real subdirectory relationship, so it
# must stay uncited rather than being silently swallowed by a naive
# substring-prefix match.
if jq_check "$changed_out" '.uncited_changes.paths | index("srcbackup/file.py") != null'; then
  pass "directory-prefix boundary check: srcbackup/file.py is NOT swallowed by the cited directory \"src\" (a raw prefix with no / boundary does not match)"
else
  fail "directory-prefix boundary check: srcbackup/file.py is NOT swallowed by the cited directory \"src\"" "$changed_out"
fi

# ============================================================================
# Criterion 6 — stdlib-only, read-only, empty-dir {} exit 0, named error
# ============================================================================
section "criterion 6 — stdlib-only, read-only, empty references dir exits 0 with {}, --changed with no since_last_check exits non-zero named"

empty_root="$WORK/empty"
mkdir -p "$empty_root/references"

empty_out="$(cp_out "$empty_root/references")"
empty_rc=$?
if [ "$empty_rc" -eq 0 ] && jq_check "$empty_out" '. == {}'; then
  pass "an empty references directory exits 0 with an empty JSON object"
else
  fail "an empty references directory exits 0 with an empty JSON object" "rc=$empty_rc" "$empty_out"
fi

# Design decision 7 (see header): "a file without since_last_check" = no
# source_id anywhere in the file carries the key — the shape a DISCOVER-only
# inventory has (spec.md's "Out of scope: DISCOVER" note).
no_since_file="$WORK/no-since-last-check.json"
jq -n '{"widgets-ghes": {"file_counts_by_dir": {}, "inventory_source": "cache"}}' > "$no_since_file"

no_since_err="$(cp_err "$empty_root/references" --changed "$no_since_file")"
no_since_rc=$?
if [ "$no_since_rc" -ne 0 ] && printf '%s' "$no_since_err" | grep -qi 'since_last_check'; then
  pass "a --changed file with no since_last_check anywhere in it exits non-zero with an error naming since_last_check"
else
  fail "a --changed file with no since_last_check anywhere in it exits non-zero with an error naming since_last_check" \
    "rc=$no_since_rc" "$no_since_err"
fi

if [ -f "$CITED_PATHS" ]; then
  non_stdlib="$(python3 - "$CITED_PATHS" <<'PYEOF'
import ast, sys
path = sys.argv[1]
tree = ast.parse(open(path, encoding="utf-8").read(), filename=path)
stdlib = getattr(sys, "stdlib_module_names", None)
if stdlib is None:
    stdlib = {"argparse", "json", "os", "re", "subprocess", "sys", "pathlib", "urllib"}
mods = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            mods.add(alias.name.split(".")[0])
    elif isinstance(node, ast.ImportFrom):
        if node.module is not None and node.level == 0:
            mods.add(node.module.split(".")[0])
mods.discard("__future__")
# permalink_density is a sibling module in this repository (the documented,
# additive-export import), not a third-party dependency.
mods.discard("permalink_density")
print("\n".join(sorted(m for m in mods if m not in stdlib)))
PYEOF
)"
  if [ -z "$non_stdlib" ]; then
    pass "every top-level import resolves to the standard library (its sibling permalink_density import aside)"
  else
    fail "every top-level import resolves to the standard library" "$non_stdlib"
  fi
else
  fail "every top-level import resolves to the standard library" "cited_paths.py does not exist yet"
fi

fp_before="$(dir_fingerprint "$SHARED_ROOT")"
cp_out "$SHARED_REFS" >/dev/null
cp_out "$SHARED_REFS" --changed "$INVENTORY_FILE" >/dev/null
fp_after="$(dir_fingerprint "$SHARED_ROOT")"
if [ "$fp_before" = "$fp_after" ]; then
  pass "read-only: running the script (with and without --changed) writes nothing under the fixture tree"
else
  fail "read-only: running the script writes nothing under the fixture tree" \
    "fingerprint before: $fp_before" "fingerprint after: $fp_after"
fi

# ============================================================================
# Regression guard — permalink_density.py's existing exports stay intact
# ============================================================================
section "regression guard — the already-shipped permalink-forges suite (build_permalink_res / accepted_hosts) stays green"

# spec.md's own "Consumers of shared symbols" note: the additive path-
# capturing export must not change build_permalink_res's or accepted_hosts's
# existing shape, since three other callers depend on it unchanged.
if [ -f "$PERMALINK_FORGES_ORACLE" ]; then
  if bash "$PERMALINK_FORGES_ORACLE" >/dev/null 2>&1; then
    pass "the already-shipped permalink-forges suite passes unmodified"
  else
    fail "the already-shipped permalink-forges suite passes unmodified" \
      "permalink_density.py's existing exports may have been changed rather than added to"
  fi
else
  fail "the already-shipped permalink-forges suite is present to run as a regression guard" \
    "not found at $PERMALINK_FORGES_ORACLE"
fi

# ============================================================================
# Criterion 4 — drift-detection-and-phases.md: read candidate set first,
# scope to candidates + uncited changes, state a reason for any other re-emit
# ============================================================================
section "criterion 4 — drift-detection-and-phases.md instructs the model to use the candidate set"

drift_flat="$(normalize "$(cat "$DRIFT_PHASES" 2>/dev/null)")"

if printf '%s' "$drift_flat" | grep -qF 'cited_paths.py'; then
  pass "drift-detection-and-phases.md names cited_paths.py as the script producing the candidate set"
else
  fail "drift-detection-and-phases.md names cited_paths.py as the script producing the candidate set"
fi

# GUESS: wording is unwritten; asserted as a proximity pattern against the
# whole flattened document so the check survives wherever the instruction
# lands, rather than pinning it to one heading. `.{0,N}` (any character),
# not `[^.]{0,N}` — a correct instruction naming cited_paths.py or
# research/.discover-inventory.json in between the two anchors carries
# literal periods, and a negated-dot class would false-fail on those.
if printf '%s' "$drift_flat" | grep -qiE 'candidate set.{0,200}before.{0,200}re-(read|emit)|before.{0,200}re-(read|emit).{0,200}candidate set'; then
  pass "drift-detection-and-phases.md instructs reading the candidate set before re-reading/re-emitting anything"
else
  fail "drift-detection-and-phases.md instructs reading the candidate set before re-reading/re-emitting anything"
fi

if printf '%s' "$drift_flat" | grep -qiE 'candidate.{0,250}uncited|uncited.{0,250}candidate'; then
  pass "drift-detection-and-phases.md scopes the re-read to the candidate references plus the uncited changes"
else
  fail "drift-detection-and-phases.md scopes the re-read to the candidate references plus the uncited changes"
fi

if printf '%s' "$drift_flat" | grep -qiE 'non-candidate.{0,250}reason|reason.{0,250}non-candidate'; then
  pass "drift-detection-and-phases.md requires a stated reason for re-emitting a non-candidate reference anyway"
else
  fail "drift-detection-and-phases.md requires a stated reason for re-emitting a non-candidate reference anyway"
fi

# ============================================================================
# Criterion 5a — tool-and-output-mechanics.md's Coverage report bullet
# ============================================================================
section "criterion 5a — the post-run summary's Coverage report lists the candidate set (grouped by source) and the uncited-change count"

coverage_block="$(awk '
  /^1\. \*\*Coverage report\.\*\*/ { f = 1 }
  f && /^2\. \*\*Skip-reasoning/ { exit }
  f { print }
' "$TOOL_MECHANICS" 2>/dev/null)"
coverage_flat="$(normalize "$coverage_block")"

if [ -n "$coverage_block" ]; then
  pass "precondition: the Coverage report bullet (item 1 of Post-run summary) is present in tool-and-output-mechanics.md"
else
  fail "precondition: the Coverage report bullet (item 1 of Post-run summary) is present in tool-and-output-mechanics.md" \
    "the anchor '1. **Coverage report.**' was not found; the checks below cannot be evaluated meaningfully"
fi

if printf '%s' "$coverage_flat" | grep -qiE 'candidate set'; then
  pass "the Coverage report bullet mentions the candidate set"
else
  fail "the Coverage report bullet mentions the candidate set"
fi

if printf '%s' "$coverage_flat" | grep -qiE 'grouped by source'; then
  pass "the Coverage report bullet groups the candidate set by source"
else
  fail "the Coverage report bullet groups the candidate set by source"
fi

if printf '%s' "$coverage_flat" | grep -qiE 'uncited'; then
  pass "the Coverage report bullet surfaces the uncited-change count"
else
  fail "the Coverage report bullet surfaces the uncited-change count"
fi

# ============================================================================
# Criterion 5b — review/SKILL.md Step 2's report-only Re-emit candidates line
# ============================================================================
section "criterion 5b — review Step 2 writes the exact Re-emit candidates line, placed with the density line, outside the 5-9 budget, omitted when nothing advanced"

review_flat="$(normalize "$(cat "$REVIEW_SKILL" 2>/dev/null)")"

# NOT a guess: spec.md quotes this line verbatim in backticks, the same way
# review/SKILL.md's existing density line is a literal template string
# today (`Paragraph→permalink density: <pct>% (report-only; not one of the
# disagreements below).`).
EXACT_LINE='Re-emit candidates: N of M references cite changed paths (K changed paths uncited).'

if printf '%s' "$review_flat" | grep -qF -- "$EXACT_LINE"; then
  pass "review/SKILL.md carries the exact literal template line spec.md quotes verbatim"
else
  fail "review/SKILL.md carries the exact literal template line spec.md quotes verbatim" \
    "expected substring: $EXACT_LINE"
fi

# Window capped at 250 (not the 600 the prose distance might actually
# call for): BSD/macOS grep -E rejects an interval bound above 255
# ("maximum repetition exceeds 255"), so the window has to fit under that
# ceiling on every platform this suite runs on.
if printf '%s' "$review_flat" | grep -qiE 'Paragraph.{0,250}Re-emit candidates|Re-emit candidates.{0,250}Paragraph'; then
  pass "the Re-emit candidates line is placed near the existing density line"
else
  fail "the Re-emit candidates line is placed near the existing density line"
fi

if printf '%s' "$review_flat" | grep -qiE 'Re-emit candidates.{0,250}(5.?.?9|budget|not counted|never counted)|(5.?.?9|budget|not counted|never counted).{0,250}Re-emit candidates'; then
  pass "review/SKILL.md documents the Re-emit candidates line as never counted toward the 5-9 slot budget"
else
  fail "review/SKILL.md documents the Re-emit candidates line as never counted toward the 5-9 slot budget"
fi

if printf '%s' "$review_flat" | grep -qiE 'Re-emit candidates.{0,250}(omit|no source advanced)|(omit|no source advanced).{0,250}Re-emit candidates'; then
  pass "review/SKILL.md documents that the line is omitted when no source advanced in the proposal"
else
  fail "review/SKILL.md documents that the line is omitted when no source advanced in the proposal"
fi

# ============================================================================
# Normalization: the citation's own shape, and the registered url's shape
# ============================================================================
section "normalization — trailing slash / query / punctuation on a citation, and .git / case / SSH on a registered url"

NORM_SHA="$(repeat_hex "f6" 20)"

# The path-capturing regex stops only at whitespace, ')' and ']', so a
# trailing '/', a '?query' and sentence punctuation all survive into the
# cited path. On the registry side the url is compared verbatim, so the
# '.git' suffix and the SSH form -- both accepted at intake -- and any
# difference in owner/repo case never resolve to their source. Each shape
# below lands its changed file in uncited_changes under a false label.
build_norm_fixture() {
  local root="$WORK/norm"
  mkdir -p "$root/references" "$root/research"

  write_ref "$root/references/trailing-slash.md" \
    "https://github.com/acme/norm/tree/$NORM_SHA/packages/core/"
  write_ref "$root/references/query.md" \
    "https://github.com/acme/norm/blob/$NORM_SHA/src/b.py?plain=1"
  write_ref "$root/references/comma.md" \
    "See https://github.com/acme/norm/blob/$NORM_SHA/src/c.py, which moved."
  write_ref "$root/references/dotgit.md" \
    "https://github.com/acme/dotgit/blob/$NORM_SHA/src/e.py"
  write_ref "$root/references/cased.md" \
    "https://github.com/Acme/Cased/blob/$NORM_SHA/src/f.py"
  write_ref "$root/references/ssh.md" \
    "https://github.com/acme/sshrepo/blob/$NORM_SHA/src/g.py"

  cat > "$root/research/source-paths.json" <<EOF
{
  "schema_version": 1,
  "sources": [
    {
      "id": "norm",
      "kind": "git-managed",
      "url": "https://github.com/acme/norm",
      "status": "confirmed",
      "archived": false,
      "lifecycle": {"state": "reachable", "last_checked": "2026-09-06", "last_checked_sha": "$NORM_SHA", "proposed_url": null},
      "discovered_via": null
    },
    {
      "id": "dotgit",
      "kind": "git-managed",
      "url": "https://github.com/acme/dotgit.git",
      "status": "confirmed",
      "archived": false,
      "lifecycle": {"state": "reachable", "last_checked": "2026-09-06", "last_checked_sha": "$NORM_SHA", "proposed_url": null},
      "discovered_via": null
    },
    {
      "id": "cased",
      "kind": "git-managed",
      "url": "https://github.com/acme/cased",
      "status": "confirmed",
      "archived": false,
      "lifecycle": {"state": "reachable", "last_checked": "2026-09-06", "last_checked_sha": "$NORM_SHA", "proposed_url": null},
      "discovered_via": null
    },
    {
      "id": "sshrepo",
      "kind": "git-managed",
      "url": "git@github.com:acme/sshrepo.git",
      "status": "confirmed",
      "archived": false,
      "lifecycle": {"state": "reachable", "last_checked": "2026-09-06", "last_checked_sha": "$NORM_SHA", "proposed_url": null},
      "discovered_via": null
    }
  ]
}
EOF
  printf '%s' "$root"
}

NORM_ROOT="$(build_norm_fixture)"
NORM_REFS="$NORM_ROOT/references"
NORM_INVENTORY="$WORK/norm-inventory.json"
jq -n --arg sha "$NORM_SHA" '
{
  "norm": {
    "file_counts_by_dir": {"src": 2, "packages": 1}, "largest_files": [], "doc_roots": [],
    "inventory_source": "cache",
    "since_last_check": {"from_sha": $sha, "to_sha": $sha,
      "files": [{"path": "packages/core/a.py"}, {"path": "src/b.py"}, {"path": "src/c.py"}]}
  },
  "dotgit": {
    "file_counts_by_dir": {"src": 1}, "largest_files": [], "doc_roots": [],
    "inventory_source": "cache",
    "since_last_check": {"from_sha": $sha, "to_sha": $sha, "files": [{"path": "src/e.py"}]}
  },
  "cased": {
    "file_counts_by_dir": {"src": 1}, "largest_files": [], "doc_roots": [],
    "inventory_source": "cache",
    "since_last_check": {"from_sha": $sha, "to_sha": $sha, "files": [{"path": "src/f.py"}]}
  },
  "sshrepo": {
    "file_counts_by_dir": {"src": 1}, "largest_files": [], "doc_roots": [],
    "inventory_source": "cache",
    "since_last_check": {"from_sha": $sha, "to_sha": $sha, "files": [{"path": "src/g.py"}]}
  }
}' > "$NORM_INVENTORY"

# ----- the citation's own shape -----

norm_base="$(cp_out "$NORM_REFS")"
if jq_check "$norm_base" '.["trailing-slash.md"] == ["packages/core"]'; then
  pass "a tree citation written with a trailing slash yields the bare directory path"
else
  fail "a tree citation written with a trailing slash yields the bare directory path" "$norm_base"
fi
if jq_check "$norm_base" '.["query.md"] == ["src/b.py"]'; then
  pass "a '?plain=1' query string is not part of the cited path"
else
  fail "a '?plain=1' query string is not part of the cited path" "$norm_base"
fi
if jq_check "$norm_base" '.["comma.md"] == ["src/c.py"]'; then
  pass "sentence punctuation trailing a citation is not part of the cited path"
else
  fail "sentence punctuation trailing a citation is not part of the cited path" "$norm_base"
fi

# ----- the registered url's shape -----

norm_changed="$(cp_out "$NORM_REFS" --changed "$NORM_INVENTORY")"
norm_rc=$?

if [ "$norm_rc" -eq 0 ] && jq_check "$norm_changed" '.uncited_changes.count == 0'; then
  pass "every changed path resolves to the reference that cites it — uncited_changes is empty"
else
  fail "every changed path resolves to the reference that cites it — uncited_changes is empty" \
    "rc=$norm_rc" "$norm_changed"
fi
if jq_check "$norm_changed" '.candidates["trailing-slash.md"]["norm"] == ["packages/core/a.py"]'; then
  pass "a trailing-slash directory citation still matches a file nested under it"
else
  fail "a trailing-slash directory citation still matches a file nested under it" "$norm_changed"
fi
if jq_check "$norm_changed" '.candidates["dotgit.md"]["dotgit"] == ["src/e.py"]'; then
  pass "a source registered with a '.git' suffix resolves from a citation written without one"
else
  fail "a source registered with a '.git' suffix resolves from a citation written without one" "$norm_changed"
fi
if jq_check "$norm_changed" '.candidates["cased.md"]["cased"] == ["src/f.py"]'; then
  pass "owner/repo case differing between the citation and the registered url still resolves"
else
  fail "owner/repo case differing between the citation and the registered url still resolves" "$norm_changed"
fi
if jq_check "$norm_changed" '.candidates["ssh.md"]["sshrepo"] == ["src/g.py"]'; then
  pass "a source registered in scp-style SSH form resolves from its https citation"
else
  fail "a source registered in scp-style SSH form resolves from its https citation" "$norm_changed"
fi

# ----- summary -------------------------------------------------------------

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
