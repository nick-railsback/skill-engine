#!/usr/bin/env bash
# Feature-scoped test runner for the permalink grammars that
# permalink_density.py (SELF-AUDIT Check 7) and grounded_rate.py (Check 8)
# credit, and for the hostnames on which they credit them.
#
# Every case builds a synthetic tree under one tempdir, invokes a CLI, and
# asserts an exit code plus a whitespace-normalized substring of stdout. No
# network, no model calls, no API key. Output uses the sibling runners'
# indented "  PASS  " / "  FAIL  " convention.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
LINT="$PLUGIN_ROOT/tests/permalink_density.py"
GROUNDED="$PLUGIN_ROOT/tests/grounded_rate.py"

# The preservation baseline: the lint exactly as it stood before this work,
# so the bundled-example percentages are compared against a recomputation
# rather than against a number frozen in this file (the example corpora
# change; a hardcoded percentage would go stale and start lying).
#
# It is resolved from git history when the pinned commit is reachable, and
# from the byte-identical vendored copy otherwise — a shallow clone, an
# export with no .git, or a history rewrite all drop the commit, and this
# file outlives any of those. When both are available the two are compared,
# so the vendored copy cannot silently drift away from the commit it claims
# to be. Nothing may be added to the vendored file: the integrity case is a
# byte comparison.
BASELINE_SHA="4dc5725e1c44843289bda8bd8ed8900325b2681b"
BASELINE_REPO_PATH="plugin/skill-engine/tests/permalink_density.py"
BASELINE_VENDORED="$SCRIPT_DIR/fixtures/baseline/permalink_density.py"

pass_count=0
fail_count=0
skip_count=0

WORK="$(mktemp -d -t skill-engine-permalink-forges.XXXXXX)"
cleanup_tmp() {
  rm -rf "$WORK"
}
trap cleanup_tmp EXIT

pass_case() {
  printf '  PASS  %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail_case() {
  printf '  FAIL  %s\n' "$1"
  if [ "$#" -gt 1 ]; then
    printf '%s\n' "$2" | sed 's/^/        /'
  fi
  fail_count=$((fail_count + 1))
  return 0
}

# A skipped case is never a pass and never a failure: it is a case whose
# precondition is absent in this checkout. It is reported loudly and kept
# out of the exit-code decision.
skip_case() {
  printf '  SKIP  %s\n' "$1"
  printf '        %s\n' "$2"
  skip_count=$((skip_count + 1))
  return 0
}

# Collapse every run of whitespace — newlines included — to one space before
# matching, so an assertion about a phrase does not depend on where the
# phrase happened to break across lines.
normalize() {
  printf '%s' "$1" | tr -s '[:space:]' ' '
}

# First verdict token and first fractional percentage in a report, as one
# comparable signature. Empty halves make an unusable signature detectable.
report_signature() {
  local text="$1" verdict pct
  verdict="$(printf '%s' "$text" | grep -o -E '\[(PASS|FAIL|N/A|DRY-RUN)\]' | sed -n '1p')"
  pct="$(printf '%s' "$text" | grep -o -E '[0-9]+\.[0-9]+%' | sed -n '1p')"
  printf '%s|%s' "$verdict" "$pct"
}

# assert_density <name> <expected-rc> <expected-substring> <references-dir> [extra CLI args...]
assert_density() {
  local name="$1" exp_rc="$2" exp_sub="$3" refs="$4"
  shift 4
  local out rc norm
  out="$(python3 "$LINT" "$refs" "$@" 2>&1)" && rc=0 || rc=$?
  norm="$(normalize "$out")"
  if [ "$rc" -eq "$exp_rc" ] && printf '%s' "$norm" | grep -qF -- "$exp_sub"; then
    pass_case "$name"
  else
    fail_case "$name" "$(printf 'expected rc=%d and substring: %s\ngot rc=%d:\n%s' \
      "$exp_rc" "$exp_sub" "$rc" "$out")"
  fi
}

# assert_grounded <name> <expected-rc> <expected-substring> <ctx-root> [extra CLI args...]
assert_grounded() {
  local name="$1" exp_rc="$2" exp_sub="$3" ctx="$4"
  shift 4
  local out rc norm
  out="$(python3 "$GROUNDED" "$ctx" --threshold 0.80 "$@" 2>&1)" && rc=0 || rc=$?
  norm="$(normalize "$out")"
  if [ "$rc" -eq "$exp_rc" ] && printf '%s' "$norm" | grep -qF -- "$exp_sub"; then
    pass_case "$name"
  else
    fail_case "$name" "$(printf 'expected rc=%d and substring: %s\ngot rc=%d:\n%s' \
      "$exp_rc" "$exp_sub" "$rc" "$out")"
  fi
}

# ----- fixture builders --------------------------------------------------

SHA="0123456789abcdef0123456789abcdef01234567"
SHA_B="fedcba9876543210fedcba9876543210fedcba98"

# Hosts. Every name is under a reserved test domain so no fixture can ever
# resolve to a real service.
GH_HOST="github.com"
GHES_HOST="git.enterprise.example"
GL_HOST="gitlab.example.com"
BBS_HOST="bitbucket.example.com"
BBC_HOST="bitbucket.example.org"
ADO_HOST="ado.example.com"
UNREG_HOST="git.unregistered.example"

