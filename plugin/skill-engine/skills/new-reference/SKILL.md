---
name: new-reference
description: Register one new reference in an existing contextualizer without a full discover pass.
---

# New reference

Create a new primary reference file from scratch and wire it into the
navigator's catalog. Use this when a single topic has been identified ahead of
time and a full discover pass would be overkill.

The proposal writes:

- A new file under `references/<source-slug>-<topic>.md` (the reference itself).
- A new row in the navigator's catalog table at `SKILL.md` pointing at that
  reference.

It does NOT write to `research/.research-state.json` — that file is a binary
setup marker only. If the new reference
covers a topic from an as-yet-unregistered source, the source is added to
`research/source-paths.json` as part of the same proposal.

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
skill at `.claude/skills/<slug>-context/`. Every path below —
`research/...`, `references/...`, `verify.sh` — resolves relative to that
directory.

Before reading or writing anything, locate the root from the project
working directory:

```bash
ctx_roots=$(find .claude/skills -mindepth 1 -maxdepth 1 -type d -name '*-context' 2>/dev/null)
n=$(printf '%s\n' "$ctx_roots" | grep -c .)
if [ "$n" -eq 0 ]; then
  echo "No contextualizer found under .claude/skills/*-context/. Run /skill-engine:engine-bootstrap first."
  exit 1
elif [ "$n" -gt 1 ]; then
  echo "Multiple contextualizers under .claude/skills/; specify one:"
  printf '%s\n' "$ctx_roots"
  exit 1
fi
CTX_ROOT="$ctx_roots"
```

Read every subsequent `research/foo` path as `$CTX_ROOT/research/foo`,
every `references/foo` as `$CTX_ROOT/references/foo`, and `verify.sh` as
`$CTX_ROOT/verify.sh`.

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

Pre-approval validation runs before any write: catalog bijection,
no-frontmatter, `./verify.sh`. See chapter [`03-engine.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/03-engine.md)
`## Pre-approval validation (the load-bearing contract)`. (Byte-equality
fixture refresh and the full test-suite harness are pre-fixture-harness aspirational —
the pre-fixture-harness three-check gate ends with `verify.sh`.)

The catalog row, the reference file, and (if applicable) the new entry in
`research/source-paths.json` are all part of the same proposal — surface
them together for human approval.

## Markdown style for the emitted reference

Soft wrap reference prose: one paragraph per line, no hard line breaks at
fixed column widths. The example contextualizer at
[`examples/modelcontextprotocol-python-sdk-context/`](https://github.com/nick-railsback/skill-engine/tree/main/examples/modelcontextprotocol-python-sdk-context) shows the intended style; the
`discover/SKILL.md` "Markdown style for emitted references" section
documents the convention in full.
