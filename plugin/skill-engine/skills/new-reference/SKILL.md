---
name: new-reference
description: Register one new reference in an existing contextualizer without a full discover pass.
---

# New reference

Create a new primary reference file from scratch and wire it into the
navigator's catalog. Use this when a single topic has been identified ahead of
time and a full discover pass would be overkill.

The proposal stages (into `$CTX_PROPOSED/`, never the live tree):

- A new file under `references/<source-slug>-<topic>.md` (the reference itself)
  — manifest status `added`.
- A new row in the navigator's catalog table at `SKILL.md` pointing at that
  reference — manifest status `modified` (the live `SKILL.md` is copied into
  `$CTX_PROPOSED/` copy-on-write, then the row is added there).

It does NOT write to `research/.research-state.json` — that file is a binary
setup marker only. If the new reference covers a topic from an
as-yet-unregistered source, the source is added to
`research/source-paths.json` (status `modified`, same copy-on-write seed) as
part of the same proposal. Every other file in the contextualizer is recorded
`unchanged`. The whole proposal lands live only when the user runs
`/skill-engine:apply <name>`.

For `kind: git-managed` sources, the proposed entry follows the same
omit-on-default convention as `engine-bootstrap` Step 2.4: `branch` is
recorded only when the contextualizer follows a non-default branch
(`dev`, `nonprod`, `release/v2`); absent ⇒ HEAD. NEW does not prompt
for a branch at registration time — the maintainer can supply
`"branch": "<name>"` in the proposed entry directly during the
approval gesture, or edit `source-paths.json` after approval. Field
schema and regex enforcement: [`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md) §"source-paths.json entry shape".

For `web-doc` sources, citations pin three values: `source_url` (from the
fetched URL), `content_hash` (`sha256(file)[:8]`), and `crawl_date` (ISO-8601
UTC). The cache path is the model's read path but is NOT the citation
target — a reviewer on a different machine verifies by re-fetching the URL
and comparing `content_hash`.

## Contextualizer root

Engine workflows operate inside a contextualizer installed as a project
skill at one of three install levels:

- **User-level:** `~/.claude/skills/<slug>-context/`
- **Local-user-level:** `~/.claude/local/skills/<slug>-context/` (when in use)
- **Project-level:** `<repo>/.claude/skills/<slug>-context/`

Every path below — `research/...`, `references/...`, `verify.sh` —
resolves relative to whichever directory matches. Before reading or
writing anything, locate the root by searching all three install levels
in order:

<!-- doctrine:locator-block:start -->
```bash
set -euo pipefail
# <name> resolves per this skill's "Selecting a contextualizer" section;
# substitute the empty string when no contextualizer was named.
name="<name>"
ctx_roots=$(
  for root in "$HOME/.claude/skills" "$HOME/.claude/local/skills" "$PWD/.claude/skills"; do
    [ -d "$root" ] || continue
    if [ -n "$name" ]; then
      find "$root" -mindepth 1 -maxdepth 1 -type d -name "${name}-context" 2>/dev/null
    else
      find "$root" -mindepth 1 -maxdepth 1 -type d -name '*-context' 2>/dev/null
    fi
  done
)
n=$(printf '%s\n' "$ctx_roots" | grep -c .)
if [ "$n" -eq 0 ] && [ -n "$name" ]; then
  echo "No contextualizer named ${name}-context under any of ~/.claude/skills/, ~/.claude/local/skills/, or .claude/skills/. Rerun with no name to list what is installed."
  exit 1
elif [ "$n" -eq 0 ]; then
  echo "No contextualizer found under any of ~/.claude/skills/, ~/.claude/local/skills/, or .claude/skills/. Run /skill-engine:engine-bootstrap first."
  exit 1
elif [ "$n" -gt 1 ] && [ -n "$name" ]; then
  # Same slug installed at more than one level: the first root in the
  # search order above wins (user, then local-user, then project).
  CTX_ROOT=$(printf '%s\n' "$ctx_roots" | head -n1)
elif [ "$n" -gt 1 ]; then
  echo "Multiple contextualizers found; rerun naming one (see 'Selecting a contextualizer' in this skill):"
  printf '%s\n' "$ctx_roots"
  exit 1
else
  CTX_ROOT="$ctx_roots"
fi
```
<!-- doctrine:locator-block:end -->

```bash
CTX_PROPOSED="${CTX_ROOT}.proposed"
```

### Selecting a contextualizer

`new-reference`'s positional arguments are the reference name and source
URLs (the NEW workflow contract — see "Doctrine surface" below), so the
contextualizer is named with a `--ctx=<name>` argument rather than a
positional: `<name>` is the directory name without the `-context`
suffix, the same grammar `review`/`apply`/`discard` use. Substitute it
(or the empty string) for `<name>` in the locator above. With no
`--ctx`, auto-detection applies — it succeeds when exactly one
contextualizer is installed and lists the matches and exits when more
than one is.

`$CTX_PROPOSED` is the **staging directory** that mirrors the live
contextualizer. Like DISCOVER and REFRESH, NEW writes its proposal there
instead of to `$CTX_ROOT`; the live skill is untouched until the user runs
`/skill-engine:apply <name>`. Read every subsequent `research/foo` path as
`$CTX_ROOT/research/foo` **for reads** and `$CTX_PROPOSED/research/foo`
**for writes**; the same asymmetry holds for `references/foo`, `SKILL.md`,
and `verify.sh`. (The full staging contract — copy-on-write population,
`.review/manifest.json`, the `REVIEW.md` scaffold, and the
review/apply/discard gate — is documented once in `discover/SKILL.md`
§ Staging directory; NEW follows it verbatim.)

**Guard against an unapplied proposal.** If `$CTX_PROPOSED` already exists,
a prior proposal is staged and not yet applied. Halt with `A proposal is
already staged at <name>-context.proposed/. Apply it (/skill-engine:apply
<name>), discard it (/skill-engine:discard <name>), or inspect it
(/skill-engine:review <name>) before running new-reference again.` and exit
cleanly, so this run never layers onto a stale proposed tree.

## Doctrine surface

The complete NEW protocol — resource registration, initial crawl, reference
authoring, catalog update, validation — lives in chapter [`03-engine.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/03-engine.md) under
`## Workflow patterns (how each menu item runs)` and the `## Workflow: NEW`
section of [`maintenance-agent.md.template`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/engine-bootstrap-templates/maintenance-agent.md.template).

