# 09-DISCOVER config

[08-discover-pipeline.md](08-discover-pipeline.md) covers what DISCOVER
does. This chapter covers the persisted state that DISCOVER reads and
writes: `research/source-paths.json` (the thin per-source schema) and
`research/.discover-cache.json` (the per-source-SHA cache).

The canonical field reference is in
[`02-artifact-contract.md`](02-artifact-contract.md) §"Per-source schema";
this chapter is the operational view (where the files live, how
DISCOVER and REFRESH read and write them, what the cache contract is).

## `research/source-paths.json`

The single configuration file the engine reads at every DISCOVER and
REFRESH invocation. Lives next to `research/.research-state.json`.
Stamped empty by `/skill-engine:engine-bootstrap`; populated by intake
and updated by DISCOVER as new sources surface.

### Shape (thin per-source schema)

```json
{
  "schema_version": 1,
  "sources": [
    {
      "id": "<computed-slug>",
      "kind": "git-managed",
      "url": "https://github.com/<org>/<repo>",
      "status": "confirmed",
      "archived": false,
      "lifecycle": {
        "state": "reachable",
        "last_checked": "2026-05-11T14:23:00Z",
        "last_checked_sha": "abc1234",
        "proposed_url": null
      },
      "discovered_via": null
    }
  ]
}
```

Required fields on every entry: `id`, `kind`, `lifecycle.state`, at
least one of `url`/`path`. The `status` enum is validated when present.
`archived`, `discovered_via`, and any other additive fields are
tolerated (additive schema evolution).

### `kind` discriminators

The `kind` field names the harvest treatment the engine applies. Four
values are accepted; the canonical schema for each lives in
[`02-artifact-contract.md`](02-artifact-contract.md):

