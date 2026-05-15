#!/usr/bin/env bash
# Static smoke-test for the skill-engine plugin substrate.
#
# Validates the files that `/plugin install <path>` would consume:
#
#   - .claude-plugin/plugin.json parses as JSON
#   - One SKILL.md per declared skill exists under skills/<name>/
#   - The five template-bundle files exist under engine-bootstrap-templates/
#
# Does NOT invoke `/plugin install` (which requires interactive Claude Code)
# and does NOT touch the network. Exits 0 with "OK — plugin substrate
# verified" on success; exits non-zero on the first missing or malformed
# file with a one-line diagnostic naming it. Under `set -euo pipefail`, the
# first failure short-circuits subsequent checks — a smoke-test trade-off,
# not a full enumeration of all errors.

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PLUGIN_ROOT"

MANIFEST=".claude-plugin/plugin.json"

# 1. Manifest exists and parses.
if [ ! -f "$MANIFEST" ]; then
  printf 'install-locally: missing %s\n' "$MANIFEST" >&2
  exit 1
fi
if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
  printf 'install-locally: %s is not valid JSON\n' "$MANIFEST" >&2
  exit 1
fi

# 2. One SKILL.md per skill directory.
#
# The manifest no longer declares skills inline; auto-discovery from
# `skills/<name>/SKILL.md` is the canonical shape Claude Code's plugin
# installer consumes. install-locally.sh mirrors that contract: enumerate
# skills/*/SKILL.md, validate each is present, and treat a plugin with
# zero skill directories as a hard failure (an empty plugin is not
# installable as a useful artifact).
#
# Asymmetry with verify.sh Check 19: `verify.sh` silent-passes a manifest
# with no `skills` key (the substrate is well-formed; that's what the
# workshop check asserts). This script hard-fails an empty `skills/` tree
# instead, because a plugin with no skills is not deployable. The two
# scripts answer different questions on purpose — `verify.sh` is the
# well-formedness gate, `install-locally.sh` is the deployability gate.
# Do not "fix" the divergence by aligning them.
found_any=0
for skill_md in skills/*/SKILL.md; do
  [ -f "$skill_md" ] || continue
  found_any=1
done
if [ "$found_any" -eq 0 ]; then
  printf 'install-locally: %s contains no SKILL.md under skills/\n' "$PLUGIN_ROOT" >&2
  exit 1
fi

# 3. Template-bundle files (five of them; engine-bootstrap stamps these).
template_bundle=(
  "engine-bootstrap-templates/verify.sh"
  "engine-bootstrap-templates/navigator.md.template"
  "engine-bootstrap-templates/navigator-multi-domain.md.template"
  "engine-bootstrap-templates/source-paths.json.template"
  "engine-bootstrap-templates/research-state.json.template"
)
for tmpl in "${template_bundle[@]}"; do
  if [ ! -f "$tmpl" ]; then
    printf 'install-locally: template-bundle file missing: %s\n' "$tmpl" >&2
    exit 1
  fi
done

printf 'OK — plugin substrate verified\n'