# Source-root URLs, as a contextualizer registers them.
GHES_SRC="https://$GHES_HOST/acme/widgets"
GL_SRC="https://$GL_HOST/acme/platform/widgets"
BBS_SRC="https://$BBS_HOST/projects/ACME/repos/widgets"
BBC_SRC="https://$BBC_HOST/acme/widgets"
ADO_SRC="https://$ADO_HOST/acme/platform/_git/widgets"
GH_SRC="https://$GH_HOST/acme/widgets"

# SHA-pinned citations, one per grammar.
GH_PIN="https://$GH_HOST/acme/widgets/blob/$SHA/src/widget.py#L10-L20"
GH_TREE_PIN="https://$GH_HOST/acme/widgets/tree/$SHA/src/widget.py"
GH_TAG_PIN="https://$GH_HOST/acme/widgets/blob/v1.2.3/src/widget.py#L10-L20"
GHES_PIN="https://$GHES_HOST/acme/widgets/blob/$SHA/src/widget.py#L10-L20"
GHES_PIN_OTHER_REPO="https://$GHES_HOST/acme/gadgets/blob/$SHA_B/src/gadget.py#L1-L9"
GL_PIN="https://$GL_HOST/acme/platform/widgets/-/blob/$SHA/src/widget.py#L10-L20"
BBS_PIN="https://$BBS_HOST/projects/ACME/repos/widgets/browse/src/widget.py?at=$SHA"
BBC_PIN="https://$BBC_HOST/acme/widgets/src/$SHA/src/widget.py"
ADO_PIN="https://$ADO_HOST/acme/platform/_git/widgets?path=/src/widget.py&version=GC$SHA"
UNREG_PIN="https://$UNREG_HOST/acme/platform/widgets/-/blob/$SHA/src/widget.py#L10-L20"

# Citations that carry no 40-hex commit at their grammar's pin position.
GH_BRANCH="https://$GH_HOST/acme/widgets/blob/main/src/widget.py"
GH_SHORT="https://$GH_HOST/acme/widgets/blob/abc1234/src/widget.py"
GHES_BRANCH="https://$GHES_HOST/acme/widgets/blob/main/src/widget.py"
GHES_SHORT="https://$GHES_HOST/acme/widgets/blob/abc1234/src/widget.py"
GL_TREE_BRANCH="https://$GL_HOST/acme/platform/widgets/-/tree/main/src/widget.py"
GL_BLOB_BRANCH="https://$GL_HOST/acme/platform/widgets/-/blob/main/src/widget.py"
BBS_BRANCH="https://$BBS_HOST/projects/ACME/repos/widgets/browse/src/widget.py?at=refs/heads/main"
BBC_BRANCH="https://$BBC_HOST/acme/widgets/src/main/src/widget.py"
ADO_BRANCH="https://$ADO_HOST/acme/platform/_git/widgets?path=/src/widget.py&version=GBmain"

# write_source_paths <file> [source-url...]
# A schema-valid registry of git-managed sources. With no URLs the registry
# is present but registers nothing.
write_source_paths() {
  local file="$1"
  shift
  local url first=1 n=0
  {
    printf '{\n  "schema_version": 1,\n  "sources": [\n'
    for url in "$@"; do
      n=$((n + 1))
      if [ "$first" -eq 0 ]; then printf ',\n'; fi
      first=0
      printf '    {\n'
      printf '      "id": "fixture-source-%d",\n' "$n"
      printf '      "kind": "git-managed",\n'
      printf '      "url": "%s",\n' "$url"
      printf '      "status": "confirmed",\n'
      printf '      "archived": false,\n'
      printf '      "lifecycle": {"state": "reachable", "last_checked": "2026-09-03", '
      printf '"last_checked_sha": "%s", "proposed_url": null},\n' "$SHA"
      printf '      "discovered_via": null\n'
      printf '    }'
    done
    printf '\n  ]\n}\n'
  } > "$file"
}

# write_pinned_corpus <file> <citation-url>
# Five prose paragraphs, each immediately followed by one citation line —
# the shape a reference body has when every load-bearing claim carries an
# anchor. The paragraph count is five whether or not the citation is
# credited (an uncredited citation line simply joins the paragraph above
# it), so the denominator cannot move under the subject and only the
# covered count does.
write_pinned_corpus() {
  local file="$1" url="$2" i
  : > "$file"
  for i in 1 2 3 4 5; do
    cat >> "$file" <<EOF
Claim ${i} about the behavior this reference documents.
${url}

EOF
  done
}

# write_windowed_corpus <file> <citation-url>
# Same five claims, each citation sitting at the far edge of the five-line
# window rather than adjacent to its paragraph.
write_windowed_corpus() {
  local file="$1" url="$2" i
  : > "$file"
  for i in 1 2 3 4 5; do
    cat >> "$file" <<EOF
Claim ${i} about the behavior this reference documents.




${url}

EOF
  done
}

# write_far_corpus <references-dir> <citation-url>
# Five claims whose citations sit one line beyond the window. One claim per
# file, because a citation covers any paragraph within five lines of it in
# either direction — packed into one file, each citation would reach back
# over the blank run and cover the *next* claim.
write_far_corpus() {
  local dir="$1" url="$2" i
  for i in 1 2 3 4 5; do
    cat > "$dir/far-${i}.md" <<EOF
Claim ${i} about the behavior this reference documents.






${url}
EOF
  done
}

