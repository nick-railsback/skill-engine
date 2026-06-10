#!/usr/bin/env bash
# Doctrine-enforcement grep checks. Cheap, brittle to renames, but
# explicit. Each check pins a deliberate non-feature: a capability the
# engine refuses to ship. The per-check comment below states the doctrine
# in self-contained form; failure means an engine file has silently
# adopted the forbidden pattern.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fail=0

# 1. No html-to-markdown library bundled.
# Doctrine: the engine does not bundle any HTML-to-Markdown converter.
# Markdown conversion is the model's responsibility (WebFetch / MCP fetch
# return markdown directly). Bundling a converter would impose a build/
# runtime dependency on every contextualizer and conflict with the
# "engine does not perform HTTP itself" stance below.
if grep -rE 'turndown|pandoc|html2markdown|readability|cheerio' \
   "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/engine-bootstrap-templates" \
   --include='*.sh' --include='*.md' 2>/dev/null \
   | grep -v -F "$PLUGIN_ROOT/tests/doctrine.sh"; then
  echo "FAIL: html-to-markdown library reference found in engine code."
  fail=1
fi

# 2. Engine code does not perform HTTP GETs itself.
# Doctrine: only the model (via WebFetch or MCP fetch) performs content
# fetches. Engine shell scripts may use `git`, `gh`, and `curl --head`
# (HEAD probes for reachability) only. A non-HEAD curl in any
# engine-bootstrap-templates/*.sh would mean the engine is silently
# taking on the fetch role.
if grep -rE '\bcurl\s+[^-]' "$PLUGIN_ROOT/engine-bootstrap-templates" \
   --include='*.sh' 2>/dev/null \
   | grep -v 'curl --head\|curl -I'; then
  echo "FAIL: non-HEAD curl invocation in engine shell scripts."
  fail=1
fi

# 3. Engine code does not handle auth tokens.
# Doctrine: the engine does not plumb auth tokens. Reachability against
# private upstreams is the user's environment's responsibility (their
# git/gh config). Any `Authorization: Bearer ...` or `GITHUB_TOKEN`
# reference in engine shell scripts would mean the engine is silently
# taking on auth.
if grep -rE 'BEARER|Authorization:\s*Bearer|GITHUB_TOKEN' \
   "$PLUGIN_ROOT/engine-bootstrap-templates" \
   --include='*.sh' 2>/dev/null; then
  echo "FAIL: auth-token plumbing detected in engine shell scripts."
  fail=1
fi