| `kind` | What it harvests | Required schema fields beyond the base | Canonical doctrine |
|---|---|---|---|
| `git-managed` | Git-hosted source code. `url` required. | optional `branch` | [`02-artifact-contract.md` §"source-paths.json entry shape"](02-artifact-contract.md#source-pathsjson-entry-shape) |
| `external-doc` | Pre-curated `.md` content outside any code repo. `path` required (directory or single file). | `.md` files carry provenance frontmatter (`source_url`, `crawl_date`, `decay`) | [`02-artifact-contract.md` §"`kind: "external-doc"`"](02-artifact-contract.md#external-doc-sources-on-source-pathsjson) |
| `web-doc` | Documentation-site content acquired via WebFetch or MCP fetch. `url` and `crawl_mode` required. | `sitemap_url` (sitemap mode, optional) or `page_list` (list mode, required); optional `crawl_filters`, `crawl_budget`; `branch` rejected | [`02-artifact-contract.md` §"`kind: "web-doc"`"](02-artifact-contract.md#kind-web-doc) |
| `local-path` | Non-git local-filesystem source. `path` required. | none | [`02-artifact-contract.md` §"source-paths.json entry shape"](02-artifact-contract.md#source-pathsjson-entry-shape) |

Each `kind` has its own cache layout under
`~/.cache/skill-engine/<kind>/<source_id>-<discriminator>/`; see
[`03-engine.md` §"Cache layout"](03-engine.md#cache-layout-per-kind-subdirectories)
for the full per-kind directory shape.

**Optional `branch`** (`kind: "git-managed"` only). Names the upstream
ref REFRESH and DISCOVER track. Absent ⇒ HEAD. Set this when the
contextualizer follows a non-default branch like `dev`, `nonprod`, or
`release/v2`. See
[`02-artifact-contract.md` §"source-paths.json entry shape"](02-artifact-contract.md#source-pathsjson-entry-shape)
for the field doctrine and the regex the contextualizer verify.sh
enforces.

### Migration from the chunked schema

Earlier engine versions persisted a `sources[i].chunks[]` granularity
layer. That layer has retired. Citations now resolve by
`(source_id, path, sha)` triple directly; reference files carry the
content hash inline.

Legacy contextualizers carrying `sources[i].chunks[]` are migrated
transparently by REFRESH on first invocation post-upgrade. The
migration is one-shot and lossy: the `chunks[]` arrays are dropped
from every entry; every other field is preserved verbatim. REFRESH
logs `Migrated N sources[] entries to thin schema (chunks[] dropped).`
and continues without prompting. No user action required.

## `research/.discover-cache.json`

The per-source-SHA cache. DISCOVER and REFRESH both consume it.
Lookup key: `(source_id, sha)`. A cache hit replays prior enrichment
without re-reading the source; a cache miss reads the source, derives
the enrichment, and writes the result under the tuple key.

```json
{
  "schema_version": 1,
  "enrichments": {
    "<source_id>": {
      "<sha>": { /* per-source-SHA enrichment payload */ }
    }
  }
}
```

The cache is the persistence layer that absorbs REFRESH economics —
re-running REFRESH against a corpus where most sources haven't changed
upstream amortizes cheaply (cache hits everywhere) rather than
re-deriving the world.

### Cache GC

On every DISCOVER and REFRESH invocation, the workflow enumerates the
active set of `source_id`s from `source-paths.json` and drops any
`.discover-cache.json` `enrichments.<source_id>` entry whose
`source_id` is no longer in the active set. This bounds growth and
prevents stale enrichments from a since-removed source persisting.

## Optional local clone cache

For large `kind: git-managed` sources, DISCOVER reads more efficiently
from a local clone than from remote `gh`/`git` calls. The recommended
cache location is:

```
~/.cache/skill-engine/<source_id>-<sha>/
```

This follows the XDG cache-directory convention (`~/.cache/<tool>/`)
used by `gh`, `cargo`, and most modern CLI tooling on macOS and Linux.

The engine does not clone without consent. Two y/N prompts (default N)
populate the cache: `engine-bootstrap` Step 3.5 (per `kind: git-managed`
source at scaffold time) and DISCOVER pre-flight step 6 (re-prompt on
cache miss for an in-scope git-managed source). On `y`, the skill
clones via an atomic-rename idiom (`<source_id>-<sha>.tmp.$$/` → `mv`
to the canonical name on success); on `N` or anything else, the cache
stays absent and reads fall back to `gh`/`git` CLI calls. The user may
also clone manually at any time or pick a different cache location.
See
[`plugin/skill-engine/skills/engine-bootstrap/SKILL.md`](plugin/skill-engine/skills/engine-bootstrap/SKILL.md)
§"Step 3.5 — Offer to seed local cache" and
[`plugin/skill-engine/skills/discover/SKILL.md`](plugin/skill-engine/skills/discover/SKILL.md)
pre-flight step 6 for the per-source clone shape.

### Cleanup contract

The clone cache is persistent — DISCOVER and REFRESH leave it on disk
between runs so subsequent passes amortize fetch cost. Three skills
coordinate its cleanup (seeding is the entry stage, covered above):

* **REFRESH** garbage-collects on SHA advance. After REFRESH
  successfully populates `~/.cache/skill-engine/<source_id>-<new-sha>/`
  for a source whose SHA changed, it deletes sibling
  `~/.cache/skill-engine/<source_id>-*/` directories whose suffix is
  not the new SHA. Guards: GC runs only when the SHA actually advanced
  and the new directory is non-empty; never touches anything outside
  the cache root; never follows symlinks; never deletes the cache root
  itself.
* **STATUS** surfaces the cache as a read-only listing — each
  `<source_id>-<sha>/` directory with size and last-access date.
  STATUS never deletes. If multiple `<source_id>-*/` directories exist
  for the same `source_id` (i.e., older SHAs were not GC'd because
  REFRESH has not run yet), STATUS flags them as a hint.
* **`/skill-engine:clean-cache`** is the opt-in, all-at-once deletion
  path. It dry-runs first (lists size + last-access for every cached
  directory and asks for confirmation); deletes only when the user
  replies with the literal word `yes`. Scope is hard-bounded to
  `${XDG_CACHE_HOME:-$HOME/.cache}/skill-engine/*/` — the script
  substitutes that path verbatim and refuses user-supplied paths.
  Suitable when a contextualizer is finished, the user has rotated
  projects, or disk usage is the primary concern.

Nothing in DISCOVER, REFRESH, or any other workflow invokes
`clean-cache` automatically. The deletion gesture is reserved for the
user.

## File permissions and discipline

`source-paths.json` is committed to git — its evolution is the
configuration history of the contextualizer and every transition the
engine performs should be reviewable in a PR.

`.discover-cache.json` is gitignored runtime state (alongside other
dot-prefixed `research/*.json` files like `.research-state.json`,
`.engine-stats.json`, and `.rejection-log.json`). It rebuilds on
demand; cold-cache REFRESH is acceptable and cheap per the per-source-
SHA contract documented in [`02-artifact-contract.md`](02-artifact-contract.md).
A contextualizer-author's `.gitignore` should list `research/.*.json`
(or its narrower equivalent) to keep cache state out of public PRs.

Manual edits to `source-paths.json` are supported and expected
(adding a new source by hand, marking a source `archived: true`,
correcting a lifecycle drift the probe didn't catch). The engine
re-reads the file on every invocation; there is no in-memory shadow.
