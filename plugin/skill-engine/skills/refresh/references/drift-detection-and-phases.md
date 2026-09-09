# Drift detection and phases

The pre-flight guards and migrations REFRESH runs before touching any source, plus the four-phase probe it runs against every in-scope source.

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

1.1. **`probe_budget` validation.** Read the root-level `probe_budget`
   field, if present. It MUST be a JSON integer ≥ 1; a value of `0`, a
   negative integer, or a non-integer (a string, a float with a
   fractional part) fails REFRESH at activation — before any network
   call — naming both the field and the offending value:

   ```
   probe_budget is invalid: <value> (must be a JSON integer ≥ 1). Fix research/source-paths.json and re-run.
   ```

   Exit non-zero. Absent `probe_budget` is valid and means: re-read all
   promoted sources every session (no cap).

1.5. **Cache layout migration (one-time).** Earlier engine versions
   stored git-managed clones flat at
   `~/.cache/skill-engine/<source_id>-<sha>/`. <!-- doctrine:legacy-cache-layout -->
   The current layout is
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

2.5. **Hint passthrough.** A `--hint='<hint>'` argument provides extra
   context for the current session (e.g., `--hint='I think
   packages/foo's reference is stale even though SHA matched'`,
   `--hint='re-check the migration guide pages'`). Treat hints as
   authoritative author input that shapes this run's refresh emphasis —
   the same contract as `discover/SKILL.md` § Hint passthrough.

3. **Idempotency check (no-op gate).** Before re-reading any source,
   check `research/.discover-cache.json` (gitignored runtime state)
   against current upstream SHAs. If every in-scope source's SHA is
   unchanged since its last cache entry AND every source still has
   `lifecycle.state ∈ {reachable, unknown}` since last run AND no
   `--hint` argument was supplied this run, summarize "no work to do"
   in the post-run summary and exit cleanly. Repeated REFRESH
   invocations against an unchanged corpus should not churn. (A hint
   always overrides the gate — it signals the author wants a re-look
   at fixed inputs, which is exactly the rerun this skill's post-run
   summary invites.)

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

**Lifecycle state.** For each in-scope source, decide whether its
upstream is still `reachable`, `moved`, `removed`, or `unknown` (see
[`02-artifact-contract.md`](../../../docs/02-artifact-contract.md) for the four-state field). Write
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

**Lifecycle sweep.** If a transition would affect existing reference
files or the navigator (a `moved` URL is cited; a `removed` source is
referenced), emit a lifecycle sweep dry-run per [`04-delivery.md`](../../../docs/04-delivery.md).
The user accepts or rejects the sweep through the protocol documented
there (proposal-token + per-file SHA integrity gates). The engine
does not auto-mutate references on lifecycle transition.

## Phases

The phases below give REFRESH a concrete sequential shape after
pre-flight. Run them in order; each phase's outputs feed the next.

### Phase 0.5 — Archive detection (git-managed, forge-dispatched)

For every in-scope `git-managed` source, read the forge's archived flag
with one read-only API call before Phase 1 runs, dispatched by URL
host:

| Host | Read | Field |
|---|---|---|
| `github.com` | `gh api repos/<owner>/<repo>` | `.archived` |
| Any other host `gh` resolves (GitHub Enterprise) | `GH_HOST=<host> gh api repos/<owner>/<repo>` | `.archived` |
| GitLab (host contains `gitlab`) | a read-only `GET /api/v4/projects/<url-encoded path>` via WebFetch or the available MCP fetch tool | `.archived` |
| Anything else (Bitbucket, Azure DevOps, a `gh`-unresolvable host, …) | not called | n/a — `unknown` |

Every host outside the first three rows is `unknown`: no call is made
and no transition is staged. Both reads are unauthenticated: no token
is passed to `gh api`, and no token is passed to the GitLab read — both
hit the host's own public API (the engine does not perform HTTP itself
— see "Tool preference for git-managed sources" below).

When the flag is `true`, stage the transition using the copy-on-write
recipe above (**Lifecycle state**): write `archived: true` for that
source into `$CTX_PROPOSED/research/source-paths.json`, seeding the
proposed file first if this run hasn't staged a write yet. The manifest
records `source-paths.json` as `modified`. The live file is untouched
until `/skill-engine:apply` promotes the proposal — REFRESH never flips
`archived` live.

