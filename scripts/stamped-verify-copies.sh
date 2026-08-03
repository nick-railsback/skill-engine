#!/usr/bin/env bash
# The one inventory of verify.sh copies that must stay byte-identical to
# plugin/skill-engine/engine-bootstrap-templates/verify.sh.
#
# Prints one absolute path per line, sorted. Two consumers read it:
#
#   doctrine.sh check 7   the detector — fails the build on any divergence
#   make sync             the fix — recopies the template over each one
#
# They are the detector and the repair for the same invariant, and each
# used to carry its own `find` over examples/. Mirrored globs do not stay
# mirrored: this repo dogfoods the engine, so it carries a contextualizer of
# its own at .claude/skills/<slug>-context/ whose verify.sh is a stamped
# copy exactly like an example's — and it fell outside both globs at once.
# The result was a tracked, shipped contextualizer whose auditor was an
# older revision of the auditor it teaches, passing checks the current
# engine would fail, with the divergence widening on every template edit and
# nothing reporting it. Adding a path here now reaches the detector and the
# fix together, which is the only reason this file exists rather than a
# third glob.
#
# The `*-context/` shape is not invented here: pre-commit.sh.template globs
# exactly `.claude/skills/*-context/verify.sh` when it stamps a hook into a
# user's repo. This matches what the engine already claims a contextualizer
# looks like on disk.
#
# Read-only. No output other than the paths.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

{
  # Shipped examples: examples/<slug>/verify.sh
  find "$REPO_ROOT/examples" -mindepth 2 -maxdepth 2 -name verify.sh 2>/dev/null
  # Contextualizers installed in this repo: .claude/skills/<slug>-context/verify.sh
  find "$REPO_ROOT/.claude/skills" -mindepth 2 -maxdepth 2 -path '*-context/verify.sh' 2>/dev/null
} | LC_ALL=C sort