# write_unanchored_corpus <file> <paragraph-count>
write_unanchored_corpus() {
  local file="$1" count="$2" i
  : > "$file"
  for ((i = 1; i <= count; i++)); do
    cat >> "$file" <<EOF
Unanchored claim ${i}, narrative prose with nothing to check it against.

EOF
  done
}

# new_corpus_root <name> [source-url...]
# A corpus root: references/ plus, when any URL is given, a sibling
# research/source-paths.json registering it. Named by the caller, never
# renamed to look like an installed skill — the registration has to be
# found by where it sits, not by what the directory is called.
new_corpus_root() {
  local root="$WORK/$1"
  shift
  mkdir -p "$root/references"
  if [ "$#" -gt 0 ]; then
    mkdir -p "$root/research"
    write_source_paths "$root/research/source-paths.json" "$@"
  fi
  printf '%s' "$root"
}

# write_eval_ctx <ctx-root> <citation-url> [source-url...]
# A contextualizer root the citation-rate runner can grade: navigator,
# one reference, a three-prompt corpus, and a registry.
write_eval_ctx() {
  local ctx="$1" url="$2"
  shift 2
  mkdir -p "$ctx/references" "$ctx/research"
  cat > "$ctx/SKILL.md" <<'EOF'
---
name: widgets-context
description: Answers questions about the widgets ecosystem. Use when working with widget assembly, widget lifecycle, or widget migration.
---

# Widgets context navigator

Body content here.
EOF
  cat > "$ctx/references/alpha.md" <<'EOF'
# alpha

Reference body.
EOF
  cat > "$ctx/research/eval-prompts.json" <<'EOF'
{
  "schema_version": 1,
  "prompts": [
    {"id": "n01", "category": "needs_reference", "text": "Q1: what is Alpha's import path?"},
    {"id": "n02", "category": "needs_reference", "text": "Q2: list the v1 to v2 migration steps."},
    {"id": "n03", "category": "needs_reference", "text": "Q3: signature of Gamma's interface."}
  ]
}
EOF
  if [ "$#" -gt 0 ]; then
    write_source_paths "$ctx/research/source-paths.json" "$@"
  fi
  write_mock_file "$ctx/mocks.json" "$url"
}

# write_mock_file <file> <citation-url> [citation-url-2] [citation-url-3]
# Three prompt records of three runs each — the run count the grader
# requires — every run opening a reference and citing the given URL.
write_mock_file() {
  local file="$1" u1="$2" u2="${3:-$2}" u3="${4:-$2}"
  local url r first=1
  {
    printf '{\n  "records": [\n'
    for url in "$u1" "$u2" "$u3"; do
      if [ "$first" -eq 0 ]; then printf ',\n'; fi
      first=0
      printf '    {"runs": ['
      for r in 1 2 3; do
        if [ "$r" -ne 1 ]; then printf ', '; fi
        printf '{"references_opened": ["alpha.md"], "turns_used": 1, '
        printf '"final_response_text": "The definition is at %s in the widgets tree.", ' "$url"
        printf '"input_tokens": 1200, "output_tokens": 60}'
      done
      printf ']}'
    done
    printf '\n  ]\n}\n'
  } > "$file"
}

# ----- a permalink in a registered forge's grammar covers its paragraph ---

# The grammar a source's own forge serves is the grammar its permalinks are
# written in. A contextualizer that registers a git-managed source on a
# host gets its paragraphs credited when they cite that host in that host's
# grammar — the same five-line window, the same threshold, the same report.

root="$(new_corpus_root a01-ghes "$GHES_SRC")"
write_pinned_corpus "$root/references/ghes.md" "$GHES_PIN"
assert_density "github-family grammar: /blob/<40hex>/ on a registered host covers its paragraph" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (5/5 paragraphs)" "$root/references"

# Registration names a host, not a repository: a second repository on the
# same registered host is the same forge and is credited the same way.
root="$(new_corpus_root a02-ghes-other-repo "$GHES_SRC")"
write_pinned_corpus "$root/references/ghes.md" "$GHES_PIN_OTHER_REPO"
assert_density "github-family grammar: credit is host-level, so another repository on the registered host also covers" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (5/5 paragraphs)" "$root/references"

root="$(new_corpus_root a03-gitlab "$GL_SRC")"
write_pinned_corpus "$root/references/gitlab.md" "$GL_PIN"
assert_density "gitlab grammar: /-/blob/<40hex>/ on a registered host covers its paragraph" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (5/5 paragraphs)" "$root/references"

# The window is the one that already exists: five lines, not a wider one
# opened up for the new grammars.
root="$(new_corpus_root a04-gitlab-window "$GL_SRC")"
write_windowed_corpus "$root/references/gitlab.md" "$GL_PIN"
assert_density "gitlab grammar: a citation at the far edge of the five-line window still covers" \
  0 "[PASS] permalink-density: corpus coverage 100.0%" "$root/references"

root="$(new_corpus_root a05-bitbucket-server "$BBS_SRC")"
write_pinned_corpus "$root/references/bitbucket.md" "$BBS_PIN"
assert_density "bitbucket server grammar: browse/<path>?at=<40hex> on a registered host covers its paragraph" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (5/5 paragraphs)" "$root/references"

