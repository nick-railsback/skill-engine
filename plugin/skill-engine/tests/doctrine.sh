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
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$f" = "$SCRIPT_DIR/doctrine.sh" ] && continue
    rel="${f#"$PLUGIN_ROOT/"}"
    case "$rel" in
      engine-bootstrap-templates/release-command.md.template) continue ;;
      engine-bootstrap-templates/pre-commit.sh.template) continue ;;
    esac
    awk -v file="$rel" '
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
          print file ":" NR ":" token
          line = substr(line, RSTART + RLENGTH)
        }
      }
    ' "$f"
  done
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

if [ "$fail" -eq 0 ]; then
  echo "All doctrine grep checks passed."
fi
exit "$fail"
