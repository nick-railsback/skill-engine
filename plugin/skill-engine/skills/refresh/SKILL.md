---
name: refresh
description: When the user wants to refresh an existing contextualizer — re-check upstream state for registered sources, detect drift, and re-emit reference files where the upstream has changed. The engine hands you a task and validates your output via the four reference invariants and verify.sh.
---

# Refresh

You receive a task: **bring the contextualizer's existing references
into agreement with the current upstream state of every registered
source**. The engine validates your output via the four reference
invariants and the named checks in `verify.sh`. How you reason about
drift is your call — there is no Stage -1/1/2/3 prescription, no
fixed keystroke menu, no required worker dispatch.

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

## Output contract

Two things, both load-bearing:

1. **Updated reference files in `references/`** (where applicable),
   each still citing its source by path plus content-hash (see
   [`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md)). Each still satisfies the four
   reference invariants:
   - **first-5K** — the first 5K bytes of every reference are
     self-contained enough to anchor a follow-up search.
   - **depth-1** — no more than one level of pointer indirection.
   - **max-100-line-TOC** — the navigator catalog stays under 100 lines.
   - **SHA-pin** — every citation pins to a specific SHA, not a moving
     branch or tag.
2. **Updates to `research/source-paths.json`** reflecting upstream
   transitions you detected (`lifecycle.state` for each source;
   `proposed_url` on `moved`; `last_checked` and `last_checked_sha`
   timestamps). The four-state field on `source-paths.json` is the
   single source of truth for upstream state.

`verify.sh` is the trust mechanism. Variance below the invariant floor
is acceptable and expected — two REFRESH runs against the same corpus
may differ in which references were rewritten or which sources
transitioned. The invariants plus the named checks are what bind
quality.

## Pre-flight

When `/skill-engine:refresh` is invoked:

1. **Locate state.** Read `research/source-paths.json`. If the file is
   missing, unparseable, or `sources[]` is empty, render:

   ```
   No sources registered. Run /skill-engine:engine-bootstrap first.
   ```

   and exit cleanly.

2. **Thin-schema migration (transparent).** If any `sources[i]` entry
   still carries a `chunks[]` field (legacy schema from earlier engine
   versions), flatten it away on first invocation: write back the file
   with `chunks` keys removed from each entry; preserve every other
   field intact. Log one line:
   `Migrated N sources[] entries to thin schema (chunks[] dropped).`
   No user prompt; continue.

3. **Idempotency check (no-op gate).** Before re-reading any source,
   check `research/.discover-cache.json` (gitignored runtime state)
   against current upstream SHAs. If every in-scope source's SHA is
   unchanged since its last cache entry AND every source still has
   `lifecycle.state ∈ {reachable, unknown}` since last run, summarize
   "no work to do" in the post-run summary and exit cleanly. Repeated
   REFRESH invocations against an unchanged corpus should not churn.

4. **Identify in-scope sources.** A source is in-scope if all hold:
   - `archived: false` (or field absent — defaults to false),
   - `lifecycle.state ≠ removed` (skip permanent-removed; `moved`
     surfaces for user accept but is not crawled until the URL is
     updated),
   - `status ∈ {confirmed, proposed}` (rejected companions don't
     refresh).

5. **`--lifecycle-only` flag.** If passed, perform only the lifecycle
   state-check pass below; skip drift detection and reference re-emit.
   Useful when the user wants to clear a lifecycle band quickly.

6. **Zero in-scope sources.** If after the filter no sources remain
   (all entries are `archived: true` and/or `lifecycle.state == removed`),
   render:

   ```
   Nothing to refresh. All <N> registered sources are archived or
   removed. Edit research/source-paths.json to add new sources or
   un-archive existing ones.
   ```

   and exit cleanly.

## Discovering drift

You have license to choose how to probe upstream state and how to
detect content drift. The engine cares about the output, not the
procedure.

**Lifecycle state.** For each in-scope source, decide whether its
upstream is still `reachable`, `moved`, `removed`, or `unknown` (see
[`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md) for the four-state field). Write
transitions to `research/source-paths.json` immediately. Conservative
default: any non-zero probe exit maps to `unknown`, not `removed`.
Auto-flipping `archived` is prohibited — the user sets it.

**Content drift.** For each source still `reachable` after the
lifecycle pass, decide whether its content has changed since the last
DISCOVER/REFRESH. Per-source SHA in `research/.discover-cache.json` is
the canonical signal for `kind: git-managed`; for `external-doc`,
the cached `(source_id, sha)` over the byte-sorted file digest plus
the `decay` policy in the source's frontmatter governs.