root="$(new_corpus_root a06-bitbucket-cloud "$BBC_SRC")"
write_pinned_corpus "$root/references/bitbucket.md" "$BBC_PIN"
assert_density "bitbucket cloud grammar: /src/<40hex>/<path> on a registered host covers its paragraph" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (5/5 paragraphs)" "$root/references"

root="$(new_corpus_root a07-azure-devops "$ADO_SRC")"
write_pinned_corpus "$root/references/azure.md" "$ADO_PIN"
assert_density "azure devops grammar: _git/<repo>?path=&version=GC<40hex> on a registered host covers its paragraph" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (5/5 paragraphs)" "$root/references"

# Five references differing only in host and grammar score alike, in one
# corpus, against one registry.
root="$(new_corpus_root a08-all-forges "$GHES_SRC" "$GL_SRC" "$BBS_SRC" "$BBC_SRC" "$ADO_SRC")"
write_pinned_corpus "$root/references/one-ghes.md" "$GHES_PIN"
write_pinned_corpus "$root/references/two-gitlab.md" "$GL_PIN"
write_pinned_corpus "$root/references/three-bitbucket-server.md" "$BBS_PIN"
write_pinned_corpus "$root/references/four-bitbucket-cloud.md" "$BBC_PIN"
write_pinned_corpus "$root/references/five-azure-devops.md" "$ADO_PIN"
assert_density "five grammars on five registered hosts: every file in the corpus is covered" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (25/25 paragraphs)" "$root/references"

# The registry is found beside the references directory, whatever that
# directory's parent is called. The density report a proposal run prints is
# computed over an ephemeral merged view whose directory name is a tempdir
# name, so keying acceptance off a "-context" suffix would leave that
# surface reporting zero.
root="$(new_corpus_root "merged-view-7f3a2b" "$GL_SRC")"
write_pinned_corpus "$root/references/gitlab.md" "$GL_PIN"
assert_density "registration beside references/: an arbitrarily named corpus root is still credited" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (5/5 paragraphs)" "$root/references"

# ----- unpinned rejected -------------------------------------------------

# The pin is the 40-hex commit; the only accepted alternative is a stable
# tag. A URL whose grammar is right but whose pin position holds a branch
# name or a short SHA is a rotting pointer, and widening the set of hosts
# must not widen the set of pins. Each grammar has its own pin position,
# so each has its own way of being unpinned.

root="$(new_corpus_root b01-gh-branch "$GH_SRC")"
write_pinned_corpus "$root/references/gh.md" "$GH_BRANCH"
assert_density "unpinned rejected: github.com /blob/main/ is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

root="$(new_corpus_root b02-gh-short "$GH_SRC")"
write_pinned_corpus "$root/references/gh.md" "$GH_SHORT"
assert_density "unpinned rejected: github.com short SHA is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

root="$(new_corpus_root b03-ghes-branch "$GHES_SRC")"
write_pinned_corpus "$root/references/ghes.md" "$GHES_BRANCH"
assert_density "unpinned rejected: /blob/main/ on a registered host is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

root="$(new_corpus_root b04-ghes-short "$GHES_SRC")"
write_pinned_corpus "$root/references/ghes.md" "$GHES_SHORT"
assert_density "unpinned rejected: a short SHA on a registered host is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

root="$(new_corpus_root b05-gl-tree "$GL_SRC")"
write_pinned_corpus "$root/references/gitlab.md" "$GL_TREE_BRANCH"
assert_density "unpinned rejected: gitlab /-/tree/main/ on a registered host is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

root="$(new_corpus_root b06-gl-blob "$GL_SRC")"
write_pinned_corpus "$root/references/gitlab.md" "$GL_BLOB_BRANCH"
assert_density "unpinned rejected: gitlab /-/blob/main/ on a registered host is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

root="$(new_corpus_root b07-bbs-branch "$BBS_SRC")"
write_pinned_corpus "$root/references/bitbucket.md" "$BBS_BRANCH"
assert_density "unpinned rejected: bitbucket server ?at=refs/heads/main is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

root="$(new_corpus_root b08-bbc-branch "$BBC_SRC")"
write_pinned_corpus "$root/references/bitbucket.md" "$BBC_BRANCH"
assert_density "unpinned rejected: bitbucket cloud /src/main/ is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

root="$(new_corpus_root b09-ado-branch "$ADO_SRC")"
write_pinned_corpus "$root/references/azure.md" "$ADO_BRANCH"
assert_density "unpinned rejected: azure devops version=GBmain is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

# ----- unregistered host -------------------------------------------------

# Acceptance is derived from what the contextualizer registers. A valid
# grammar on a host nobody registered is somebody else's forge, and
# crediting it would make the whole check gradeable on any URL that merely
# looks the part.

root="$(new_corpus_root c01-unregistered "$GL_SRC")"
write_pinned_corpus "$root/references/other.md" "$UNREG_PIN"
assert_density "unregistered host: a valid gitlab-grammar permalink on an unregistered host is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

root="$(new_corpus_root c02-empty-registry)"
mkdir -p "$root/research"
write_source_paths "$root/research/source-paths.json"
write_pinned_corpus "$root/references/gh.md" "$GH_PIN"
assert_density "unregistered host: a registry that registers nothing still credits github.com" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (5/5 paragraphs)" "$root/references"

