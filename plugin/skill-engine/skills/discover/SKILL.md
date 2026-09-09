---
name: discover
description: Use when a contextualizer's reference coverage needs to grow against its registered sources — a fresh contextualizer's first pass, quarterly upkeep, or whenever the catalog is lagging what users are asking — to propose new reference files.
---

# Discover

You receive a task: **discover the essence of the registered sources,
then write reference files for the parts that matter**. The named
checks in `verify.sh` (plus the permalink-density lint for SHA-pinning)
validate your output; the four reference invariants are your authoring
targets — not all are machine-checked (see § Output contract). How you
reason about the corpus is your call —
there is no Stage 0/1/2 prescription, no fixed keystroke menu, no
required worker dispatch. Vary your approach by what the corpus
rewards.

## Contextualizer root

Engine workflows operate inside a contextualizer installed as a project
skill at one of three install levels:

- **User-level:** `~/.claude/skills/<slug>-context/`
- **Local-user-level:** `~/.claude/local/skills/<slug>-context/` (when in use)
- **Project-level:** `<repo>/.claude/skills/<slug>-context/`

Every path below — `research/...`, `references/...`, `verify.sh` —
resolves relative to whichever directory matches. Before reading or
writing anything, locate the root by searching all three install
levels in order:

Run the script in [`shared/locator-block.md`](../../shared/locator-block.md) verbatim before proceeding.

```bash
CTX_PROPOSED="${CTX_ROOT}.proposed"
```

Multi-contextualizer disambiguation and the full staging-directory
model — the `$CTX_PROPOSED` manifest schema, removed-detection, and
the review/apply/discard handoff — are documented in
[`references/staging-and-contextualizer-model.md`](references/staging-and-contextualizer-model.md).
Read it before your first write of a run, or whenever more than one
contextualizer is found.

## Output contract

Two things, both load-bearing:

1. **Reference files in `references/`.** Each cites its source by path
   plus content-hash (see [`02-artifact-contract.md`](../../docs/02-artifact-contract.md)). Each
   satisfies the four reference invariants (definitions owned by
   [`02-artifact-contract.md`](../../docs/02-artifact-contract.md) §Navigator size budget and
   §Long references — do not restate them elsewhere):
   - **first-5K** — the navigator's standing instructions (invariants,
     critical rules, dispatch logic) fit in the first 5K bytes of
     `SKILL.md` body; the catalog table is a TOC and is exempt.
   - **depth-1** — no more than one level of pointer indirection.
   - **max-100-line-TOC** — any reference body over 100 lines carries a
     TOC marker within its first 30 lines.
   - **SHA-pin** — every citation pins to a specific SHA, not a moving
     branch or tag.
2. **A post-run summary** for the author (see "Post-run summary" below).

`verify.sh` — plus the permalink-density lint and the reviewer — is the
trust mechanism: it mechanically checks depth-1 (`catalog-bijection`)
and the lint checks SHA-pinning; first-5K and the TOC are
reviewer-backstopped. Variance below the floor is expected — sessions
on the same corpus may differ in reference count, partition, and
prose style.

## Pre-flight

Before writing anything: guard against an unapplied proposal, resolve
in-scope sources, decide `gh`/`git` vs `WebFetch` per source kind,
optionally cache a local clone, and detect lifecycle transitions
(`reachable`/`moved`/`removed`/`unknown`). Full procedure in
[`references/cache-and-clone.md`](references/cache-and-clone.md) —
read it before your first source read of a run.

## Discovering essence

You have license to choose what to cover and at what depth. Reasoning
aids that may help (resolve them under the plugin root —
`$CLAUDE_PLUGIN_ROOT/data/` when the engine is installed as a plugin,
or `plugin/skill-engine/data/` when consumed from a checkout — and
read at your discretion, ignore as you see fit):

- `data/public-orgs.json` — known-public scope allowlist per
  ecosystem; useful when distinguishing integral first-party scopes
  from generic open-source dependencies.