**Lifecycle sweep.** If a transition would affect existing reference
files or the navigator (a `moved` URL is cited; a `removed` source is
referenced), emit a lifecycle sweep dry-run per [`04-delivery.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/04-delivery.md).
The user accepts or rejects the sweep through the protocol documented
there (proposal-token + per-file SHA integrity gates). The engine
does not auto-mutate references on lifecycle transition.

## Tool preference for git-managed sources

For each source with `kind: git-managed`, prefer the `gh` and `git`
command-line tools over WebFetch:

- `gh repo view <owner>/<repo>`,
- `gh api repos/<owner>/<repo>/commits/<ref>`,
- `git ls-remote <url> <ref>`, `git ls-tree --recursive <ref>`,
- `git show <ref>:<path>`.

The CLIs return clean structured output; WebFetch returns rendered HTML
that consumes roughly 10× more tokens to parse. Reserve WebFetch for
`kind: external-doc` or git sources where CLI access fails.

**Which `<ref>` to use.** If the source entry carries a `branch` field,
that branch is `<ref>` everywhere above (e.g., `gh api
repos/<owner>/<repo>/commits/dev`, `git ls-remote <url> dev`). If the
`branch` field is absent, fall back to `HEAD` — `gh api
repos/<owner>/<repo>/commits/HEAD`, `git ls-remote <url> HEAD`. A branch
that no longer exists upstream is a permanent error: surface a
diagnostic naming the branch and the source, transition
`lifecycle.state` to `unknown`, and skip the source for this run (do
not silently fall back to HEAD when a branch was explicitly named).

For large `kind: git-managed` sources, REFRESH reads more efficiently
from a local clone than from remote `gh`/`git` calls. The recommended
cache location is `~/.cache/skill-engine/<source_id>-<sha>/` (see
`engine-bootstrap/SKILL.md` for the convention). If the cache directory
exists, prefer a local read; otherwise fall back to CLI calls.

### Cache garbage collection

After REFRESH successfully populates a new `~/.cache/skill-engine/<source_id>-<new-sha>/`
for a source whose SHA advanced, delete any sibling directories
matching `~/.cache/skill-engine/<source_id>-*/` whose suffix is NOT
the new SHA. Old SHA directories are by definition stale: their
contents reflect an upstream state that REFRESH has already replaced.

GC runs only when:
- The current REFRESH actually advanced the SHA for that source_id
  (cold-cache REFRESH on an unchanged SHA must not delete the cache).
- The new directory exists and is non-empty (no GC on a failed clone).

GC must not touch any directory outside `~/.cache/skill-engine/`, must
not follow symlinks, and must not delete the cache root itself.

When GC fires, narrate the action in the Coverage report of the post-run summary
(e.g., `Superseded N stale source-SHA cache directories: vitejs-vite@aaaa1111 → bbbb2222.`).
Silent deletion of disk contents the author did not request would be
the wrong shape.

## Markdown style for rewritten references

Reference files that REFRESH rewrites use **soft wrapping**: one paragraph
per line, no hard line breaks at fixed column widths. If an incoming
reference is already hard-wrapped (legacy artifact from a prior DISCOVER),
REFRESH unwraps it during the rewrite. See `discover/SKILL.md` "Markdown
style for emitted references" for the full convention.

## Post-run summary

At end-of-run, produce a paragraph-form summary for the author with
three components (no multi-column tables, no interactive menus):

1. **Coverage report.** What was probed; which sources transitioned;
   which references were rewritten; which were skipped because the
   cache short-circuited. Cite sources by `source_id`; cite content by
   path+content-hash.
2. **Skip-reasoning.** For both sources and references the model
   considered but skipped: "I skipped source Z because... I left
   reference X unchanged because..." Empty-skip case allowed.
3. **Creative-input gesture.** End with the invitation to revise:
   `If you'd like me to revise, tell me a hint and rerun:
   /skill-engine:refresh --hint='<your hint>'` — for example,
   `--hint='I think packages/foo's reference is stale even though SHA
   matches; recheck against the README'`.

The summary is paragraph-form; ≤30 lines of text typical. It is the
author's primary signal that drift was correctly identified and that
the chosen re-emits are defensible.

## Cadence

Weekly is the typical rhythm. Run REFRESH any time more than a few days
of upstream changes have accumulated; skip it when the catalog is quiet.
The lifecycle pass is cheap (sub-second for typical 5-30 source
contextualizers) and catches dead-link drift that accumulates silently.

## Doctrine surface

- [`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md) — the four invariants;
  `source-paths.json` thin schema; reference shape contract.
- [`04-delivery.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/04-delivery.md) — lifecycle sweep dry-run UX + dangling-citation
  consequence framing.
- [`08-discover-pipeline.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/08-discover-pipeline.md) — pipeline doctrine (one-pager;
  REFRESH and DISCOVER share the goal-given posture).
- [`maintenance-agent.md.template`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/engine-bootstrap-templates/maintenance-agent.md.template) § `## Workflow: REFRESH` —
  per-domain agent template overview.

## What this skill does NOT do

- It does not detect upstream archival automatically. The user
  manually flags a source `archived: true`; the engine treats it as
  `removed` for sweep purposes thereafter.
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
