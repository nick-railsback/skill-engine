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

if [ "$fail" -eq 0 ]; then
  echo "All doctrine grep checks passed."
fi
exit "$fail"
