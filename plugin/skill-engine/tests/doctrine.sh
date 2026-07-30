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
   --include='*.sh' --include='*.md' --include='*.template' 2>/dev/null \
   | grep -v -F "$PLUGIN_ROOT/tests/doctrine.sh"; then
  echo "FAIL: html-to-markdown library reference found in engine code."
  fail=1
fi

# 2. Engine code does not perform HTTP GETs itself.
# Doctrine: only the model (via WebFetch or MCP fetch) performs content
# fetches. Engine shell scripts may use `git`, `gh`, and `curl --head`/-I
# (HEAD probes for reachability) only. A non-HEAD curl in any stamped
# shell script would mean the engine is silently taking on the fetch role.
# Allowlist shape, not GET-recognition: the previous pattern required a
# non-dash character right after `curl `, which never matches the dominant
# real-world GET forms (`curl -fsSL URL`, `curl -s URL`) — so it caught
# only invocations nobody writes. Now ANY curl invocation is flagged
# unless its argument list carries --head or -I (alone or in a combined
# short-flag cluster like -sI).
# Scope includes *.sh.template: those files stamp into every user repo
# and previously escaped this check entirely.
# Comments are stripped before the allowlist filter (full-line comments,
# and trailing ones — whitespace before the '#' keeps URL fragments
# intact), then the curl token is re-required: a trailing "# … --head …"
# comment must not whitelist a GET on the same line, and a prose comment
# mentioning curl is not an invocation. The -I allowance accepts the flag
# anywhere in a short-flag cluster (-I is curl's only capital-I option),
# so legitimate forms like `curl -Is` pass.
if grep -rEn '(^|[^A-Za-z0-9_-])curl([[:space:]]|$)' \
   "$PLUGIN_ROOT/engine-bootstrap-templates" \
   --include='*.sh' --include='*.sh.template' 2>/dev/null \
   | sed -E 's/^([^:]*:[0-9]+:)[[:space:]]*#.*$/\1/; s/[[:space:]]+#.*$//' \
   | grep -E '(^|[^A-Za-z0-9_-])curl([[:space:]]|$)' \
   | grep -vE '(--head|[[:space:]]-[A-Za-z]*I[A-Za-z]*)([[:space:]]|$)'; then
  echo "FAIL: non-HEAD curl invocation in engine shell scripts (only curl --head / -I reachability probes are permitted)."
  fail=1
fi

