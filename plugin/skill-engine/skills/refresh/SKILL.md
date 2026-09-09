---
name: refresh
description: Use when an existing contextualizer's references may have drifted from current upstream state — typically weekly, or whenever a few days of upstream changes have accumulated — to bring them back into agreement.
---

# Refresh

You receive a task: **bring the contextualizer's existing references
into agreement with the current upstream state of every registered
source**. The named checks in `verify.sh` (plus the permalink-density
lint for SHA-pinning) validate your output; the four reference
invariants are your authoring targets — not all are machine-checked
(see § Output contract). How you reason about drift is your call — there is no Stage -1/1/2/3 prescription, no
fixed keystroke menu, no required worker dispatch.

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

`/skill-engine:refresh <name>` names the contextualizer to refresh —
the directory name without the `-context` suffix; with no argument,
auto-detection applies. The staging-directory model (how
`$CTX_PROPOSED` mirrors the live tree and the sandbox-block diagnostic)
is in [`references/tool-and-output-mechanics.md`](references/tool-and-output-mechanics.md).
Read it before your first write of a run.

## Output contract

Two things, both load-bearing:

1. **Updated reference files in `references/`** (where applicable),
   each still citing its source by path plus content-hash (see
   [`02-artifact-contract.md`](../../docs/02-artifact-contract.md)). Each still satisfies the four
   reference invariants (definitions owned by
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
2. **Updates to `research/source-paths.json`** reflecting upstream
   transitions you detected (`lifecycle.state` for each source;
   `proposed_url` on `moved`; `last_checked` and `last_checked_sha`
   timestamps). The four-state field on `source-paths.json` is the
   single source of truth for upstream state.

`verify.sh` — plus the permalink-density lint and the reviewer — is the
trust mechanism. Of the four invariants above, `verify.sh` mechanically
checks depth-1 (inside its `catalog-bijection` check) and the lint checks
SHA-pinning; first-5K and the TOC are reviewer-backstopped. Variance below
the invariant floor is acceptable and expected — two REFRESH runs against
the same corpus may differ in which references were rewritten or which sources
transitioned. The invariants plus the named checks are what bind
quality.

## Pre-flight

Guard against an unapplied proposal, locate `research/source-paths.json`,
migrate legacy cache layout and thin-schema state, detect `verify.sh`
template drift, honor `--hint`/`--lifecycle-only`, and filter to
in-scope sources. Then run the probe phases against every in-scope
source: archive check (Phase 0.5), HEAD probe, decay check, re-crawl +
diff surfacing, cache GC.
Full mechanics are in
[`references/drift-detection-and-phases.md`](references/drift-detection-and-phases.md).
Read it before your first source read of a run.

## Discovering drift

You have license to choose how to probe upstream state and how to
detect content drift. The engine cares about the output, not the
procedure.

**Lifecycle state.** For each in-scope source, decide whether its
upstream is `reachable`, `moved`, `removed`, or `unknown` and write
transitions to the proposed tree. A transition affecting an existing
reference or the navigator triggers a lifecycle-sweep dry-run the user
accepts or rejects before anything is rewritten. Both mechanics — the
copy-on-write snippet and the sweep protocol — are in
[`references/drift-detection-and-phases.md`](references/drift-detection-and-phases.md).

**Content drift.** For each source still `reachable` after the
lifecycle pass, decide whether its content has changed since the last
DISCOVER/REFRESH. Per-source SHA in `research/.discover-cache.json` is
the canonical signal for `kind: git-managed`; for `external-doc`,
the cached `(source_id, sha)` over the byte-sorted file digest plus
the `decay` policy in the source's frontmatter governs.

When you do dispatch subagents to probe drift across sources, restrict
their tools to `Read`/`Glob`/`Grep` — no write access, no shell access
— per [`03-engine.md`](../../docs/03-engine.md) § Anatomy: how the
engine works, whose concurrency-cap and streaming-dispatch guidance
applies whenever you choose that route.

## Tool preference, cache GC & post-run summary

Prefer the `gh`/`git` CLIs over WebFetch for git-managed sources —
WebFetch parses rendered HTML at roughly 10× the token cost. Garbage-
collect superseded source-SHA cache directories once a new one lands.
Rewritten references use soft-wrap style. Before rendering the closing
summary, verify against the ephemeral merged tree and write the staging
manifest; the summary itself has four parts: coverage, skip-reasoning,
a hint invitation, and the staging-dir handoff line. Full mechanics are in
[`references/tool-and-output-mechanics.md`](references/tool-and-output-mechanics.md).
Read it before finalizing any run.

## Cadence

Weekly is the typical rhythm. Run REFRESH any time more than a few days
of upstream changes have accumulated; skip it when the catalog is quiet.
The lifecycle pass is cheap (sub-second for typical 5-30 source
contextualizers) and catches dead-link drift that accumulates silently.

## Doctrine surface

- [`02-artifact-contract.md`](../../docs/02-artifact-contract.md) — the four invariants;
  `source-paths.json` thin schema; reference shape contract.
- [`04-delivery.md`](../../docs/04-delivery.md) — lifecycle sweep dry-run UX + dangling-citation
  consequence framing.
- [`08-discover-pipeline.md`](../../docs/08-discover-pipeline.md) — pipeline doctrine (one-pager;
  REFRESH and DISCOVER share the goal-given posture).
- [`maintenance-agent.md.template`](../../engine-bootstrap-templates/maintenance-agent.md.template) § `## Workflow: REFRESH` —
  per-domain agent template overview.
- [`03-engine.md`](../../docs/03-engine.md) — engine anatomy:
  concurrency cap, streaming dispatch, and tool isolation for any
  subagents you choose to dispatch.

## What this skill does NOT do

- It does not auto-apply an archived transition. GitHub/GitLab
  archival is staged `archived: true`; the reviewer's `apply` accepts
  it.
- It does not rewrite inner-path changes on `moved` sources. The outer
  URL is rewritten on accept; inner-path drift is flagged for manual
  review.
- It does not auto-rewrite SHA-pinned URLs on moved sources to point at
  the new host's equivalent SHAs (SHA history may not transfer on org
  rename / fork-as-rename). Stale source-shas are flagged in dry-run
  for manual spot-check.
- It does not propose new sources or expand source coverage. That is
  DISCOVER's domain. REFRESH only updates existing references and
  lifecycle state for sources already in `source-paths.json`.
- It does not parse lockfiles or query registries for commodity
  filtering by default.