root="$(new_corpus_root c03-empty-registry-other)"
mkdir -p "$root/research"
write_source_paths "$root/research/source-paths.json"
write_pinned_corpus "$root/references/gitlab.md" "$GL_PIN"
assert_density "unregistered host: a registry that registers nothing credits no other host" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

# ----- bare corpus fallback ----------------------------------------------

# The lint is a standalone CLI over a directory of markdown. Handed a bare
# corpus with no contextualizer around it — no registry to derive anything
# from — it falls back to github.com and to github.com alone. That is the
# invocation the sibling density runner makes on every run, so this
# fallback is load-bearing for the suite itself.

root="$(new_corpus_root d01-bare-github)"
write_pinned_corpus "$root/references/gh.md" "$GH_PIN"
assert_density "bare corpus fallback: github.com is credited with no registry in sight" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (5/5 paragraphs)" "$root/references"

root="$(new_corpus_root d02-bare-ghes)"
write_pinned_corpus "$root/references/ghes.md" "$GHES_PIN"
assert_density "bare corpus fallback: a github-family permalink on another host is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

root="$(new_corpus_root d03-bare-gitlab)"
write_pinned_corpus "$root/references/gitlab.md" "$GL_PIN"
assert_density "bare corpus fallback: a gitlab permalink is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

root="$(new_corpus_root d04-bare-bbs)"
write_pinned_corpus "$root/references/bitbucket.md" "$BBS_PIN"
assert_density "bare corpus fallback: a bitbucket server permalink is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

root="$(new_corpus_root d05-bare-bbc)"
write_pinned_corpus "$root/references/bitbucket.md" "$BBC_PIN"
assert_density "bare corpus fallback: a bitbucket cloud permalink is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

root="$(new_corpus_root d06-bare-ado)"
write_pinned_corpus "$root/references/azure.md" "$ADO_PIN"
assert_density "bare corpus fallback: an azure devops permalink is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

# ----- github.com preserved ----------------------------------------------

# The bundled example corpora are the callers that exist today: a CI suite,
# a review step that parses the percentage, and a proposal-run report line.
# Their numbers are compared against a recomputation by the lint as it
# stood before this work, so the comparison stays honest when the corpora
# change.

baseline_script=""
baseline_origin=""
if command -v git >/dev/null 2>&1 \
  && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  && git -C "$REPO_ROOT" cat-file -e "$BASELINE_SHA:$BASELINE_REPO_PATH" 2>/dev/null; then
  baseline_script="$WORK/baseline-from-history.py"
  git -C "$REPO_ROOT" show "$BASELINE_SHA:$BASELINE_REPO_PATH" > "$baseline_script" 2>/dev/null
  baseline_origin="history"
elif [ -f "$BASELINE_VENDORED" ]; then
  baseline_script="$BASELINE_VENDORED"
  baseline_origin="vendored"
fi

if [ "$baseline_origin" = "history" ]; then
  if cmp -s "$baseline_script" "$BASELINE_VENDORED"; then
    pass_case "github.com preserved: the vendored baseline is byte-identical to the pinned commit"
  else
    fail_case "github.com preserved: the vendored baseline is byte-identical to the pinned commit" \
      "the vendored copy has drifted from the commit it stands in for; re-capture it"
  fi
elif [ "$baseline_origin" = "vendored" ]; then
  skip_case "github.com preserved: the vendored baseline is byte-identical to the pinned commit" \
    "the pinned commit is not in this checkout (shallow clone, no git, or rewritten history); the vendored copy is in use unverified"
else
  fail_case "github.com preserved: a baseline copy of the lint is available" \
    "neither the pinned commit nor the vendored copy could be read; the preservation comparison cannot run"
fi

if [ -n "$baseline_origin" ]; then
  examples_seen=0
  for example_refs in "$REPO_ROOT"/examples/*/references; do
    [ -d "$example_refs" ] || continue
    examples_seen=$((examples_seen + 1))
    example_name="$(basename "$(dirname "$example_refs")")"
    base_out="$(python3 "$baseline_script" "$example_refs" --min-paragraphs 5 --require-min-paragraphs 2>&1)" \
      && base_rc=0 || base_rc=$?
    cur_out="$(python3 "$LINT" "$example_refs" --min-paragraphs 5 --require-min-paragraphs 2>&1)" \
      && cur_rc=0 || cur_rc=$?
    base_sig="$(report_signature "$base_out")"
    cur_sig="$(report_signature "$cur_out")"
    case "$base_sig" in
      "|"* | *"|")
        fail_case "github.com preserved: $example_name reports a verdict and a percentage" \
          "$(printf 'the baseline report had no verdict/percentage to compare:\n%s' "$base_out")"
        ;;
      *)
        if [ "$base_rc" -eq "$cur_rc" ] && [ "$base_sig" = "$cur_sig" ]; then
          pass_case "github.com preserved: $example_name reports the baseline verdict and percentage ($cur_sig)"
        else
          fail_case "github.com preserved: $example_name reports the baseline verdict and percentage" \
            "$(printf 'baseline rc=%d sig=%s\ncurrent  rc=%d sig=%s\n\nbaseline report:\n%s\n\ncurrent report:\n%s' \
              "$base_rc" "$base_sig" "$cur_rc" "$cur_sig" "$base_out" "$cur_out")"
        fi
        ;;
    esac
  done
  if [ "$examples_seen" -eq 0 ]; then
    fail_case "github.com preserved: the bundled example corpora are present" \
      "no examples/*/references directory found under $REPO_ROOT"
  fi
