# 08-DISCOVER pipeline

DISCOVER scans the sources registered with the engine and writes
reference files for the parts that matter. The engine hands the model
a task; the model executes it; `verify.sh` plus the permalink-density
lint and the reviewer are the trust mechanism. Of the four reference
invariants, `verify.sh` mechanically checks depth-1 (inside its
`catalog-bijection` check) and the lint checks SHA-pinning; first-5K
and the long-reference TOC are authoring discipline the reviewer
backstops.

## The goal

When `/skill-engine:discover` runs:

> **Discover the essence of the registered sources. Write reference
> files for the parts that matter. Satisfy the four reference
> invariants (first-5K, depth-1, max-100-line-TOC, SHA-pin). Use any
> procedural reasoning you find appropriate; the engine validates
> output via `verify.sh`.**

No Stage 1/2/3 worker dispatch. No fixed keystroke menu. No
prescribed importance-scan signals, commodity-filter rules, or
companion-discovery decision tree. The model varies its approach by
what the corpus rewards.

## Output contract

Two things, both load-bearing:

1. **Reference files in `references/`.** Each cites its source by
   path plus content-hash. Each satisfies the four invariants
   documented in [`02-artifact-contract.md`](02-artifact-contract.md).
2. **A post-run summary** for the author — paragraph-form,
   ≤30 lines, four components:
   - **Coverage report.** What was read; what references emit; what
     each reference covers. Cite content by path+content-hash.
   - **Skip-reasoning.** Files and companion sources that were
     considered but excluded, with reasons. Empty-skip case
     allowed ("Nothing of note was skipped.").
   - **Proposed companions.** Companion sources surfaced this run
     with `status: "proposed"` in `source-paths.json`. One line per
     proposal: what was proposed, why (one-sentence rationale from
     `discovered_via`), and the accept path — edit
     `source-paths.json`, flip `status` to `confirmed` or
     `rejected`, re-run `/skill-engine:discover` to crawl accepted
     sources. Empty case allowed ("No companions surfaced this
     run.").
   - **Creative-input gesture.** End with the invitation to rerun
     with a hint: `/skill-engine:discover --hint='<your hint>'`.

### Paragraph→permalink density

Every prose paragraph in an emitted reference must have a SHA-pinned
GitHub permalink within 5 lines (above, below, or inside the paragraph).
The permalink shape is `https://github.com/<owner>/<repo>/blob/<40-hex-sha>/<path>` —
stable version tags like `v1.2.3` are accepted equivalently; unpinned
`blob/main/...` URLs do not satisfy the requirement. SELF-AUDIT Check 7
enforces ≥80% paragraph→permalink coverage corpus-wide; emit references
with substantially higher per-file coverage so the corpus aggregate has
headroom.

This makes the structural-honesty claim downstream documentation makes —
that any paragraph without a nearby permalink should be treated as
unverified — mechanically true. The cost is one extra source-repo
pointer per paragraph; the alternative is unverifiable curation.

### Proposal threshold

The approval gate is the filter, not the agent. A candidate that is
plausibly in-domain belongs in **Proposed companions**, not
Skip-reasoning — even if the agent would recommend against accepting
it.

Recommend-against proposals (the canonical case is different-language
ports of the same domain) carry an explicit `recommend: reject` line
in their rationale. The pattern generalises: documentation-only
mirrors, layered packages that re-export a sibling's public surface,
and other near-domain candidates whose inclusion would muddy
invocation belong in the same shape — proposed, with the recommend-
against reasoning made plain. Skip-reasoning is reserved for clear
non-fits: off-domain repos, accidental name collisions,
archived/abandoned candidates. Erring toward propose keeps the user
in control of the catalog's edges; erring toward skip strips that
control without the user ever seeing the call.

`verify.sh` is the gate. Two sessions on the same corpus may produce
different reference counts, different topical partitions, different
prose styles — variance below the invariant floor is acceptable and
expected.

## Persisted state

`research/source-paths.json` carries a thin per-source schema:
`id`, `kind`, `lifecycle`, at least one of `url`/`path`, the `status`
enum when present, and any additive fields (`archived`,
`discovered_via`, etc.). No per-source sub-region granularity layer is
persisted — citations resolve by `(source_id, path, sha)` triple
directly. Legacy contextualizers carrying `sources[i].chunks[]` are
migrated transparently on first REFRESH (one-shot, lossy: chunks data
dropped, sources data preserved).

`research/.discover-cache.json` carries the per-source-SHA cache.
Cache hit → replay prior enrichment. Cache miss → read the source,
write the result under `(source_id, sha)`. DISCOVER and REFRESH both
consume this layer.

## Lifecycle handling

For each in-scope source, the model decides whether its upstream is
still `reachable`, `moved`, `removed`, or `unknown`. Transitions are
written to `source-paths.json` immediately. When a transition would
affect existing reference files or the navigator (a `moved` URL is
cited; a `removed` source is referenced), the model emits a lifecycle
sweep dry-run per [`04-delivery.md`](04-delivery.md). The
proposal-token + per-file SHA gates protect against drift between
propose-time and apply-time. Conservative default: any non-zero probe
exit maps to `unknown`, not `removed`. The user sets `archived: true`
manually; the engine never auto-flips it.

## Tool preference

For `kind: git-managed` sources, the model prefers `gh repo view`,
`gh api repos/<owner>/<repo>/contents/<path>?ref=<ref>`, `git ls-tree
--recursive <ref>`, and `git show <ref>:<path>` over WebFetch. The CLIs
return clean structured output; WebFetch returns rendered HTML that
consumes ~10× more tokens to parse. Reserve WebFetch for `kind:
external-doc` or git sources where CLI access fails.

The `<ref>` token resolves from the source-paths.json entry: if the
entry carries a `branch` field, that branch is the ref; otherwise the
ref is `HEAD`. Reference SHAs cite the resolved commit on the tracked
ref, not the repo-wide default — a contextualizer monitoring a `dev`
branch never quietly references main-branch commits. The field
schema and regex enforcement live in
[`02-artifact-contract.md` §"source-paths.json entry shape"](02-artifact-contract.md#source-pathsjson-entry-shape).

For large `kind: git-managed` sources, the engine offers to seed a
local clone at `~/.cache/skill-engine/<source_id>-<sha>/`. The offer is
**consent-gated, not automatic**: `engine-bootstrap` Step 3.5 prompts
once per git-managed source at scaffold time, and DISCOVER's pre-flight
step 6 re-prompts on cache miss (declined at bootstrap, deleted via
`/skill-engine:clean-cache`, source added later). On `y`, the skill
runs the documented `git clone --depth=1 --filter=blob:none` itself; on
`N` or any non-`y` reply, the cache remains absent and DISCOVER falls
back to the `gh`/`git` tool preference above. The user may also clone
manually at any time, or choose a different cache location — the
prompts are a convenience over manual `git clone`, not a replacement
for it (see [`plugin/skill-engine/skills/engine-bootstrap/SKILL.md`](plugin/skill-engine/skills/engine-bootstrap/SKILL.md)
for the per-source clone shape).

For `kind: web-doc` sources, the same pre-flight Step 6 dispatches
to a kind-aware probe — a bare directory match under
`~/.cache/skill-engine/web-doc/<source_id>-*/` is sufficient for a
cache hit (web-doc snapshots carry no `.git/` to validate). On a miss,
the user is prompted **once per source** to crawl the upstream site
into the cache; on consent the skill runs the bootstrap Step 3.6 crawl
procedure inline (sitemap fetch, page-budget enforcement, atomic
rename into `~/.cache/skill-engine/web-doc/<source_id>-<crawl_id>/`);
on decline the source is sticky-skipped for this DISCOVER session
(no upstream live read substitutes for the missing snapshot — the
post-run summary records an explicit "no cache, no read" notice
naming the source). The canonical wording for both prompts and the
full kind-dispatch flow lives in
[`plugin/skill-engine/skills/discover/SKILL.md`](plugin/skill-engine/skills/discover/SKILL.md)
pre-flight step 6; this chapter summarizes rather than duplicates.

The clone cache persists across runs; REFRESH garbage-collects stale
per-`source_id` SHA directories on SHA advance, STATUS surfaces what is
on disk, and `/skill-engine:clean-cache` is the opt-in all-at-once
deletion path. See [`09-discover-config.md`](09-discover-config.md)
§"Cleanup contract" for the full mechanism. The four cache lifecycle
stages — seed (consent-gated at bootstrap and DISCOVER pre-flight),
REFRESH GC, STATUS, and clean-cache — are named, not counted; see
[`09-discover-config.md`](09-discover-config.md) §"Optional local clone
cache" for the seed half.

## Corpus-coverage heuristics

The contextualizer-bundled `research/verify.sh` (stamped by
`/skill-engine:engine-bootstrap` from
`plugin/skill-engine/engine-bootstrap-templates/verify.sh`) carries
three corpus-coverage heuristics that surface concerns to the
contextualizer-author without rejecting the corpus:

- **`monorepo-coverage`** — when a source root contains workspace
  members (`packages/*`, `apps/*`, `libs/*`, `crates/*`), each top-level
  member should have ≥1 reference citing it OR an explicit
  skip-reason in the post-run summary.
- **`companions-coverage`** — proposed companion sources should have
  references OR explicit skip-reasons.
- **`catalog-density`** — when a source root contains ≥20 files, the
  catalog should carry ≥3 rows for that source OR a minimal-essence
  justification in the post-run summary.

All three emit `[WARN]` (not `[FAIL]`); the reviewer remains the
backstop trust mechanism. The same three heuristics live in the
contextualizer-side `verify.sh` the plugin stamps at bootstrap
(`plugin/skill-engine/engine-bootstrap-templates/verify.sh`), so the
same heuristics are available in the contextualizer's `verify.sh`, run on
demand by the user or CI.

## Cadence

DISCOVER runs when the user invokes it — no daemon, no cron. Typical
rhythm: quarterly for mature contextualizers; on-demand when the
catalog-vs-asks gap is widening; opportunistically for fresh
contextualizers (first runs are welcome).

## Companion doctrine

DISCOVER may surface companion sources during a session — second-order
references (dependencies, related ecosystems, upstream tools) the
model believes deserve their own reference. The doctrine:

- **Single-hop limit.** DISCOVER does not recurse on companions past
  depth-1. Companions of companions are deferred to a later DISCOVER
  invocation against the companion as a registered source.
- **Top-level peers, not nested.** Each surfaced companion lands as a
  new top-level `sources[]` entry. `discovered_via[]` carries
  provenance (parent source id, depth, discover run, signal).
- **User accepts or rejects.** Companions begin at
  `status: "proposed"`; promotion to `confirmed` requires user
  acceptance through the workflow's approval gate. Rejected
  companions remain in the file with `status: "rejected"` for
  re-proposal-TTL bookkeeping.

## What DISCOVER does NOT do

- It does not auto-clone proposed companion sources. The author runs
  `git clone` themselves.
- It does not recurse companion discovery past depth-1.
- It does not parse lockfiles (`package-lock.json`, `Cargo.lock`,
  `go.sum`). Manifests are input to the model's reasoning, not an
  enforced schema.
- It does not do live registry calls for commodity filtering by
  default.
- It does not auto-detect "archived" upstream state.
- It does not track inner-path changes on `moved` sources. The outer
  URL is rewritten on accept; inner-path drift is flagged.
- It does not auto-rewrite SHA-pinned URLs on moved sources to point
  at the new host's equivalent SHAs.

## Cross-references

- [`02-artifact-contract.md`](02-artifact-contract.md) — the four
  reference invariants; `source-paths.json` thin schema;
  reference shape contract.
- [`04-delivery.md`](04-delivery.md) — when to add DISCOVER;
  lifecycle sweep dry-run semantics.
- [`09-discover-config.md`](09-discover-config.md) — configuration
  surface for `source-paths.json` and the optional cache.
- [`11-walkthrough.md`](11-walkthrough.md) — end-to-end example.
