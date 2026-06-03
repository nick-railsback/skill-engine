---
name: refresh
description: Refresh a contextualizer's references against current upstream state.
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

```bash
set -euo pipefail
ctx_roots=$(
  for root in "$HOME/.claude/skills" "$HOME/.claude/local/skills" "$PWD/.claude/skills"; do
    [ -d "$root" ] || continue
    find "$root" -mindepth 1 -maxdepth 1 -type d -name '*-context' 2>/dev/null
  done
)
n=$(printf '%s\n' "$ctx_roots" | grep -c .)
if [ "$n" -eq 0 ]; then
  echo "No contextualizer found under any of ~/.claude/skills/, ~/.claude/local/skills/, or .claude/skills/. Run /skill-engine:engine-bootstrap first."
  exit 1
elif [ "$n" -gt 1 ]; then
  echo "Multiple contextualizers found; specify one:"
  printf '%s\n' "$ctx_roots"
  exit 1
fi
CTX_ROOT="$ctx_roots"
CTX_PROPOSED="${CTX_ROOT}.proposed"
```

`$CTX_PROPOSED` is the **staging directory** that mirrors the live
contextualizer's structure. REFRESH writes to it instead of
`$CTX_ROOT`; the live skill is untouched until the user runs
`/skill-engine:apply <name>` to promote the proposal. Drift-detection
reads still come from the live `$CTX_ROOT/...` — the user's
last-applied state is the baseline against which drift is measured —
but every write goes to `$CTX_PROPOSED/...`. See `discover/SKILL.md`
§ Staging directory for the full model (manifest schema, three
commands, REVIEW.md template stamping) — including the sandbox-block
diagnostic to emit when a `$CTX_PROPOSED` write under `.claude/skills/**`
is rejected (per [`04-delivery.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/04-delivery.md)
§ "When a `.claude/skills/**` write is blocked"; retry with
`/skill-engine:refresh`).

The only writes that do not redirect are upstream-source clones under
`~/.cache/skill-engine/...` (the proposed-dir model is about
contextualizer-internal writes; the upstream-source cache is
independent and lives in the user-level cache root).

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

`verify.sh` — plus the permalink-density lint and the reviewer — is the
trust mechanism. Of the four invariants above, `verify.sh` mechanically
checks depth-1 (inside its `catalog-bijection` check) and the lint checks
SHA-pinning; first-5K and the TOC are reviewer-backstopped. Variance below
the invariant floor is acceptable and expected — two REFRESH runs against
the same corpus may differ in which references were rewritten or which sources
transitioned. The invariants plus the named checks are what bind
quality.

## Pre-flight

When `/skill-engine:refresh` is invoked:

0. **Guard against an unapplied proposal.** If `$CTX_PROPOSED` already exists,
   a prior DISCOVER/REFRESH proposal is staged and not yet applied. Do not
   layer this run onto it — halt with:

   ```
   A proposal is already staged at <slug>-context.proposed/. Apply it (/skill-engine:apply <slug>), discard it (/skill-engine:discard <slug>), or inspect it (/skill-engine:review <slug>) before running refresh again.
   ```

   Exit cleanly. This run's copy-on-write staging tree is built fresh from the
   live baseline once the guard passes. (Same guard as `discover/SKILL.md`
   § Pre-flight step 0 — neither route may build on a stale proposed tree.)

1. **Locate state.** Read `research/source-paths.json`. If the file is
   missing, unparseable, or `sources[]` is empty, render:

   ```
   No sources registered. Run /skill-engine:engine-bootstrap first.
   ```

   and exit cleanly.

1.5. **Cache layout migration (one-time).** Earlier engine versions
   stored git-managed clones flat at
   `~/.cache/skill-engine/<source_id>-<sha>/`. The current layout is
   `~/.cache/skill-engine/git-managed/<source_id>-<sha>/`. On every
   REFRESH invocation, check for flat-layout entries:

   ```bash
   cache_root="${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}"
   # Allow-list: a flat-layout git-managed clone has a .git/HEAD file inside
   # a directory at the cache root. Anything else (future kind subdirs, stray
   # directories) is intentionally not migrated.
   flat_entries=$(find "$cache_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r d; do
     [ -f "$d/.git/HEAD" ] || continue
     printf '%s\n' "$d"
   done)
   ```

   If any are found, prompt **once per session**:

   ```
   Found <N> cache entries in the old flat layout.
   Relocate to ~/.cache/skill-engine/git-managed/? This is a one-shot
   mv (local-only, not committed). Decline to re-clone on next REFRESH.
   [y/N]
   ```

   On `y`: `mv` each entry into `git-managed/`. On `n`: skip; the
   existing re-clone path handles cache miss on next REFRESH. The
   user's choice is not persisted — the prompt fires next REFRESH if
   any flat entries remain.

1.6. **verify.sh template drift detection.** REFRESH compares the live
   `$CTX_ROOT/verify.sh` against the engine's current template at
   `$CLAUDE_PLUGIN_ROOT/engine-bootstrap-templates/verify.sh` via byte-for-byte
   SHA-256 equality. Neither file embeds timestamps, machine-specific paths,
   or RCS-keyword drift sources, so the SHA is content-stable across machines
   and runs. The drift check is shared with DISCOVER; both routes funnel into
   the same staging-gate handoff so re-stamping is visible in the user's
   `REVIEW.md` disagreement set instead of silently overwriting.

   ```bash
   engine_template="${CLAUDE_PLUGIN_ROOT:-}/engine-bootstrap-templates/verify.sh"
   if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ] || [ ! -f "$engine_template" ]; then
     # Fallback: walk the conventional plugin install candidates.
     for cand in "$HOME/.claude/plugins/skill-engine" "$HOME/.claude/local/plugins/skill-engine"; do
       if [ -f "$cand/engine-bootstrap-templates/verify.sh" ]; then
         engine_template="$cand/engine-bootstrap-templates/verify.sh"
         break
       fi
     done
   fi
   ```

   Three cases:

   - **Engine template unreachable** (plugin uninstalled but stamped skill
     remains — degenerate, reachable). Skip the drift check silently; emit
     one N/A line in the post-run summary's Coverage report
     (`verify.sh template drift check skipped — engine template unreachable`).
     Do not abort the run.
   - **Live `verify.sh` absent** (first-run regeneration: user ran
     `engine-bootstrap` but not yet `discover`/`refresh`). Emit the engine
     template into `$CTX_PROPOSED/verify.sh` unconditionally; the manifest
     entry is `{status: "added", sha_before: null, sha_after: <content-hash-of-engine-template>}`,
     matching the manifest's null-field convention for `added` entries. The
     `sha_*` fields use the same content-hash form (7-char prefix) the rest
     of the manifest uses — see `discover/SKILL.md` § Staging directory for
     the manifest example. The SHA-256 used for the equality comparison
     above is the engine-internal signal; the manifest's `sha_*` fields are
     the user-visible record.
   - **Live `verify.sh` present and SHAs differ.** Write the engine template
     to `$CTX_PROPOSED/verify.sh`; the manifest entry carries
     `{status: "modified", sha_before: <content-hash-of-live>, sha_after: <content-hash-of-engine-template>}`.

   When drift is staged, the disagreement set in `REVIEW.md` Step 2 SHOULD
   include the re-stamp as one surfaced item (the magnitude-ranking heuristic
   places mechanism drift between scope changes and
   zero-impact items). The `verify.sh` run REFRESH executes against the
   proposed tree (`Post-run summary` below) runs against the **new**
   `verify.sh` — the new template must pass its own checks against the
   proposed tree, or staging is aborted with a diagnostic.

   REFRESH MUST NOT write directly to `$CTX_ROOT/verify.sh` under any
   code path. Every re-stamp flows through the staging gate.

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
transitions to `$CTX_PROPOSED/research/source-paths.json`. The first
time this run needs to record a transition, seed the proposed file as
a copy-on-write of the live file before mutating it:

```bash
if [ ! -f "$CTX_PROPOSED/research/source-paths.json" ]; then
  mkdir -p "$CTX_PROPOSED/research"
  cp "$CTX_ROOT/research/source-paths.json" "$CTX_PROPOSED/research/source-paths.json"
fi
# …then apply the transition to the proposed file.
```

The manifest records `source-paths.json` as `modified`. The lifecycle
transitions you detect are part of the proposal the user reviews;
promoting them silently to the live tree before review would defeat
the staging-dir model. Conservative default: any non-zero probe exit
maps to `unknown`, not `removed`. Auto-flipping `archived` is
prohibited — the user sets it.

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

## Phases

The four phases below give REFRESH a concrete sequential shape after
pre-flight. Run them in order; each phase's outputs feed the next.

### Phase 1 — HEAD probe (kind-dispatched)

| Kind | Probe command | Records to lifecycle |
|---|---|---|
| `git-managed` | `git ls-remote --heads -- <url> <branch>` | `last_checked_sha` = first column |
| `web-doc` | `HTTP HEAD <url>` | `last_checked` = now; if redirect → `state: "moved"`, `proposed_url` set; if 4xx → `state: "removed"` |
| `external-doc` | n/a (local content) | n/a |
| `local-path` | n/a (local content) | n/a |

For `web-doc`, use WebFetch or the available MCP fetch tool with HTTP
HEAD if supported; fall back to GET with body discarded if the tool
doesn't expose HEAD. Conservative default: any non-zero probe exit maps
to `lifecycle.state: "unknown"`, NOT `"removed"`.

For `git-managed` probes, the tool-choice guidance in "Tool preference
for git-managed sources" below (gh/git CLI over WebFetch; how to pick
`<ref>` when `branch` is present vs. absent) applies.

### Phase 2 — Decay check (web-doc only)

For each `web-doc` source with `status: "confirmed"` and a cached
snapshot:

1. Read `_crawl-manifest.json`'s `crawl_date` and the source's `decay`
   value (from any of the snapshot file's frontmatter — they should all
   match; use the first).
2. Compute `expires_at = crawl_date + decay`. If `decay == "none"`,
   skip (crawl-once).
3. If `now > expires_at`, mark the source for re-crawl.

Prompt the user **once per session** with the full list of expired
sources:

```
<N> web-doc sources are past their decay budget:
  - <source_id_1> (crawled <D1>, decay <X1>, <Y1> overdue)
  - <source_id_2> ...

Re-crawl now? [y/N/individual]
```

`individual` mode prompts per-source.

### Phase 3 — Apply (re-crawl + diff surfacing)

For each web-doc source approved for re-crawl:

1. Execute the bootstrap Step 3.6 crawl procedure with the same source
   config (sitemap discovery, filters, budget, robots).
2. Compute the new `crawl_id` from the fresh page set.
3. If `new_crawl_id == old_crawl_id`, no content changed — update
   `lifecycle.last_checked` only, discard the new tmp directory.
4. Otherwise, compute diff:
   - **Added pages**: in new manifest, not in old.
   - **Removed pages**: in old manifest, not in new.
   - **Changed pages**: same URL, different content_hash.
5. Update `lifecycle.last_crawl_id` to the new value.
6. Surface in the REFRESH closing line:

```
web-doc source <source_id>:
  +<A> pages added (consider covering in references)
  -<R> pages removed (review references citing these for cut_block)
  ~<C> pages changed (references citing these need content_hash update)

Old snapshot at ~/.cache/skill-engine/web-doc/<source_id>-<old_id>/
retained pending reference review.
```

7. Cache GC: defer deletion of the old `<old_id>` directory until no
   active reference cites a content_hash inside it. The next REFRESH
   sweeps unreferenced old directories.

### Phase 4 — Cache GC pass (web-doc only)

After all re-crawls complete, walk
`~/.cache/skill-engine/web-doc/<source_id>-*/` for each source. For each
directory that is NOT the source's current `lifecycle.last_crawl_id`,
check whether any reference file in the contextualizer cites a
content_hash present in that directory's `_crawl-manifest.json`:

```bash
# Pseudocode: for each old crawl directory, grep all references for any
# content_hash listed in its manifest. If zero hits, it's GC-eligible.
```

GC-eligible directories are listed in the REFRESH summary; user
confirms before deletion. (Aligns with the "engine does not act without
consent" doctrine — old caches stay until the user OKs removal.)

The git-managed cache GC rules in "Cache garbage collection" below are
complementary: Phase 4 covers `web-doc/` only.

## Tool preference for git-managed sources

For each source with `kind: git-managed`, prefer the `gh` and `git`
command-line tools over WebFetch:

- `gh repo view <owner>/<repo>`,
- `gh api repos/<owner>/<repo>/commits/<ref>`,
- `git ls-remote -- <url> <ref>`, `git ls-tree --recursive <ref>`,
- `git show <ref>:<path>`.

The CLIs return clean structured output; WebFetch returns rendered HTML
that consumes roughly 10× more tokens to parse. Reserve WebFetch for
`kind: external-doc` or git sources where CLI access fails.

The `--` in the `git ls-remote` probes terminates option parsing so a `url`
beginning with `-` cannot be read as a flag (e.g. `--upload-pack=…`) — the same
argument-injection guard the engine-bootstrap and DISCOVER clone flows use.

**Which `<ref>` to use.** If the source entry carries a `branch` field,
that branch is `<ref>` everywhere above (e.g., `gh api
repos/<owner>/<repo>/commits/dev`, `git ls-remote -- <url> dev`). If the
`branch` field is absent, fall back to `HEAD` — `gh api
repos/<owner>/<repo>/commits/HEAD`, `git ls-remote -- <url> HEAD`. A branch
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

Before rendering the summary, finalize the staging directory. The proposed
tree is a sparse copy-on-write, so verify against an **ephemeral merged tree**
(live overlaid with this run's changes and the manifest's removals applied),
not against `$CTX_PROPOSED/` directly — the exact procedure and bash are in
`discover/SKILL.md` § Post-run summary. Confirm `verify.sh` exits 0 against
that merged tree, then write `$CTX_PROPOSED/.review/manifest.json` per the
schema and stamping convention documented in `discover/SKILL.md` § Staging
directory. A non-zero `verify.sh` exit aborts the proposed-dir write with a
diagnostic; the user never sees a `REVIEW.md` for a broken proposal.

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

4. **Staging-dir handoff line** (always last, even for no-op runs).
   Render one line naming the proposed directory and the three
   review/apply/discard commands:

   ```
   Proposal staged at <slug>-context.proposed/. Run /skill-engine:review <slug> to inspect, /skill-engine:apply <slug> to promote, /skill-engine:discard <slug> to throw away.
   ```

   `<slug>` is the contextualizer slug without the `-context` suffix.

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