fi

# A stable version tag is the one accepted alternative to a commit SHA.
root="$(new_corpus_root e01-tag-pinned "$GH_SRC")"
write_pinned_corpus "$root/references/gh.md" "$GH_TAG_PIN"
assert_density "github.com preserved: a tag-pinned permalink is still credited" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (5/5 paragraphs)" "$root/references"

# tree/<40hex> is credited on github.com today and corpora rely on it.
root="$(new_corpus_root e02-tree-pinned "$GH_SRC")"
write_pinned_corpus "$root/references/gh.md" "$GH_TREE_PIN"
assert_density "github.com preserved: a /tree/<40hex>/ permalink is still credited" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (5/5 paragraphs)" "$root/references"

# The window is not widened for the host that already worked either.
root="$(new_corpus_root e03-far "$GH_SRC")"
write_far_corpus "$root/references" "$GH_PIN"
assert_density "github.com preserved: a citation beyond the five-line window still does not cover" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" "$root/references"

# ----- cli shape preserved -----------------------------------------------

# Five call sites invoke this CLI with the argument forms below and read
# the verdict, the percentage, or the exit code out of what comes back.
# None of them can be handed a new flag without being edited, so the
# argument surface and the report lines have to stay exactly as they are.

root="$(new_corpus_root f01-no-flags "$GH_SRC")"
write_pinned_corpus "$root/references/gh.md" "$GH_PIN"
assert_density "cli shape preserved: invoked with no flags at all, the PASS line keeps its wording" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (5/5 paragraphs) ≥80% threshold" "$root/references"

root="$(new_corpus_root f02-thin "$GH_SRC")"
write_unanchored_corpus "$root/references/thin.md" 2
assert_density "cli shape preserved: a corpus under the paragraph floor is N/A and exits 0" \
  0 "[N/A] permalink-density: only 2 paragraphs in scope (need ≥5 for a meaningful ratio)" \
  "$root/references" --min-paragraphs 5

root="$(new_corpus_root f03-thin-required "$GH_SRC")"
write_unanchored_corpus "$root/references/thin.md" 2
assert_density "cli shape preserved: --require-min-paragraphs turns that same corpus into a failure" \
  1 "[FAIL] permalink-density: only 2 paragraphs in scope" \
  "$root/references" --min-paragraphs 5 --require-min-paragraphs

root="$(new_corpus_root f04-missing "$GH_SRC")"
assert_density "cli shape preserved: a references directory that does not exist is N/A and exits 0" \
  0 "[N/A] permalink-density: no references emitted yet" "$root/references/not-emitted-yet"

root="$(new_corpus_root f05-empty "$GH_SRC")"
assert_density "cli shape preserved: an empty references directory is N/A and exits 0" \
  0 "[N/A] permalink-density: no references emitted yet" "$root/references"

# A corpus at 60% coverage: three anchored claims in one file, two
# unanchored in another. The threshold decides the verdict and nothing else
# about the run changes.
root="$(new_corpus_root f06-threshold "$GH_SRC")"
: > "$root/references/covered.md"
for i in 1 2 3; do
  cat >> "$root/references/covered.md" <<EOF
Claim ${i} about the behavior this reference documents.
${GH_PIN}

EOF
done
write_unanchored_corpus "$root/references/uncovered.md" 2
assert_density "cli shape preserved: --threshold below the measured rate passes with the rate reported" \
  0 "[PASS] permalink-density: corpus coverage 60.0% (3/5 paragraphs) ≥50% threshold" \
  "$root/references" --threshold 0.50
assert_density "cli shape preserved: the default threshold fails that same corpus, at the same rate" \
  1 "[FAIL] permalink-density: corpus coverage 60.0% (3/5 paragraphs) below 80% threshold" \
  "$root/references"
assert_density "cli shape preserved: the failure report still names the sub-threshold file and its paragraphs" \
  1 "references/uncovered.md: 0.0% (0/2 paragraphs covered)" "$root/references"
assert_density "cli shape preserved: the failure report still names each uncovered paragraph by line" \
  1 "L1: Unanchored claim 1," "$root/references"

# ----- staged proposal ---------------------------------------------------

# A proposal is staged in a sibling directory that mirrors the live skill
# and is a sparse copy-on-write, so which files it holds varies per run.
# The percentage the review step reports over that staged tree must not
# depend on whether this particular run happened to rewrite the registry.

staged_root="$WORK/g01-install"
mkdir -p "$staged_root/acme-context/references" "$staged_root/acme-context/research"
mkdir -p "$staged_root/acme-context.proposed/references"
write_source_paths "$staged_root/acme-context/research/source-paths.json" "$GL_SRC"
write_pinned_corpus "$staged_root/acme-context/references/gitlab.md" "$GL_PIN"
write_pinned_corpus "$staged_root/acme-context.proposed/references/gitlab.md" "$GL_PIN"
assert_density "staged proposal: with no registry of its own, the staged tree is credited by the live skill beside it" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (5/5 paragraphs)" \
  "$staged_root/acme-context.proposed/references"