- `data/popular-names.json` — top-N most-popular bare names per
  ecosystem; useful when deciding whether a dependency is commodity
  vs. worth a reference.
- `research/.discover-inventory.json` — pre-flight file inventory,
  largest files, and doc roots per source; a starting frame for
  corpus shape, read at your discretion.

The engine does not require you to use them and does not require any
particular procedural shape. It requires that the references you emit
satisfy the four invariants and that the named checks in `verify.sh`
pass.

When you do dispatch subagents to explore the corpus, restrict their
tools to `Read`/`Glob`/`Grep` — no write access, no shell access — per
[`03-engine.md`](../../docs/03-engine.md) § Anatomy: concurrency cap
and streaming-dispatch guidance for any dispatch you choose.

## Proposal threshold

**Default = propose, not exclude.** When a candidate companion source
is plausibly within the contextualizer's domain, surface it in
**Proposed companions** in the post-run summary, not Skip-reasoning.
The user's approval gate (the `status: "proposed" → confirmed/rejected`
flip in `source-paths.json`) is the filter. Pre-filtering by agent
judgment defeats the design: a silent exclusion narrows the catalog
without the user ever seeing the call.

**Skip-reasoning is for clear non-fits** — off-domain repos, unrelated
forks, accidental name collisions, archived/abandoned candidates. It
is not the bucket for "I judged this shouldn't be a separate
reference." That judgment belongs to the user.

Two edge cases — different-language ports and docs-repo /
higher-level-package companions — are in
[`references/proposal-and-post-run.md`](references/proposal-and-post-run.md).

## Formatting, permalinks & post-run summary

Soft-wrap style for emitted references, the paragraph→permalink density
rule (≥80% coverage, SHA-pinned), and the full post-run merged-tree
verification procedure are in
[`references/proposal-and-post-run.md`](references/proposal-and-post-run.md).
Read it before finalizing any run.

## Cadence

DISCOVER runs when the user invokes it — no daemon, no cron. Typical
rhythm: quarterly for mature contextualizers; on-demand when the
catalog-vs-asks gap is widening; opportunistically for fresh
contextualizers (first runs are welcome).

## Doctrine surface

- [`02-artifact-contract.md`](../../docs/02-artifact-contract.md) — the four invariants;
  `source-paths.json` thin schema; reference shape contract.
- [`04-delivery.md`](../../docs/04-delivery.md) — when to add DISCOVER; lifecycle sweep dry-run
  semantics; proposal-token + per-file SHA gates.
- [`08-discover-pipeline.md`](../../docs/08-discover-pipeline.md) — pipeline doctrine (one-pager).
- [`09-discover-config.md`](../../docs/09-discover-config.md) — persisted-state layout (thin per-source
  schema; cache contract).
- [`03-engine.md`](../../docs/03-engine.md) — engine anatomy:
  concurrency cap, streaming dispatch, and tool isolation for any
  subagents you choose to dispatch.

## What this skill does NOT do

- It does not auto-clone proposed companion sources. The author runs
  `git clone` themselves into the cache location (or any chosen
  directory).
- It does not recurse companion discovery past depth-1. Single-hop
  limit by doctrine.
- It does not parse lockfiles (`package-lock.json`, `Cargo.lock`,
  `go.sum`). Manifests are input to your reasoning, not an enforced
  schema.
- It does not do live registry calls for commodity filtering by
  default.
- It does not detect archival. REFRESH's Phase 0.5 stages
  `archived: true`; DISCOVER just reads it live.
- It does not track inner-path changes on `moved` sources. The outer
  URL is rewritten on accept; inner-path drift is flagged for manual
  review.
- It does not auto-rewrite SHA-pinned URLs on moved sources to point
  at the new host's equivalent SHAs. SHA history may not transfer on
  org rename; stale source-shas are flagged in the dry-run for manual
  spot-check.