# 4. Engine code does not invoke mutating git verbs.
# Doctrine: locked decision #1 — the engine performs no git mutations against
# any repository the user owns. Read-only verbs against the user's repo plus
# engine-controlled clones in ~/.cache/skill-engine/ (created by the engine,
# not the user) are permitted. Allow-list is closed; any verb not listed
# fails the check. Open by structure (a lint), not by convention.
#
# Allow-list:
#   diff, status, log, show, clone, ls-remote, ls-tree, ls-files,
#   rev-parse, cat-file
#
# Scope:
#   plugin/skill-engine/skills/**/*.md
#   plugin/skill-engine/agents/*.md
#   plugin/skill-engine/bin/*.sh
#   plugin/skill-engine/tests/*.sh        (this file is implicitly excluded
#                                          via the path-equality check below)
#   plugin/skill-engine/engine-bootstrap-templates/*  (every file, except
#                                          the two excluded templates that
#                                          legitimately carry user-side
#                                          mutating verbs)
#
# Excluded files — these stamp into the user's own release
# workflow and pre-commit hook; their `git add` / `git commit` / `git push` /
# `git describe` invocations are the user's commits, not the engine's:
#   engine-bootstrap-templates/release-command.md.template
#   engine-bootstrap-templates/pre-commit.sh.template
#
# Prose-mention guard: matches inside HTML comments (<!-- ... -->) and inside
# Markdown code spans (`...`) are stripped per-line before verb extraction so
# narration like "the engine does not `git add`" does not trip the lint.
git_readonly_scan() {
  local f rel
  local -a scan_files=()
  # Collect (and exclude) first, then hand the whole set to a single awk
  # invocation. The previous form forked one awk per file — dozens of process
  # spawns per CI run across skills/ + agents/ + bin/ + tests/ + templates/.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$f" = "$SCRIPT_DIR/doctrine.sh" ] && continue
    rel="${f#"$PLUGIN_ROOT/"}"
    case "$rel" in
      engine-bootstrap-templates/release-command.md.template) continue ;;
      engine-bootstrap-templates/pre-commit.sh.template) continue ;;
    esac
    scan_files+=("$f")
  done
  [ "${#scan_files[@]}" -eq 0 ] && return 0
  # FNR (per-file line number) and FILENAME give the same file:line prefix the
  # per-file form produced; rel is derived by stripping the literal PLUGIN_ROOT
  # prefix via substr (length-based, so a metachar in the path can't matter).
  awk -v root="$PLUGIN_ROOT/" '
    FNR == 1 { rel = substr(FILENAME, length(root) + 1) }
    {
      line = $0
      # Strip single-line HTML comments.
      gsub(/<!--[^>]*-->/, "", line)
      # Strip Markdown code spans (paired backticks on the same line).
      gsub(/`[^`]*`/, "", line)
      # Extract executable git verbs. \<git\> + whitespace + lowercase verb.
      while (match(line, /(^|[[:space:]]|[(;&|])git[[:space:]]+[a-z][a-z-]*/)) {
        token = substr(line, RSTART, RLENGTH)
        sub(/.*git[[:space:]]+/, "", token)
        print rel ":" FNR ":" token
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "${scan_files[@]}"
}

# Known git verbs filter: the candidate-match `git <token>` is only a real
# git invocation when <token> is a recognized git subcommand. Without this
# filter, prose noun phrases like "no git mutations" or "a git host URL"
# trip the lint. The union below is allow-list ∪ deny-list (AC5.2 ∪ AC5.3)
# plus a few additional known verbs seen in docs / templates.
readonly_violations=$(
  {
    find "$PLUGIN_ROOT/skills" -type f -name '*.md' 2>/dev/null
    find "$PLUGIN_ROOT/agents" -type f -name '*.md' 2>/dev/null
    find "$PLUGIN_ROOT/bin" -type f -name '*.sh' 2>/dev/null
    find "$PLUGIN_ROOT/tests" -type f -name '*.sh' 2>/dev/null
    find "$PLUGIN_ROOT/engine-bootstrap-templates" -type f 2>/dev/null
  } | git_readonly_scan | awk -F: '
    BEGIN {
      # Allow-list (AC5.2): read-only relative to user repo state.
      allow["diff"]=1; allow["status"]=1; allow["log"]=1; allow["show"]=1
      allow["clone"]=1; allow["ls-remote"]=1; allow["ls-tree"]=1
      allow["ls-files"]=1; allow["rev-parse"]=1; allow["cat-file"]=1
      # Known real git verbs (allow ∪ deny). Anything not in this set is
      # treated as a non-verb (prose) match and ignored.
      verbs["diff"]=1; verbs["status"]=1; verbs["log"]=1; verbs["show"]=1
      verbs["clone"]=1; verbs["ls-remote"]=1; verbs["ls-tree"]=1
      verbs["ls-files"]=1; verbs["rev-parse"]=1; verbs["cat-file"]=1
      verbs["push"]=1; verbs["commit"]=1; verbs["tag"]=1; verbs["init"]=1
      verbs["add"]=1; verbs["rm"]=1; verbs["mv"]=1; verbs["restore"]=1
      verbs["reset"]=1; verbs["checkout"]=1; verbs["switch"]=1
      verbs["merge"]=1; verbs["rebase"]=1; verbs["cherry-pick"]=1
      verbs["revert"]=1; verbs["stash"]=1; verbs["apply"]=1; verbs["am"]=1
      verbs["pull"]=1; verbs["fetch"]=1; verbs["gc"]=1; verbs["clean"]=1
      verbs["prune"]=1; verbs["worktree"]=1; verbs["submodule"]=1
      verbs["config"]=1; verbs["notes"]=1; verbs["bisect"]=1
      verbs["sparse-checkout"]=1; verbs["describe"]=1; verbs["blame"]=1
      verbs["archive"]=1; verbs["format-patch"]=1; verbs["request-pull"]=1
      verbs["grep"]=1; verbs["branch"]=1; verbs["remote"]=1
    }
    { if (($3 in verbs) && !($3 in allow)) print }
  '
)

if [ -n "$readonly_violations" ]; then
  echo "FAIL: engine code invokes git verbs outside the read-only allow-list."
  echo "$readonly_violations" | awk -F: '{
    printf "  %s:%s  git %s\n", $1, $2, $3
  }'
  echo "  Allow-list: diff, status, log, show, clone, ls-remote, ls-tree, ls-files, rev-parse, cat-file."
  fail=1
fi

# 5. No "disable the sandbox" guidance anywhere in engine skills or docs.
# Doctrine: when a write under .claude/skills/** is blocked, the engine
# routes the user to the NARROW fix (a scoped sandbox.filesystem.allowWrite
# entry, or removing the deny), never the BROAD one (disabling the sandbox).
# The engine must never tell a user to lower a machine-wide defense to use it.
#
# Scope: skills/ AND docs/ (*.md). The canonical sandbox-block diagnostic
# lives in docs/04-delivery.md, which NO other doctrine check scans — so
# docs/ is in scope here, or the rule would pass vacuously exactly where
# the diagnostic that needs policing lives.
#
# Guard (scoped exclusion, in the spirit of check 4's template exclusion):
# the canonical diagnostic narrates the prohibition itself in plain prose
# ("the remedy is never to disable the sandbox…"). A code-span / HTML-comment
# strip cannot tell that negated narration apart from a real recommendation,
# so stripping alone is not a sufficient guard here. Instead, that one block
# is fenced by sentinel comments and skipped; everywhere else ANY
# disable-sandbox-class phrasing — even negated — fails the check. This keeps
# the prohibition discussion confined to the single canonical block.
#
# Pattern set (case-insensitive): disable…sandbox, turn off…sandbox,
# without…sandbox, sandbox…:…false, sandbox off.
sandbox_files=()
while IFS= read -r f; do [ -n "$f" ] && sandbox_files+=("$f"); done < <(
  find "$PLUGIN_ROOT/skills" -type f -name '*.md' 2>/dev/null
  find "$PLUGIN_ROOT/docs" -type f -name '*.md' 2>/dev/null
)
# Single awk over all files; `exempt` resets at each file boundary (FNR==1).
sandbox_guidance_violations=""
if [ "${#sandbox_files[@]}" -gt 0 ]; then
  sandbox_guidance_violations=$(awk -v root="$PLUGIN_ROOT/" '
    FNR == 1 { rel = substr(FILENAME, length(root) + 1); exempt = 0 }
    /<!-- doctrine:sandbox-prose-exempt:start -->/ { exempt=1; next }
    /<!-- doctrine:sandbox-prose-exempt:end -->/   { exempt=0; next }
    exempt { next }
    {
      line = tolower($0)
      if (line ~ /disable.*sandbox/ ||
          line ~ /turn[[:space:]]+off.*sandbox/ ||
          line ~ /without.*sandbox/ ||
          line ~ /sandbox.*:.*false/ ||
          line ~ /sandbox[[:space:]]+off/) {
        print rel ":" FNR ":" $0
      }
    }
  ' "${sandbox_files[@]}")
fi

if [ -n "$sandbox_guidance_violations" ]; then
  echo "FAIL: 'disable the sandbox'-class guidance found in engine skills/docs."
  echo "$sandbox_guidance_violations" | awk -F: '{ printf "  %s:%s\n", $1, $2 }'
  echo "  Remedy must be narrow (scoped sandbox.filesystem.allowWrite / remove deny), never disabling the sandbox."
  fail=1
fi

# 5b. Sentinel-balance guard for check 5's scoped exclusion.
# An unterminated :start (a dropped or mistyped :end) would leave awk's
# `exempt` flag set for the rest of that file, silently suppressing every
# subsequent line from check 5 — i.e. a real "disable sandbox" recommendation
# added below an orphaned :start would pass undetected. Fail if any scanned
# file has mismatched start/end sentinel counts.
# Single awk over all files; per-file counts are flushed at each file
# boundary (and the last file at END) since one awk now spans every file.
sentinel_imbalance=""
if [ "${#sandbox_files[@]}" -gt 0 ]; then
  sentinel_imbalance=$(awk -v root="$PLUGIN_ROOT/" '
    function flush() { if (prev != "" && s != e) printf "%s: %d start / %d end\n", prev, s, e }
    FNR == 1 { flush(); prev = substr(FILENAME, length(root) + 1); s = 0; e = 0 }
    /<!-- doctrine:sandbox-prose-exempt:start -->/ { s++ }
    /<!-- doctrine:sandbox-prose-exempt:end -->/   { e++ }
    END { flush() }
  ' "${sandbox_files[@]}")
fi

if [ -n "$sentinel_imbalance" ]; then
  echo "FAIL: unbalanced doctrine:sandbox-prose-exempt sentinels (would blind check 5)."
  echo "$sentinel_imbalance" | awk '{ print "  " $0 }'
  fail=1
fi

# 6. README example-count claim matches reality.
# Doctrine: the cardinal count of worked examples named in README.md prose
# must equal the actual `examples/<slug>/SKILL.md` count. Drift means the
# README is lying to readers about the corpus shape. The README claim is
# unbolded ("There are three worked examples, …") per the current README
# prose direction; the grep maps a small set of cardinal words to digits
# and compares. If the README ever moves to a numeric form ("There are 3
# …"), extend the matcher; for now the cardinal form is what ships. The
# cardinal map ceiling is currently `ten`; a fork running with 11+
# bundled examples must extend the map (loud-fail with "unrecognized
# cardinal" alerts that this needs doing).
#
# Hidden-directory guard: `find -not -path '*/.*'` so an in-progress
# `examples/.draft/SKILL.md` does not inflate `actual_count`.
#
# Multi-match guard: if the README contains more than one
# "there (are|is) <word> worked example(s)" sentence, fail rather than
# letting `head -1` silently swallow a second contradictory claim. The
# whole point of this check is to detect drift.
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
readme_matches=$(grep -oiE 'there (are|is) [a-z]+ worked examples?' \
  "$REPO_ROOT/README.md" 2>/dev/null)
# grep -c prints '0' AND exits 1 on no match; a trailing `|| echo 0` would
# append a second line -> "0\n0" -> the `-gt 1` integer test below errors on
# stderr. Capture the count (already a lone integer) and default only the
# empty-output case.
readme_match_count=$(printf '%s\n' "$readme_matches" | grep -c . 2>/dev/null)
readme_match_count=${readme_match_count:-0}
readme_cardinal=$(printf '%s\n' "$readme_matches" | head -1 | awk '{ print tolower($3) }')
actual_count=$(find "$REPO_ROOT/examples" -maxdepth 2 -name SKILL.md -not -path '*/.*' 2>/dev/null | wc -l | tr -d ' ')
case "$readme_cardinal" in
  one)   claimed=1 ;;
  two)   claimed=2 ;;
  three) claimed=3 ;;
  four)  claimed=4 ;;
  five)  claimed=5 ;;
  six)   claimed=6 ;;
  seven) claimed=7 ;;
  eight) claimed=8 ;;
  nine)  claimed=9 ;;
  ten)   claimed=10 ;;
  *)     claimed=-1 ;;
esac
if [ "$readme_match_count" -gt 1 ]; then
  echo "FAIL: README example-count claim is multi-stated ($readme_match_count matches) — drift risk; reconcile to a single sentence."
  fail=1
elif [ "$claimed" = "-1" ]; then
  echo "FAIL: README example-count claim not found or unrecognized cardinal (looked for 'there (are|is) <word> worked example(s)' with <word> in one..ten)."
  fail=1
elif [ "$claimed" != "$actual_count" ]; then
  echo "FAIL: README example-count claim ($readme_cardinal = $claimed) does not match actual ($actual_count) examples/*/SKILL.md."
  fail=1
fi

# 7. Example verify.sh copies stay byte-identical to the template.
# Doctrine: each examples/<slug>/verify.sh is a verbatim copy of
# engine-bootstrap-templates/verify.sh. The example-COUNT check above does
# not inspect verify.sh content, so without this a template edit that misses
# the copies would silently leave 4 diverging ~1,100-line scripts.
tmpl="$PLUGIN_ROOT/engine-bootstrap-templates/verify.sh"
if [ ! -f "$tmpl" ]; then
  echo "FAIL: engine-bootstrap-templates/verify.sh missing — cannot check example copies."
  fail=1
else
  while IFS= read -r ex; do
    [ -n "$ex" ] || continue
    if ! cmp -s "$tmpl" "$ex"; then
      echo "FAIL: ${ex#"$REPO_ROOT/"} diverges from engine-bootstrap-templates/verify.sh — re-sync the copy."
      fail=1
    fi
  done < <(find "$REPO_ROOT/examples" -mindepth 2 -maxdepth 2 -name verify.sh 2>/dev/null)
fi

# 8. Version parity across the release surfaces.
# Doctrine: plugin.json, marketplace.json, and the README (version badge +
# prose) all state one version. docs/10-version-evolution.md mandates this;
# no other mechanical gate enforced it, so a mid-flight split (plugin 0.3.0 /
# marketplace 0.2.1) could ship unnoticed. Brittle to README rewording by
# design — a missed capture fails loud rather than passing vacuously.
plugin_ver=$(jq -r '.version // empty' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null)
market_ver=$(jq -r '.plugins[0].version // empty' "$REPO_ROOT/.claude-plugin/marketplace.json" 2>/dev/null)
readme_badge_ver=$(grep -oE 'badge/version-v[0-9]+\.[0-9]+\.[0-9]+' "$REPO_ROOT/README.md" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
readme_prose_ver=$(grep -oE 'This is v[0-9]+\.[0-9]+\.[0-9]+' "$REPO_ROOT/README.md" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
if [ -z "$plugin_ver" ] || [ -z "$market_ver" ] || [ -z "$readme_badge_ver" ] || [ -z "$readme_prose_ver" ]; then
  echo "FAIL: version-parity check could not read a version (plugin='$plugin_ver' marketplace='$market_ver' README-badge='$readme_badge_ver' README-prose='$readme_prose_ver')."
  fail=1
elif [ "$plugin_ver" != "$market_ver" ] || [ "$plugin_ver" != "$readme_badge_ver" ] || [ "$plugin_ver" != "$readme_prose_ver" ]; then
  echo "FAIL: version mismatch — plugin.json=$plugin_ver, marketplace.json=$market_ver, README badge=$readme_badge_ver, README prose=$readme_prose_ver. Reconcile to a single version."
  fail=1
fi

# 9. Skills reference only the kind-partitioned cache layout.
# Doctrine: the clone cache is partitioned by source kind —
# ~/.cache/skill-engine/git-managed/<source_id>-<sha>/ for git-backed
# sources and ~/.cache/skill-engine/web-doc/<source_id>-<crawl_id>/ for
# crawl snapshots. The flat layout (~/.cache/skill-engine/<source_id>-…/)
# is legacy, mentioned only in migration and cleanup prose. An unmarked
# flat-layout path in a skill means the layout has forked again — the
# failure mode that once left engine-bootstrap seeding a cache DISCOVER
# could not see, double-cloning every source. Deliberate legacy mentions
# carry a per-line <!-- doctrine:legacy-cache-layout --> marker.
flat_cache_refs=$(grep -rn -F 'cache/skill-engine/<source_id>' \
  "$PLUGIN_ROOT/skills" --include='*.md' 2>/dev/null \
  | grep -v -F '<!-- doctrine:legacy-cache-layout -->')
if [ -n "$flat_cache_refs" ]; then
  echo "FAIL: flat cache-layout path in a skill — the kind-partitioned layout (git-managed/, web-doc/) is the only current layout."
  echo "$flat_cache_refs" | sed "s|^$PLUGIN_ROOT/|  |"
  echo "  Use ~/.cache/skill-engine/git-managed/<source_id>-<sha>/ (or web-doc/), or mark a deliberate legacy mention with <!-- doctrine:legacy-cache-layout -->."
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "All doctrine grep checks passed."
fi
exit "$fail"