g01_out="$(python3 "$LINT" "$staged_root/acme-context.proposed/references" 2>&1)"
g01_sig="$(report_signature "$g01_out")"

# The same staged corpus, this time in a run that did copy the registry
# forward. Same corpus, same registered host, same number.
staged_root="$WORK/g02-install"
mkdir -p "$staged_root/acme-context/references" "$staged_root/acme-context/research"
mkdir -p "$staged_root/acme-context.proposed/references" "$staged_root/acme-context.proposed/research"
write_source_paths "$staged_root/acme-context/research/source-paths.json" "$GL_SRC"
write_source_paths "$staged_root/acme-context.proposed/research/source-paths.json" "$GL_SRC"
write_pinned_corpus "$staged_root/acme-context/references/gitlab.md" "$GL_PIN"
write_pinned_corpus "$staged_root/acme-context.proposed/references/gitlab.md" "$GL_PIN"
assert_density "staged proposal: with a registry of its own, the staged tree reports the same result" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (5/5 paragraphs)" \
  "$staged_root/acme-context.proposed/references"
g02_out="$(python3 "$LINT" "$staged_root/acme-context.proposed/references" 2>&1)"
g02_sig="$(report_signature "$g02_out")"

if [ "$g01_sig" = "$g02_sig" ]; then
  pass_case "staged proposal: the percentage does not depend on whether the run rewrote the registry ($g01_sig)"
else
  fail_case "staged proposal: the percentage does not depend on whether the run rewrote the registry" \
    "$(printf 'no staged registry: %s\nstaged registry:    %s\n\nfirst report:\n%s\n\nsecond report:\n%s' \
      "$g01_sig" "$g02_sig" "$g01_out" "$g02_out")"
fi

# A companion proposed on a new host is creditable before it is promoted:
# the staged registry is the one that will become live, so it is the one
# that governs the staged corpus.
staged_root="$WORK/g03-install"
mkdir -p "$staged_root/acme-context/references" "$staged_root/acme-context/research"
mkdir -p "$staged_root/acme-context.proposed/references" "$staged_root/acme-context.proposed/research"
write_source_paths "$staged_root/acme-context/research/source-paths.json" "$GL_SRC"
write_source_paths "$staged_root/acme-context.proposed/research/source-paths.json" "$BBS_SRC"
write_pinned_corpus "$staged_root/acme-context.proposed/references/bitbucket.md" "$BBS_PIN"
assert_density "staged proposal: a host registered only in the staged tree is credited before promotion" \
  0 "[PASS] permalink-density: corpus coverage 100.0% (5/5 paragraphs)" \
  "$staged_root/acme-context.proposed/references"

# The other side of the same rule: when the staged tree carries a registry,
# that registry governs, so a host the live skill still registers and the
# staged one has dropped is not credited in the staged corpus.
staged_root="$WORK/g04-install"
mkdir -p "$staged_root/acme-context/references" "$staged_root/acme-context/research"
mkdir -p "$staged_root/acme-context.proposed/references" "$staged_root/acme-context.proposed/research"
write_source_paths "$staged_root/acme-context/research/source-paths.json" "$GL_SRC"
write_source_paths "$staged_root/acme-context.proposed/research/source-paths.json" "$BBS_SRC"
write_pinned_corpus "$staged_root/acme-context.proposed/references/gitlab.md" "$GL_PIN"
assert_density "staged proposal: the staged registry governs, so a host only the live skill registers is not credited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" \
  "$staged_root/acme-context.proposed/references"

# Widening where a registration is found never widens what counts as
# registered.
staged_root="$WORK/g05-install"
mkdir -p "$staged_root/acme-context/references" "$staged_root/acme-context/research"
mkdir -p "$staged_root/acme-context.proposed/references" "$staged_root/acme-context.proposed/research"
write_source_paths "$staged_root/acme-context/research/source-paths.json" "$GL_SRC"
write_source_paths "$staged_root/acme-context.proposed/research/source-paths.json" "$BBS_SRC"
write_pinned_corpus "$staged_root/acme-context.proposed/references/other.md" "$UNREG_PIN"
assert_density "staged proposal: a host registered in neither tree stays uncredited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" \
  "$staged_root/acme-context.proposed/references"

staged_root="$WORK/g06-install"
mkdir -p "$staged_root/acme-context/references" "$staged_root/acme-context/research"
mkdir -p "$staged_root/acme-context.proposed/references"
write_source_paths "$staged_root/acme-context/research/source-paths.json" "$GL_SRC"
write_pinned_corpus "$staged_root/acme-context.proposed/references/other.md" "$UNREG_PIN"
assert_density "staged proposal: with no staged registry, a host the live skill does not register stays uncredited" \
  1 "[FAIL] permalink-density: corpus coverage 0.0% (0/5 paragraphs)" \
  "$staged_root/acme-context.proposed/references"

# ----- grounded-rate inherits the grammar --------------------------------

# The citation-rate grader asks whether the model emitted a pinned
# permalink when it answered. It reads the same grammar as the density
# lint, so a tenant whose references are creditable and whose answers cite
# the same forge is graded grounded rather than failed for citing the forge
# it was given. Mocked responses only — no key, no network.