The artifact contract a new reference must satisfy (frontmatter, filename
conventions, catalog bijection; the byte-equality fixture is pre-fixture-harness
aspirational) is documented in [`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md).

## Cadence

Ad-hoc, whenever the domain grows a new topic the catalog does not yet cover.

## Invariants

Pre-stage validation runs before the proposal is finalized: catalog
bijection, no-frontmatter, `verify.sh`. See chapter [`03-engine.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/03-engine.md)
`## Pre-approval validation (the load-bearing contract)`. (Byte-equality
fixture refresh and the full test-suite harness are pre-fixture-harness aspirational —
the pre-fixture-harness three-check gate ends with `verify.sh`.)

Because `$CTX_PROPOSED/` is a sparse copy-on-write tree, run `verify.sh`
against an **ephemeral merged view** of live + this proposal's changes, not
against `$CTX_PROPOSED/` directly — exactly as `discover/SKILL.md`
§ Post-run summary documents. Then write `$CTX_PROPOSED/.review/manifest.json`
(one entry per file, per the schema in `discover/SKILL.md` § Staging
directory) and stamp `$CTX_PROPOSED/.review/REVIEW.md` from
`$CLAUDE_PLUGIN_ROOT/engine-bootstrap-templates/REVIEW.md.template` (the
`<name>` substitution as in DISCOVER). NEW MUST NOT write directly to
`$CTX_ROOT` — the new reference, the catalog row, and any
`source-paths.json` entry all flow through the staging gate.

The catalog row, the reference file, and (if applicable) the new entry in
`research/source-paths.json` are all part of the same proposal — they are
surfaced together for human review via `/skill-engine:review <name>` and
promoted together by `/skill-engine:apply <name>`.

## Markdown style for the emitted reference

Soft wrap reference prose: one paragraph per line, no hard line breaks at
fixed column widths. The example contextualizer at
[`examples/modelcontextprotocol-python-sdk-context/`](https://github.com/nick-railsback/skill-engine/tree/main/examples/modelcontextprotocol-python-sdk-context) shows the intended style; the
`discover/SKILL.md` "Markdown style for emitted references" section
documents the convention in full.