When the flag is `false`, or the host is `unknown`, no transition is
staged. State the number of sources checked and the number unknown in
the post-run summary: `<N> sources checked, <M> unknown-host (not
counted against N)`.

A source already `archived: true` in the live file was already excluded
before Phase 0.5 runs (Pre-flight step 4, "Identify in-scope sources").
A source archived only by a pending, unapplied proposal is still
`archived: false` in the live read baseline and is still probed here
and at Phase 1.

### Phase 1 — HEAD probe (kind-dispatched)

| Kind | Probe command | Records to lifecycle |
|---|---|---|
| `git-managed` | `git ls-remote --heads -- <url> <branch>` | `last_checked_sha` = first column |
| `web-doc` | `HTTP HEAD <url>` | `last_checked` = now; if redirect → `state: "moved"`, `proposed_url` set; if 404/410 → `state: "removed"`; any other 4xx (401/403/429…) → `state: "unknown"` |
| `external-doc` | n/a (local content) | n/a |
| `local-path` | n/a (local content) | n/a |

For `web-doc`, use WebFetch or the available MCP fetch tool with HTTP
HEAD if supported; fall back to GET with body discarded if the tool
doesn't expose HEAD. Conservative default: any non-zero probe exit maps
to `lifecycle.state: "unknown"`, NOT `"removed"`. The conservative
default takes precedence over the probe table above: only 404 and 410 —
the statuses that assert the resource is gone — map to `removed`. An
auth wall (401/403) or rate limit (429) is a transient condition, and
`removed` permanently drops the source from refresh scope.

For `git-managed` probes, the tool-choice guidance in "Tool preference
for git-managed sources" below (gh/git CLI over WebFetch; how to pick
`<ref>` when `branch` is present vs. absent) applies.

When the newly-probed SHA differs from the source's previously-recorded
`last_checked_sha` **and** a local cache directory already exists for that
source, run the in-place advance recipe in "Tool preference for
git-managed sources" below § Cache garbage collection, with `<old_sha>` =
the prior recorded `last_checked_sha` and `<new_sha>` = this probe's
result, before continuing to Phase 2. REFRESH never clones on its own
("Source materialization" in `cache-and-clone.md` names only DISCOVER
pre-flight step 6 and `engine-bootstrap` Step 3.5 as consent points), so
when no local cache exists for the source, REFRESH's existing CLI fallback
is unchanged.

**Promotion and ordering.** After Phase 1 completes for every in-scope
source, the `git-managed` sources whose newly-probed SHA differs from
their previously-recorded `last_checked_sha` (see above) are
*promoted* — they are candidates to proceed to Re-read scoping.
Promoted sources are ordered by descending `importance` (absent ⇒ 3);
ties are broken by oldest recorded probe timestamp first
(`lifecycle.last_checked`, missing ⇒ treated as `1970-01-01T00:00:00Z`
so never-probed sources sort to the front); further ties are broken by
ascending source `id`. The ordering recipe:

```jq
.sources | sort_by([-(.importance // 3), (.lifecycle.last_checked // "1970-01-01T00:00:00Z"), .id]) | .[].id
```

When `probe_budget: N` is set, the budgeted step is the re-read, never
the Phase 1 probe: the budget bounds model-token cost, not network
cost, so the cheap `git ls-remote`/HTTP HEAD check above always runs
for every in-scope source. At most N promoted sources — in the order
above — proceed to Re-read scoping; every in-scope source is still
probed regardless of `probe_budget`.
Sources beyond the budget are explicitly skipped, not silently
dropped — render once, in the post-run summary's Coverage report:

```
"M of K sources skipped this session due to probe_budget=N (next-eligible: <list>)"
```

No skip line is printed absent `probe_budget`: every promoted source
proceeds, in the order above.

### Re-read scoping (git-managed)

Before re-reading or re-emitting any reference, read the re-emit candidate
set `cited_paths.py` prints:

```bash
python3 "$CLAUDE_PLUGIN_ROOT/tests/cited_paths.py" <references-dir> --changed research/.discover-inventory.json
```

Scope the re-read to the candidate references the output names plus the
uncited changes (`.uncited_changes.paths`) — the parts of the corpus this
run's changed-path signal actually covers. If the model re-emits a
non-candidate reference anyway, state a reason for it in the post-run
summary.

Skip this step — there is no candidate set to read — when
`research/.discover-inventory.json` does not exist or carries no source's
`since_last_check`: no git-managed source's cache advanced this run, so
there is no changed-path signal to scope against.

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