ctx="$WORK/h01-ghes"
write_eval_ctx "$ctx" "$GHES_PIN" "$GHES_SRC"
assert_grounded "grounded-rate: a github-family citation on a registered host is graded grounded" \
  0 "[PASS] grounded-rate: 100.0% (3/3 prompts grounded)" "$ctx" --mock-responses "$ctx/mocks.json"

ctx="$WORK/h02-gitlab"
write_eval_ctx "$ctx" "$GL_PIN" "$GL_SRC"
assert_grounded "grounded-rate: a gitlab citation on a registered host is graded grounded" \
  0 "[PASS] grounded-rate: 100.0% (3/3 prompts grounded)" "$ctx" --mock-responses "$ctx/mocks.json"

ctx="$WORK/h03-bbs"
write_eval_ctx "$ctx" "$BBS_PIN" "$BBS_SRC"
assert_grounded "grounded-rate: a bitbucket server citation on a registered host is graded grounded" \
  0 "[PASS] grounded-rate: 100.0% (3/3 prompts grounded)" "$ctx" --mock-responses "$ctx/mocks.json"

ctx="$WORK/h04-bbc"
write_eval_ctx "$ctx" "$BBC_PIN" "$BBC_SRC"
assert_grounded "grounded-rate: a bitbucket cloud citation on a registered host is graded grounded" \
  0 "[PASS] grounded-rate: 100.0% (3/3 prompts grounded)" "$ctx" --mock-responses "$ctx/mocks.json"

ctx="$WORK/h05-ado"
write_eval_ctx "$ctx" "$ADO_PIN" "$ADO_SRC"
assert_grounded "grounded-rate: an azure devops citation on a registered host is graded grounded" \
  0 "[PASS] grounded-rate: 100.0% (3/3 prompts grounded)" "$ctx" --mock-responses "$ctx/mocks.json"

ctx="$WORK/h06-gitlab-unpinned"
write_eval_ctx "$ctx" "$GL_TREE_BRANCH" "$GL_SRC"
assert_grounded "grounded-rate: an unpinned citation on a registered host is not grounded" \
  1 "[FAIL] grounded-rate: 0.0% (0/3 prompts grounded)" "$ctx" --mock-responses "$ctx/mocks.json"
assert_grounded "grounded-rate: an unpinned citation is reported as a missing permalink, not a missing reference" \
  1 "[no-permalink-in-response]" "$ctx" --mock-responses "$ctx/mocks.json"

ctx="$WORK/h07-unregistered"
write_eval_ctx "$ctx" "$UNREG_PIN" "$GL_SRC"
assert_grounded "grounded-rate: a pinned citation on an unregistered host is not grounded" \
  1 "[FAIL] grounded-rate: 0.0% (0/3 prompts grounded)" "$ctx" --mock-responses "$ctx/mocks.json"

ctx="$WORK/h08-github"
write_eval_ctx "$ctx" "$GH_PIN" "$GH_SRC"
write_mock_file "$ctx/mocks.json" "$GH_PIN" "$GH_TAG_PIN" "$GH_PIN"
assert_grounded "grounded-rate: github.com SHA-pinned and tag-pinned citations are still grounded" \
  0 "[PASS] grounded-rate: 100.0% (3/3 prompts grounded)" "$ctx" --mock-responses "$ctx/mocks.json"

ctx="$WORK/h09-github-unpinned"
write_eval_ctx "$ctx" "$GH_BRANCH" "$GH_SRC"
assert_grounded "grounded-rate: a github.com branch-pinned citation is still not grounded" \
  1 "[no-permalink-in-response]" "$ctx" --mock-responses "$ctx/mocks.json"

# The bar the two coverage gates apply is one shared constant, and the call
# sites that omit --threshold are relying on that: they retune together or
# not at all. Omitting the flag has to keep reading it.
ctx="$WORK/h11-default-threshold"
write_eval_ctx "$ctx" "$GH_PIN" "$GH_SRC"
write_mock_file "$ctx/mocks.json" "$GH_PIN" "$GH_PIN" "$GH_BRANCH"
default_out="$(python3 "$GROUNDED" "$ctx" --mock-responses "$ctx/mocks.json" 2>&1)" \
  && default_rc=0 || default_rc=$?
default_norm="$(normalize "$default_out")"
default_expect="[FAIL] grounded-rate: 66.7% (2/3 prompts grounded) below 80% threshold"
if [ "$default_rc" -eq 1 ] && printf '%s' "$default_norm" | grep -qF -- "$default_expect"; then
  pass_case "grounded-rate: with no --threshold, the shared default bar is still the one applied"
else
  fail_case "grounded-rate: with no --threshold, the shared default bar is still the one applied" \
    "$(printf 'expected rc=1 and substring: %s\ngot rc=%d:\n%s' \
      "$default_expect" "$default_rc" "$default_out")"
fi

# The keyless schema gate the local CI suite runs over every bundled
# context root is untouched by any of this.
ctx="$WORK/h10-dry-run"
write_eval_ctx "$ctx" "$GL_PIN" "$GL_SRC"
assert_grounded "grounded-rate: the keyless corpus dry-run keeps its output and exit code" \
  0 "[DRY-RUN] grounded-rate: 3 prompt(s) parsed" "$ctx" --dry-run

# ----- summary -----------------------------------------------------------

echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
if [ "$skip_count" -gt 0 ]; then
  echo "Skipped: $skip_count"
fi
[ "$fail_count" -eq 0 ]