# 3. Engine code does not handle auth tokens.
# Doctrine: the engine does not plumb auth tokens. Reachability against
# private upstreams is the user's environment's responsibility (their
# git/gh config). Any `Authorization: Bearer ...` or `GITHUB_TOKEN`
# reference in engine shell scripts would mean the engine is silently
# taking on auth.
# Scope includes *.sh.template (stamped into user repos) but deliberately
# NOT *.md.template: prose templates narrate doctrine and would
# false-positive on sentences about tokens; checks 2-3 police executable
# shell only.
if grep -rE 'BEARER|Authorization:\s*Bearer|GITHUB_TOKEN' \
   "$PLUGIN_ROOT/engine-bootstrap-templates" \
   --include='*.sh' --include='*.sh.template' 2>/dev/null; then
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
#   plugin/skill-engine/agents/*.md       (directory currently absent;
#                                          covered again if reintroduced)
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
      # Strip shell line comments. Engine shell files legitimately describe
      # git verbs in prose ("...the global/system git config..."), and a
      # comment cannot invoke anything. Applied after the code-span strip so
      # a span containing '#' has already gone.
      sub(/#.*$/, "", line)
      # Strip double-quoted literals carrying no command substitution, so a
      # verb named inside a diagnostic message is not read as an invocation.
      # Forms that can actually run something -- $(...) and backticks -- are
      # deliberately left in place and still scanned. Known limit, pinned
      # rather than implied away: `bash -c "git push"` is not caught here.
      while (match(line, /"[^"$`]*"/)) {
        line = substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH)
      }
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
# trip the lint. The union below is the read-only allow-list plus the
# mutating deny-list, plus a few additional known verbs seen in docs /
# templates.
readonly_violations=$(
  {
    find "$PLUGIN_ROOT/skills" -type f -name '*.md' 2>/dev/null
    find "$PLUGIN_ROOT/agents" -type f -name '*.md' 2>/dev/null
    find "$PLUGIN_ROOT/bin" -type f -name '*.sh' 2>/dev/null
    find "$PLUGIN_ROOT/tests" -type f -name '*.sh' 2>/dev/null
    find "$PLUGIN_ROOT/engine-bootstrap-templates" -type f 2>/dev/null
  } | git_readonly_scan | awk -F: '
    BEGIN {
      # Allow-list: read-only relative to user repo state.
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

# 8 (continued) — the two hand-edited release surfaces the four-way check
# above does not see. Only the prompt-guided /release skill touches
# SECURITY.md's supported line and the CHANGELOG heading, so a hand-rolled
# release could keep CI green while SECURITY.md advertises the wrong
# supported line.
#   SECURITY.md: the supported-versions table row `| X.Y.x |` must carry
#   plugin.json's major.minor (pre-1.0 policy: latest minor line only).
#   CHANGELOG.md: the top release heading `## [X.Y.Z]` must equal
#   plugin.json's version exactly.
if [ -n "$plugin_ver" ]; then
  plugin_minor="${plugin_ver%.*}"
  security_line=$(grep -oE '^\| [0-9]+\.[0-9]+\.x ' "$REPO_ROOT/SECURITY.md" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+')
  changelog_ver=$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$REPO_ROOT/CHANGELOG.md" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  if [ -z "$security_line" ]; then
    echo "FAIL: version-parity could not read SECURITY.md's supported-line row ('| X.Y.x |' shape expected)."
    fail=1
  elif [ "$security_line" != "$plugin_minor" ]; then
    echo "FAIL: SECURITY.md supports $security_line.x but plugin.json is $plugin_ver — update the supported-versions table."
    fail=1
  fi
  if [ -z "$changelog_ver" ]; then
    echo "FAIL: version-parity could not read CHANGELOG.md's top release heading ('## [X.Y.Z]' shape expected)."
    fail=1
  elif [ "$changelog_ver" != "$plugin_ver" ]; then
    echo "FAIL: CHANGELOG.md's top release heading is $changelog_ver but plugin.json is $plugin_ver — add or fix the release entry."
    fail=1
  fi
fi

# 9. Skills, docs, and the README reference only the kind-partitioned
# cache layout.
# Doctrine: the clone cache is partitioned by source kind —
# ~/.cache/skill-engine/git-managed/<source_id>-<sha>/ for git-backed
# sources and ~/.cache/skill-engine/web-doc/<source_id>-<crawl_id>/ for
# crawl snapshots. The flat layout (~/.cache/skill-engine/<source_id>-…/)
# is legacy, mentioned only in migration and cleanup prose. An unmarked
# flat-layout path means the layout has forked again — the failure mode
# that once left engine-bootstrap seeding a cache DISCOVER could not see,
# double-cloning every source. Scope is skills/ AND docs/ AND the repo
# README: the v0.3.x migration updated skills only and the doc chapters
# kept teaching the flat path for months. Deliberate legacy mentions
# carry a per-line <!-- doctrine:legacy-cache-layout --> marker.
flat_cache_refs=$(grep -rn -F 'cache/skill-engine/<source_id>' \
  "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/docs" "$REPO_ROOT/README.md" \
  --include='*.md' 2>/dev/null \
  | grep -v -F '<!-- doctrine:legacy-cache-layout -->')
if [ -n "$flat_cache_refs" ]; then
  echo "FAIL: flat cache-layout path in a skill/doc/README — the kind-partitioned layout (git-managed/, web-doc/) is the only current layout."
  echo "$flat_cache_refs" | sed "s|^$PLUGIN_ROOT/|  |;s|^$REPO_ROOT/|  |"
  echo "  Use ~/.cache/skill-engine/git-managed/<source_id>-<sha>/ (or web-doc/), or mark a deliberate legacy mention with <!-- doctrine:legacy-cache-layout -->."
  fail=1
fi

# 10. The contextualizer-locator script lives in exactly one shared file;
# none of the five locator skills inlines it, and each links to it instead.
# Doctrine: discover, refresh, status, self-audit, and new-reference used to
# carry a byte-identical copy of one root-resolution bash block, which this
# check enforced with a byte-compare across all five (plus a sentinel-
# balance guard so an unterminated fence couldn't blind that compare). The
# block now lives in exactly one tracked file — shared/locator-block.md —
# so there is nothing left for five copies to diverge from, and the
# byte-compare and its guard are retired outright rather than reworked into
# a no-op. What a single shared copy still needs enforced: the shared file
# must exist and actually carry the locator script, not a stub or an empty
# placeholder (grepped for two literal strings pulled from the script's own
# error paths, so a bad move or a truncation fails loud rather than passing
# vacuously); none of the five skills' SKILL.md may still carry the block
# inline — its fenced sentinels or its literal script text surviving in a
# SKILL.md would mean the move was a copy, not a move; and each of the five
# skills' SKILL.md must link to the shared file instead of inlining it.
# Whether that link actually resolves to a real file on disk is check 15's
# job — a Markdown link target beginning `../../` already matches this
# pointer's shape — so link resolution is not re-checked here.
locator_shared="$PLUGIN_ROOT/shared/locator-block.md"
locator_sentence_1='No contextualizer named ${name}-context under any of ~/.claude/skills/, ~/.claude/local/skills/, or .claude/skills/. Rerun with no name to list what is installed.'
locator_sentence_2='No contextualizer found under any of ~/.claude/skills/, ~/.claude/local/skills/, or .claude/skills/. Run /skill-engine:engine-bootstrap first.'

if [ ! -f "$locator_shared" ]; then
  echo "FAIL: shared/locator-block.md is missing — the locator script has no single shared home."
  fail=1
elif ! grep -qF -- "$locator_sentence_1" "$locator_shared" || ! grep -qF -- "$locator_sentence_2" "$locator_shared"; then
  echo "FAIL: shared/locator-block.md exists but does not contain the locator script (its distinguishing 'No contextualizer …' text is missing)."
  fail=1
fi

for locator_skill in discover refresh status self-audit new-reference; do
  skill_md="$PLUGIN_ROOT/skills/$locator_skill/SKILL.md"
  locator_inline_line=$(grep -nF \
    -e '<!-- doctrine:locator-block:start -->' \
    -e '<!-- doctrine:locator-block:end -->' \
    -e "$locator_sentence_1" \
    -e "$locator_sentence_2" \
    "$skill_md" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$locator_inline_line" ]; then
    echo "FAIL: skills/$locator_skill/SKILL.md:$locator_inline_line still inlines the locator block — move it to shared/locator-block.md and link to it instead."
    fail=1
  fi
  if ! grep -qF -- '](../../shared/locator-block.md' "$skill_md" 2>/dev/null; then
    echo "FAIL: skills/$locator_skill/SKILL.md does not link to ../../shared/locator-block.md."
    fail=1
  fi
done

# 11. Every bundled example's Claims policy carries the load-bearing
# sentences from the navigator template.
# Doctrine: examples legitimately customize their Claims-policy prose
# (concrete permalink shapes, multi-source footer rules), so a whole-
# section byte-compare would false-positive. What must NOT drift are the
# two sentences other machinery depends on: the Check-8 grading contract
# on item 1 (the v0.4.0 propagation missed exactly this sentence in one
# example) and the footer-is-not-a-substitute contract on item 3.
claims_sentence_1="This inline permalink is what the grounded-citation eval (SELF-AUDIT Check 8) grades."
claims_sentence_2="summary of what you read — not a substitute"
while IFS= read -r ex_skill; do
  [ -n "$ex_skill" ] || continue
  for sentence in "$claims_sentence_1" "$claims_sentence_2"; do
    if ! grep -qF -- "$sentence" "$ex_skill"; then
      echo "FAIL: ${ex_skill#"$REPO_ROOT/"} Claims policy is missing the load-bearing sentence: \"$sentence\" — re-propagate from navigator.md.template."
      fail=1
    fi
  done
done < <(find "$REPO_ROOT/examples" -mindepth 2 -maxdepth 2 -name SKILL.md -not -path '*/.*' 2>/dev/null)

# 12. No tracked file names the feature-planning docs tree.
# Doctrine: this repo's feature-planning documents live in a directory that is
# excluded per-clone via .git/info/exclude and is never committed. A tracked
# file naming a path under it is a pointer that resolves on exactly one
# machine, written in vocabulary no reader of this repo can look up.
#
# The trap is structural, not careless. A planning workflow that pins test
# files by hash needs those tests tracked, while the documents they were
# derived from stay untracked — so the natural way to head such a test, citing
# the document it implements, produces a committed dangling pointer every time.
# Nothing upstream detects it and the machine-local pre-push hook scrubs an
# unrelated token set, so this check is the only mechanical guard.
#
# Scope is every tracked file (git ls-files): the trap is about being
# committed, not about living in any particular directory. -H forces the
# filename prefix even when xargs hands grep a single-file final batch, which
# otherwise yields unprefixed lines that defeat both the exclusion and the
# report. This file is the one exclusion, because a grep must name what it
# searches for; keep it the only one, and state the rule here in the abstract
# rather than quoting a real offending path -- a check whose own comment
# violates it is not a check. If the planning docs ever become tracked, delete
# this check outright instead of exempting files from it.
chunk_doc_refs=$(
  cd "$REPO_ROOT" && git ls-files -z \
    | xargs -0 grep -HInF 'docs/chunks/' 2>/dev/null \
    | grep -v '^plugin/skill-engine/tests/doctrine\.sh:'
)
if [ -n "$chunk_doc_refs" ]; then
  echo "FAIL: a tracked file names the untracked feature-planning docs tree — the pointer dangles in every other clone."
  echo "$chunk_doc_refs" | awk -F: '{ printf "  %s:%s\n", $1, $2 }'
  echo "  Tracked artifacts must stand alone: state the invariant, never cite the planning doc."
  fail=1
fi

# 13. The always-loaded standing rules exist and name real targets.
# Doctrine: CLAUDE.md is the one file a session loads before doing anything, so
# what it says is instruction delivered ahead of any check that could correct
# it. Two ways that goes wrong on an ordinary edit, neither of which anything
# else in this repo would notice: the file goes missing, and the standing rules
# have no always-loaded home; or a Makefile target is renamed underneath a rule
# that names it, and the instruction sends every session to a target that does
# not exist. Absence is a failure rather than a skip -- a check that goes quiet
# exactly when its subject is deleted is the vacuous green this suite exists to
# refuse. Anchored on the backticked `make <target>` form so ordinary prose
# ("make sure") is not swept in.
#
# Tracked-ness is deliberately NOT asserted here, though it is what the rule
# ultimately needs. This target runs before a commit -- that is its whole
# purpose -- so requiring the file to be tracked would fail every run between
# writing it and committing it, which is exactly when the maintainer runs this.
# CI checks out tracked files only, so there the existence branch below already
# means tracked; that is where the guarantee has to hold, and it does.
claude_md="$REPO_ROOT/CLAUDE.md"
if [ ! -f "$claude_md" ]; then
  echo "FAIL: CLAUDE.md is absent — the repo's standing rules have no always-loaded home."
  fail=1
else
  while IFS= read -r mk_target; do
    [ -n "$mk_target" ] || continue
    if ! grep -qE "^${mk_target}:" "$REPO_ROOT/Makefile" 2>/dev/null; then
      echo "FAIL: CLAUDE.md names 'make $mk_target', which is not a target in Makefile — the always-loaded rules are stale."
      fail=1
    fi
  done < <(grep -oE '`make [a-zA-Z0-9_.-]+`' "$claude_md" 2>/dev/null \
    | tr -d '`' | awk '{ print $2 }' | sort -u)
fi

# 14. No SKILL.md doctrine pointer uses a GitHub blob/tree permalink into
# this plugin's own shipped tree.
# Doctrine: a doctrine pointer whose target already ships on disk inside the
# installed plugin (a docs/*.md chapter, an engine-bootstrap-templates/*
# file) must resolve as a local relative read, not a GitHub `blob/main` or
# `tree/main` permalink that round-trips back out to this repo's hosted
# copy of a file the user already has on disk. Closed-pattern shape, per
# check 4's git-verb allow-list precedent, rather than a bare `grep
# blob/main`: anchored on the full literal path prefix
# `github.com/nick-railsback/skill-engine/(blob|tree)/main/plugin/skill-engine/`
# so the two existing prose mentions of the anti-pattern itself —
# discover/SKILL.md's and self-audit/SKILL.md's "`blob/main/...` URLs do not
# satisfy the [SHA-pin] requirement" — do not trip it. Those sentences
# describe a different invariant entirely (SHA-pinning permalinks inside a
# user's own reference corpus, not this repo's doctrine pointers) and
# neither line contains the `.../main/plugin/skill-engine/` prefix, so
# anchoring on the prefix rather than the bare `blob/main` substring lets
# them pass by construction.
# Scope: tracked *.md files under skills/** only. docs/*.md cross-references
# to other repo files and engine-bootstrap-templates/*.template
# cross-references to each other carry their own blob/main and tree/main
# links and are a different, unaudited surface this check does not police.
doctrine_pointer_violations=$(
  cd "$REPO_ROOT" && git ls-files -z -- 'plugin/skill-engine/skills/**/*.md' \
    | xargs -0 grep -HInE 'github\.com/nick-railsback/skill-engine/(blob|tree)/main/plugin/skill-engine/' 2>/dev/null
)
if [ -n "$doctrine_pointer_violations" ]; then
  echo "FAIL: SKILL.md contains a GitHub blob/tree permalink into the plugin's own shipped tree — convert to a local relative path (e.g. ../../docs/02-artifact-contract.md or ../../engine-bootstrap-templates/maintenance-agent.md.template)."
  echo "$doctrine_pointer_violations" | awk -F: '{ printf "  %s:%s\n", $1, $2 }'
  fail=1
fi

# 15. Every local relative doctrine pointer in a SKILL.md resolves to a real
# file on disk.
# Doctrine: a doctrine pointer written as a local relative path (rather than a
# GitHub permalink — check 14's concern) is only a safe trade if something
# keeps it honest. A relative path is a filesystem check, not a network
# fetch, so nothing but the absence of a check was stopping this from being
# asserted: a future rename or move of a docs/*.md chapter or an
# engine-bootstrap-templates/* file that leaves a pointer dangling must be
# caught here, the next time this suite runs, not discovered by someone
# following a broken link.
# Scope: tracked SKILL.md files under skills/** only, same as check 14.
# Match shape: a Markdown link target beginning `../../` — the local
# relative form the two existing self-audit pointers demonstrate
# (../../docs/13-coverage-testing.md) — captured per-occurrence with its
# line number, in the spirit of check 4's file:line reporting. A trailing
# `#anchor` is stripped before the filesystem check, since anchors are not a
# path component; the pointer is resolved against the citing file's own
# directory (skills/<skill-name>/), matching how a relative Markdown link
# resolves in any renderer.
relative_link_matches=$(
  cd "$REPO_ROOT" && git ls-files -z -- 'plugin/skill-engine/skills/**/SKILL.md' \
    | while IFS= read -r -d '' f; do
        awk -v rel="$f" '
          {
            line = $0
            while (match(line, /\]\(\.\.\/\.\.\/[^)]*\)/)) {
              target = substr(line, RSTART + 2, RLENGTH - 3)
              sub(/#.*$/, "", target)
              print rel ":" FNR ":" target
              line = substr(line, RSTART + RLENGTH)
            }
          }
        ' "$REPO_ROOT/$f"
      done
)
relative_link_violations=""
if [ -n "$relative_link_matches" ]; then
  while IFS=: read -r rel_file rel_line rel_target; do
    [ -n "$rel_file" ] || continue
    skill_dir="$(dirname "$REPO_ROOT/$rel_file")"
    if [ ! -f "$skill_dir/$rel_target" ]; then
      relative_link_violations="${relative_link_violations}${rel_file}:${rel_line}: ${rel_target}
"
    fi
  done <<< "$relative_link_matches"
fi
if [ -n "$relative_link_violations" ]; then
  echo "FAIL: SKILL.md local relative doctrine pointer does not resolve to a file on disk."
  printf '%s' "$relative_link_violations" | sed '/^$/d;s/^/  /'
  fail=1
fi

# 16. Every shipped skill's description names a trigger condition, not a
# bare label.
# Doctrine: a SKILL.md `description:` frontmatter value states WHEN to invoke
# the skill, not WHAT the skill is. A label-only description ("Delete the
# cache." / "Register a reference.") gives the routing matcher nothing to
# compare a query against, so the skill either fires too often or never; a
# trigger-condition description ("Use when...") is what the matcher actually
# needs. This is a syntactic floor, not a semantic verifier of trigger-
# condition quality — a description can contain the word and still be a weak
# trigger, which is a review-time judgment call, not a mechanical one; the
# same boundary check 15 draws between a pointer resolving and a pointer
# being the *right* one.
# Scope: tracked SKILL.md files under skills/** only, same convention as
# checks 14/15. Match shape: the `description:` frontmatter line's value must
# contain a case-insensitive "when" — the word every existing WHEN-form
# description in this repo already carries.
description_when_violations=""
while IFS= read -r -d '' f; do
  [ -n "$f" ] || continue
  desc_line=$(awk '
    BEGIN { infm=0 }
    /^---[[:space:]]*$/ { infm++; if (infm == 2) exit; next }
    infm == 1 && /^description:/ { print; exit }
  ' "$REPO_ROOT/$f")
  if [ -z "$desc_line" ]; then
    description_when_violations="${description_when_violations}${f}: no description: frontmatter field found
"
  elif ! printf '%s' "$desc_line" | grep -qiE 'when'; then
    description_when_violations="${description_when_violations}${f}: ${desc_line}
"
  fi
done < <(cd "$REPO_ROOT" && git ls-files -z -- 'plugin/skill-engine/skills/**/SKILL.md')
if [ -n "$description_when_violations" ]; then
  echo "FAIL: SKILL.md description: frontmatter names what the skill is, not when to invoke it (no case-insensitive 'when' found)."
  printf '%s' "$description_when_violations" | sed '/^$/d;s/^/  /'
  fail=1
fi

# 17. discover has a references/ directory carrying at least one tracked
# Markdown file, and discover/SKILL.md links into it.
# Doctrine: on-demand reference material for a skill lives under that
# skill's own references/ directory, not folded permanently into the
# always-loaded SKILL.md body. A references/ directory that is missing,
# that holds no tracked file, or that nothing in SKILL.md points at, is
# dead weight — the split only pays off once real content lives there and
# the router actually sends the model to it.
discover_dir="$PLUGIN_ROOT/skills/discover"
discover_skill_md="$discover_dir/SKILL.md"
discover_refs_dir="$discover_dir/references"
if [ ! -d "$discover_refs_dir" ]; then
  echo "FAIL: skills/discover/references/ does not exist."
  fail=1
else
  discover_refs_tracked_md=$(cd "$REPO_ROOT" && git ls-files -- 'plugin/skill-engine/skills/discover/references/' | grep -E '\.md$')
  if [ -z "$discover_refs_tracked_md" ]; then
    echo "FAIL: skills/discover/references/ exists but contains no tracked Markdown file."
    fail=1
  fi
fi
if [ ! -f "$discover_skill_md" ] || ! grep -qE '\]\(\.?/?references/' "$discover_skill_md" 2>/dev/null; then
  echo "FAIL: skills/discover/SKILL.md does not link to its references/ directory."
  fail=1
fi

# 18. discover/SKILL.md's own file size sits at or under the router-sized
# ceiling.
# Doctrine: a skill's SKILL.md is read on every invocation before the model
# reads a single byte of the user's source material, so its on-disk size is
# a standing entry cost paid every time. 8,204 bytes — the largest of this
# plugin's already router-sized skills — is the ceiling every SKILL.md is
# held to.
discover_skill_md="$PLUGIN_ROOT/skills/discover/SKILL.md"
if [ ! -f "$discover_skill_md" ]; then
  echo "FAIL: skills/discover/SKILL.md is missing — cannot check its size."
  fail=1
else
  discover_skill_bytes=$(wc -c < "$discover_skill_md" | tr -d ' ')
  if [ "$discover_skill_bytes" -gt 8204 ]; then
    echo "FAIL: skills/discover/SKILL.md is $discover_skill_bytes bytes — over the 8,204-byte router-sized ceiling."
    fail=1
  fi
fi

# 19. Content trimmed out of discover/SKILL.md lands in tracked files, not
# the void.
# Doctrine: shrinking a SKILL.md by deleting its content is a different
# change from shrinking it by relocating that content into references/
# read on demand, and only the latter is a size split. The combined byte
# count of discover/SKILL.md plus everything under discover/references/
# must not fall below 90% of the file's pre-split size — a floor a real
# relocation cannot breach but a real deletion can.
discover_dir="$PLUGIN_ROOT/skills/discover"
discover_skill_md="$discover_dir/SKILL.md"
discover_refs_dir="$discover_dir/references"
discover_combined_bytes=0
if [ -f "$discover_skill_md" ]; then
  discover_combined_bytes=$(wc -c < "$discover_skill_md" | tr -d ' ')
fi
if [ -d "$discover_refs_dir" ]; then
  while IFS= read -r -d '' discover_ref_file; do
    discover_ref_bytes=$(wc -c < "$discover_ref_file" | tr -d ' ')
    discover_combined_bytes=$((discover_combined_bytes + discover_ref_bytes))
  done < <(find "$discover_refs_dir" -type f -print0 2>/dev/null)
fi
if [ "$discover_combined_bytes" -lt 31743 ]; then
  echo "FAIL: discover/SKILL.md + discover/references/ combined is $discover_combined_bytes bytes — below the 31,743-byte (90% of the pre-split 35,270) floor."
  fail=1
fi

# 20. discover's Doctrine surface section links the engine chapter that
# documents subagent-dispatch doctrine.
# Doctrine: a skill's Doctrine surface section is the map from the skill to
# the fuller chapters that govern it. A chapter the skill's own behavior
# depends on but the surface omits is a doctrine pointer that should exist
# and does not — discover dispatches subagents under concurrency and
# tool-isolation rules documented in 03-engine.md, so its Doctrine surface
# must link that chapter.
discover_skill_md="$PLUGIN_ROOT/skills/discover/SKILL.md"
discover_surface_section=$(awk '/^## Doctrine surface/{f=1;next} /^## /{f=0} f' "$discover_skill_md" 2>/dev/null)
if ! printf '%s' "$discover_surface_section" | grep -qF '03-engine.md'; then
  echo "FAIL: skills/discover/SKILL.md's Doctrine surface section does not link 03-engine.md."
  fail=1
fi

# 21. discover/SKILL.md's own body states the tool-isolation rule for any
# subagent it dispatches.
# Doctrine: exploration work a discover subagent performs is read-only —
# Read, Glob, and Grep only, no write and no shell access — and that rule
# must be stated in the file the model actually reads before deciding
# whether to dispatch, not left to live only in a doctrine chapter the
# model may or may not have loaded alongside it.
discover_skill_md="$PLUGIN_ROOT/skills/discover/SKILL.md"
if ! grep -qiE 'read[^a-z]{1,15}glob[^a-z]{1,15}grep' "$discover_skill_md" 2>/dev/null || \
   ! grep -qiE 'no[[:space:]]+write' "$discover_skill_md" 2>/dev/null || \
   ! grep -qiE 'no[[:space:]]+shell' "$discover_skill_md" 2>/dev/null; then
  echo "FAIL: skills/discover/SKILL.md does not state the Read/Glob/Grep-only, no-write/no-shell subagent isolation rule in its own body."
  fail=1
fi

# 22. refresh has a references/ directory carrying at least one tracked
# Markdown file, and refresh/SKILL.md links into it.
# Doctrine: on-demand reference material for a skill lives under that
# skill's own references/ directory, not folded permanently into the
# always-loaded SKILL.md body. A references/ directory that is missing,
# that holds no tracked file, or that nothing in SKILL.md points at, is
# dead weight — the split only pays off once real content lives there and
# the router actually sends the model to it.
refresh_dir="$PLUGIN_ROOT/skills/refresh"
refresh_skill_md="$refresh_dir/SKILL.md"
refresh_refs_dir="$refresh_dir/references"
if [ ! -d "$refresh_refs_dir" ]; then
  echo "FAIL: skills/refresh/references/ does not exist."
  fail=1
else
  refresh_refs_tracked_md=$(cd "$REPO_ROOT" && git ls-files -- 'plugin/skill-engine/skills/refresh/references/' | grep -E '\.md$')
  if [ -z "$refresh_refs_tracked_md" ]; then
    echo "FAIL: skills/refresh/references/ exists but contains no tracked Markdown file."
    fail=1
  fi
fi
if [ ! -f "$refresh_skill_md" ] || ! grep -qE '\]\(\.?/?references/' "$refresh_skill_md" 2>/dev/null; then
  echo "FAIL: skills/refresh/SKILL.md does not link to its references/ directory."
  fail=1
fi

# 23. engine-bootstrap has a references/ directory carrying at least one
# tracked Markdown file, and engine-bootstrap/SKILL.md links into it.
# Doctrine: on-demand reference material for a skill lives under that
# skill's own references/ directory, not folded permanently into the
# always-loaded SKILL.md body. A references/ directory that is missing,
# that holds no tracked file, or that nothing in SKILL.md points at, is
# dead weight — the split only pays off once real content lives there and
# the router actually sends the model to it.
engine_bootstrap_dir="$PLUGIN_ROOT/skills/engine-bootstrap"
engine_bootstrap_skill_md="$engine_bootstrap_dir/SKILL.md"
engine_bootstrap_refs_dir="$engine_bootstrap_dir/references"
if [ ! -d "$engine_bootstrap_refs_dir" ]; then
  echo "FAIL: skills/engine-bootstrap/references/ does not exist."
  fail=1
else
  engine_bootstrap_refs_tracked_md=$(cd "$REPO_ROOT" && git ls-files -- 'plugin/skill-engine/skills/engine-bootstrap/references/' | grep -E '\.md$')
  if [ -z "$engine_bootstrap_refs_tracked_md" ]; then
    echo "FAIL: skills/engine-bootstrap/references/ exists but contains no tracked Markdown file."
    fail=1
  fi
fi
if [ ! -f "$engine_bootstrap_skill_md" ] || ! grep -qE '\]\(\.?/?references/' "$engine_bootstrap_skill_md" 2>/dev/null; then
  echo "FAIL: skills/engine-bootstrap/SKILL.md does not link to its references/ directory."
  fail=1
fi

# 24. refresh/SKILL.md's own file size sits at or under the router-sized
# ceiling.
# Doctrine: a skill's SKILL.md is read on every invocation before the model
# reads a single byte of the user's source material, so its on-disk size is
# a standing entry cost paid every time. 8,204 bytes — the largest of this
# plugin's already router-sized skills — is the ceiling every SKILL.md is
# held to.
refresh_skill_md="$PLUGIN_ROOT/skills/refresh/SKILL.md"
if [ ! -f "$refresh_skill_md" ]; then
  echo "FAIL: skills/refresh/SKILL.md is missing — cannot check its size."
  fail=1
else
  refresh_skill_bytes=$(wc -c < "$refresh_skill_md" | tr -d ' ')
  if [ "$refresh_skill_bytes" -gt 8204 ]; then
    echo "FAIL: skills/refresh/SKILL.md is $refresh_skill_bytes bytes — over the 8,204-byte router-sized ceiling."
    fail=1
  fi
fi

# 25. engine-bootstrap/SKILL.md's own file size sits at or under the
# router-sized ceiling.
# Doctrine: a skill's SKILL.md is read on every invocation before the model
# reads a single byte of the user's source material, so its on-disk size is
# a standing entry cost paid every time. 8,204 bytes — the largest of this
# plugin's already router-sized skills — is the ceiling every SKILL.md is
# held to.
engine_bootstrap_skill_md="$PLUGIN_ROOT/skills/engine-bootstrap/SKILL.md"
if [ ! -f "$engine_bootstrap_skill_md" ]; then
  echo "FAIL: skills/engine-bootstrap/SKILL.md is missing — cannot check its size."
  fail=1
else
  engine_bootstrap_skill_bytes=$(wc -c < "$engine_bootstrap_skill_md" | tr -d ' ')
  if [ "$engine_bootstrap_skill_bytes" -gt 8204 ]; then
    echo "FAIL: skills/engine-bootstrap/SKILL.md is $engine_bootstrap_skill_bytes bytes — over the 8,204-byte router-sized ceiling."
    fail=1
  fi
fi

# 26. Content trimmed out of refresh/SKILL.md lands in tracked files, not
# the void.
# Doctrine: shrinking a SKILL.md by deleting its content is a different
# change from shrinking it by relocating that content into references/
# read on demand, and only the latter is a size split. The combined byte
# count of refresh/SKILL.md plus everything under refresh/references/
# must not fall below 90% of the file's pre-split size — a floor a real
# relocation cannot breach but a real deletion can.
refresh_dir="$PLUGIN_ROOT/skills/refresh"
refresh_skill_md="$refresh_dir/SKILL.md"
refresh_refs_dir="$refresh_dir/references"
refresh_combined_bytes=0
if [ -f "$refresh_skill_md" ]; then
  refresh_combined_bytes=$(wc -c < "$refresh_skill_md" | tr -d ' ')
fi
if [ -d "$refresh_refs_dir" ]; then
  while IFS= read -r -d '' refresh_ref_file; do
    refresh_ref_bytes=$(wc -c < "$refresh_ref_file" | tr -d ' ')
    refresh_combined_bytes=$((refresh_combined_bytes + refresh_ref_bytes))
  done < <(find "$refresh_refs_dir" -type f -print0 2>/dev/null)
fi
if [ "$refresh_combined_bytes" -lt 23381 ]; then
  echo "FAIL: refresh/SKILL.md + refresh/references/ combined is $refresh_combined_bytes bytes — below the 23,381-byte (90% of the pre-split 25,979) floor."
  fail=1
fi

# 27. Content trimmed out of engine-bootstrap/SKILL.md lands in tracked
# files, not the void.
# Doctrine: shrinking a SKILL.md by deleting its content is a different
# change from shrinking it by relocating that content into references/
# read on demand, and only the latter is a size split. The combined byte
# count of engine-bootstrap/SKILL.md plus everything under
# engine-bootstrap/references/ must not fall below 90% of the file's
# pre-split size — a floor a real relocation cannot breach but a real
# deletion can.
engine_bootstrap_dir="$PLUGIN_ROOT/skills/engine-bootstrap"
engine_bootstrap_skill_md="$engine_bootstrap_dir/SKILL.md"
engine_bootstrap_refs_dir="$engine_bootstrap_dir/references"
engine_bootstrap_combined_bytes=0
if [ -f "$engine_bootstrap_skill_md" ]; then
  engine_bootstrap_combined_bytes=$(wc -c < "$engine_bootstrap_skill_md" | tr -d ' ')
fi
if [ -d "$engine_bootstrap_refs_dir" ]; then
  while IFS= read -r -d '' engine_bootstrap_ref_file; do
    engine_bootstrap_ref_bytes=$(wc -c < "$engine_bootstrap_ref_file" | tr -d ' ')
    engine_bootstrap_combined_bytes=$((engine_bootstrap_combined_bytes + engine_bootstrap_ref_bytes))
  done < <(find "$engine_bootstrap_refs_dir" -type f -print0 2>/dev/null)
fi
if [ "$engine_bootstrap_combined_bytes" -lt 28581 ]; then
  echo "FAIL: engine-bootstrap/SKILL.md + engine-bootstrap/references/ combined is $engine_bootstrap_combined_bytes bytes — below the 28,581-byte (90% of the pre-split 31,757) floor."
  fail=1
fi

# 28. refresh's Doctrine surface section links the engine chapter that
# documents subagent-dispatch doctrine.
# Doctrine: a skill's Doctrine surface section is the map from the skill to
# the fuller chapters that govern it. A chapter the skill's own behavior
# depends on but the surface omits is a doctrine pointer that should exist
# and does not — refresh dispatches subagents under concurrency and
# tool-isolation rules documented in 03-engine.md, so its Doctrine surface
# must link that chapter.
refresh_skill_md="$PLUGIN_ROOT/skills/refresh/SKILL.md"
refresh_surface_section=$(awk '/^## Doctrine surface/{f=1;next} /^## /{f=0} f' "$refresh_skill_md" 2>/dev/null)
if ! printf '%s' "$refresh_surface_section" | grep -qF '03-engine.md'; then
  echo "FAIL: skills/refresh/SKILL.md's Doctrine surface section does not link 03-engine.md."
  fail=1
fi

# 29. refresh/SKILL.md's own body states the tool-isolation rule for any
# subagent it dispatches.
# Doctrine: exploration work a refresh subagent performs is read-only —
# Read, Glob, and Grep only, no write and no shell access — and that rule
# must be stated in the file the model actually reads before deciding
# whether to dispatch, not left to live only in a doctrine chapter the
# model may or may not have loaded alongside it.
refresh_skill_md="$PLUGIN_ROOT/skills/refresh/SKILL.md"
if ! grep -qiE 'read[^a-z]{1,15}glob[^a-z]{1,15}grep' "$refresh_skill_md" 2>/dev/null || \
   ! grep -qiE 'no[[:space:]]+write' "$refresh_skill_md" 2>/dev/null || \
   ! grep -qiE 'no[[:space:]]+shell' "$refresh_skill_md" 2>/dev/null; then
  echo "FAIL: skills/refresh/SKILL.md does not state the Read/Glob/Grep-only, no-write/no-shell subagent isolation rule in its own body."
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "All doctrine grep checks passed."
fi
exit "$fail"
