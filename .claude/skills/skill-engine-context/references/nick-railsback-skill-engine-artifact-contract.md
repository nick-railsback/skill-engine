# The artifact contract: source registry, reference shape, and citation rules

Every deliverable the skill-engine produces — a `<area-domain>-context` skill directory — must satisfy one data contract. The contract is a spec two enforcers validate against: the contextualizer-side `verify.sh` (stamped at bootstrap) and the fixture-harness invariants suite. A deliverable that doesn't match the shape is rejected at pre-approval validation. Source: [`docs/02-artifact-contract.md` intro](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L3-L5).

The filesystem surface is small: one navigator (`SKILL.md`), a `references/` directory of cataloged primaries and bare-named companions, an optional `SKILL.json` sibling, and a `research/source-paths.json` registry. This reference summarizes the load-bearing schema fields and gotchas and points at the source docs for the exhaustive spec. Source: [`docs/02-artifact-contract.md` § The three artifacts](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L21-L41).

## Contents

* [The source registry (research/source-paths.json)](#the-source-registry-researchsource-pathsjson)
* [The four source kinds and the url-XOR-path rules](#the-four-source-kinds-and-the-url-xor-path-rules)
* [Reference files: no frontmatter, depth-1, two forms](#reference-files-no-frontmatter-depth-1-two-forms)
* [Citing sources: permalinks and provenance blocks](#citing-sources-permalinks-and-provenance-blocks)
* [SKILL.json and the trijection](#skilljson-and-the-trijection)
* [Navigator size budget at a glance](#navigator-size-budget-at-a-glance)
* [Related references](#related-references)

## The source registry (research/source-paths.json)

`research/source-paths.json` is the single config file the engine reads at every DISCOVER and REFRESH. It is a thin per-source schema: a top-level `schema_version` (integer, `const 1`) plus a `sources[]` array. It is stamped empty at bootstrap, populated at intake, and updated by DISCOVER as companion sources surface. The file is committed to git; the sibling `.discover-cache.json` (and other dot-prefixed `research/*.json`) is gitignored runtime state that rebuilds on demand. Source: [`docs/09-discover-config.md` § research/source-paths.json](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/09-discover-config.md#L13-L47), [§ File permissions and discipline](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/09-discover-config.md#L179-L196).

A single entry looks like this — the base fields are common to every kind: Source: [`docs/02-artifact-contract.md` § entry shape](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L165-L183).

```json
{
  "id": "vitejs-vite",
  "kind": "git-managed",
  "url": "https://github.com/vitejs/vite",
  "path": null,
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
```

The per-entry fields, their enums, and their jobs summarize as follows; the JSON Schema is the machine-readable transcription and the field-doctrine paragraphs are canonical. Source: [`engine-bootstrap-templates/source-paths.schema.json`](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/engine-bootstrap-templates/source-paths.schema.json#L1-L8), [`docs/02-artifact-contract.md` § field doctrine](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L185-L201).

| Field | Type / enum | Notes |
|---|---|---|
| `schema_version` | integer `const 1` | Top-level, not per-source; additive evolution keeps v1 current. |
| `id` | string, min-length 1 | Deterministic kebab-case slug from URL/path at intake; user-readable, distinct from the SHA-256-derived `source_id`. |
| `kind` | `git-managed` \| `web-doc` \| `external-doc` \| `local-path` | Names the harvest treatment (see next section). |
| `url` | string \| null | Required for `git-managed` and `web-doc`; null/empty ⇒ absent. |
| `path` | string \| null | Required for `external-doc` and `local-path`; null/empty ⇒ absent. |
| `status` | `intake` \| `proposed` \| `confirmed` \| `rejected` | Curation state-machine: how the source got in and how the user curated it. |
| `archived` | boolean, default `false` | User-set; the engine never auto-detects archival. `true` ⇒ crawl is skipped, citations treated like `removed`. |
| `lifecycle.state` | `reachable` \| `moved` \| `removed` \| `unknown` | Upstream state-machine, orthogonal to `status`. |
| `lifecycle.last_checked` / `last_checked_sha` / `proposed_url` | ISO-8601 UTC / SHA / URL-or-null | Probe timestamp, upstream HEAD SHA, redirect target for `moved`. |
| `discovered_via` | null \| array | Null on user-supplied sources; array of `{parent_source_id, depth, discover_run, signal}` on DISCOVER companions (`depth: 1`, single-hop in v1). |
| `branch` | string, `^[A-Za-z0-9._/-]+$` | `git-managed` only; absent ⇒ HEAD. Present on any other kind is a schema violation. |

Two state-machine axes are load-bearing and must never be conflated: `status` (curation) and `lifecycle.state` (upstream) describe distinct things. A `confirmed` source can go `removed` upstream without invalidating the curation; a `rejected` companion can still reach `moved`. The engine surfaces both axes separately. Source: [`docs/02-artifact-contract.md` § Two state-machine axes](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L201-L201). The required fields `verify.sh` enforces on every entry are `id`, `kind`, `url`-or-`path`, `status`, `lifecycle.state`, plus the three enum constraints. Source: [`docs/02-artifact-contract.md` § Required fields](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L199-L199).

## The four source kinds and the url-XOR-path rules

`kind` picks the harvest treatment, and it decides whether the entry is addressed by a `url` or a `path`. Git repos and doc-sites are URL-addressed; pre-curated markdown and non-git local trees are path-addressed. Source: [`docs/09-discover-config.md` § kind discriminators](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/09-discover-config.md#L49-L60).

| `kind` | Addressed by | Harvest treatment |
|---|---|---|
| `git-managed` | `url` (required) | Git-hosted source code; per-source SHA via `git rev-parse HEAD`, then sparse/shallow clone when the SHA changed. Optional `branch`. |
| `web-doc` | `url` + `crawl_mode` (required) | Doc-site content via WebFetch / MCP fetch. `crawl_mode` is `sitemap` or `list`; `sitemap_url` (sitemap-only), `page_list` (list-only, non-empty), optional `crawl_filters` / `crawl_budget` (1–5000, default 200). `branch` is rejected. |
| `external-doc` | `path` (required) | Pre-curated `.md` outside any code repo (directory scanned recursively, or a single file). NOT a bootstrap-intake kind. |
| `local-path` | `path` (required) | Non-git local-filesystem source; no extra fields. |

The url-XOR-path rule is expressed in JSON Schema as per-kind `allOf` conditionals: `git-managed`/`web-doc` require a non-empty `url` (and `web-doc` forces `path` to null/empty); `external-doc`/`local-path` require a non-empty `path` (and force `url` to null/empty). A null or empty string is treated as absent, matching `verify.sh`'s `.field // ""` defaulting. Source: [`engine-bootstrap-templates/source-paths.schema.json` § allOf](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/engine-bootstrap-templates/source-paths.schema.json#L82-L127). One semantic rule is not expressible in JSON Schema and lives only in `verify.sh`: `web-doc` `page_list` URLs must share an origin with the source `url`. Source: [`engine-bootstrap-templates/source-paths.schema.json` § description](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/engine-bootstrap-templates/source-paths.schema.json#L5-L5). `branch` present on any kind other than `git-managed` is likewise a schema violation. Source: [`engine-bootstrap-templates/source-paths.schema.json` § branch-is-git-managed](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/engine-bootstrap-templates/source-paths.schema.json#L108-L111).

`external-doc`'s `path` points at authored markdown that lives outside the navigated code repos — a generic accessibility reference, a SharePoint-style compliance snapshot. It is deliberately NOT git-managed: no SHA-then-clone flow, and no URL. The footgun the contract guards against is blending un-tagged generic content with repo-derived signal, so every external-doc `.md` must carry provenance frontmatter (see next section). Source: [`docs/02-artifact-contract.md` § kind: external-doc](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L103-L130).

## Reference files: no frontmatter, depth-1, two forms

Reference files are pure Markdown with NO YAML frontmatter — the first line of every reference is the `# Reference Title` H1. This matches Anthropic's Agent Skills practice (frontmatter is scoped to `SKILL.md` only), and it is enforced by the `reference-frontmatter` check, which fails any `references/*.md` whose first non-blank line is `---`. On platforms that don't parse YAML in supporting files a stray block renders as visible content; on those that do, `name:`/`description:` collide with the SKILL.md metadata schema. Source: [`docs/02-artifact-contract.md` § No YAML frontmatter](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L393-L399).

A primary takes one of two forms, both first-class. File form `references/<slug>.md` is the default (a rename touches one file). Directory form `references/<slug>/` is opt-in for multimodal references: it holds a canonical primary `.md` of the same basename (`references/billing-mfa/billing-mfa.md`) alongside non-`.md` assets. Exactly one `.md` is permitted at depth-2 and its basename must match the directory; a `<slug>` present in both forms is a duplicate-primary failure. Source: [`docs/02-artifact-contract.md` § directory form](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L464-L468).

The structure stays one level deep. From `SKILL.md` every reference is reachable in exactly one link traversal — no nested reference directories, no delegation to a sub-directory of references. Depth-1 prevents shallow probing (Claude `head`-previewing before committing to a full read) and is enforced inside the `catalog-bijection` check; a catalog row whose target encodes a nested path fails there. Bare-named companion files live flat in the same `references/` directory and remain depth-1. Source: [`docs/02-artifact-contract.md` § Reference depth](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L456-L462). Reference bodies are authored in soft-wrapped prose (one paragraph per physical line) and, once past 100 lines, must carry a `## Contents` TOC marker in the first 30 lines — the shape this very file follows.

## Citing sources: permalinks and provenance blocks

For `git-managed` sources the canonical pointer is an inline commit-SHA GitHub permalink with a line range: `https://github.com/<owner>/<repo>/blob/<sha>/<path>#L<start>-L<end>`, where `<sha>` is a 40-char commit SHA captured at harvest time (stable version tags like `v1.2.3` are accepted equivalently). This is the form the SHA-pin lint (`permalink_density.py`, Check 7) grades. The failure mode it prevents is link rot: branch-pinned `blob/main/...` URLs rot at an estimated 38–66% over one-to-two years as the source repo evolves. Source: [`docs/02-artifact-contract.md` § SHA-pinned permalinks](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L549-L559).

Pin everything in reference-corpus content; the single exception is intentional-latest pointers meant to drift with `main` (the project README, a stable spec page), which belong in navigator prose, not reference bodies. Source: [`docs/02-artifact-contract.md` § When to keep an unpinned URL](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L566-L571).

`web-doc` and `external-doc` content isn't on GitHub, so it is cited by a `source_url + content_hash + crawl_date` block instead of a permalink — because the web-doc cache is gitignored, a reviewer on another machine verifies by re-fetching the URL and comparing the content hash. Source: [`docs/02-artifact-contract.md` § web-doc citation form](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L140-L142).

```text
Source: https://docs.example.com/a11y/guide
Content-hash: 3f9a1c2b        # sha256(content)[:8]
As-of: 2026-05-07
```

That citation is backed by the provenance frontmatter every cached web-doc/external-doc `.md` carries — three keys with pinned regexes: `source_url` (`^https?://…$`), `crawl_date` (ISO-8601 UTC, literal `Z` when a time is included), and `decay` (`none` or `<N>d|w|m|y`, e.g. `30d`). The keys are enforced at scaffold time and again at commit time by the `external-doc-frontmatter` check. Source: [`docs/02-artifact-contract.md` § Required provenance frontmatter](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L112-L126).

```markdown
---
source_url: https://docs.example.com/a11y/guide
crawl_date: 2026-05-07
decay: 30d
---
```

## SKILL.json and the trijection

A navigator MAY ship an optional `SKILL.json` machine-readable sibling next to `SKILL.md`. It is opt-in additive — contextualizers without it still pass `verify.sh` — and future-proofs downstream tools that want structured metadata without parsing Markdown. Source: [`docs/02-artifact-contract.md` § SKILL.json](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L334-L336).

Its shape mirrors the navigator: `name` and `description` (same WHEN-not-WHAT discipline), a `catalog[]` (one object per primary: `tag`, `path`, `description`, optional boolean `draft`), a `cross_references[]` of routing hints (`query_pattern`, `primary`, `also_load`, `rationale`), and an optional `schema_version`. Source: [`docs/02-artifact-contract.md` § Shape](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L338-L344).

When `SKILL.json` is present, the contract is a three-way correspondence — a trijection over `tag` field values: `SKILL.md ## Catalog rows ↔ SKILL.json non-draft catalog entries ↔ references/<area-domain>-*.md files`. The pairwise `SKILL.md ↔ filesystem` bijection continues to hold orthogonally; the trijection extends it. Source: [`docs/02-artifact-contract.md` § Trijection summary](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L356-L362).

The one tolerance: an entry with the JSON boolean `"draft": true` is excluded from the trijection, letting in-progress entries sit in `SKILL.json` without a catalog row or a file yet — the check surfaces a one-line `[WARN]` count rather than failing. A stringified `"true"` is NOT the draft marker (it counts as a non-draft entry and is included). Source: [`docs/02-artifact-contract.md` § draft tolerance](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L352-L354).

## Navigator size budget at a glance

The navigator's standing instructions — invariants, critical rules, and dispatch logic — must fit in the first 5K bytes of the `SKILL.md` body (frontmatter excluded). The motivation is auto-compaction: mid-conversation the orchestrator re-attaches skills within a ~25K budget for all attached skills, so reserving 5K per navigator leaves multi-skill headroom; a navigator that overflows is silently truncated. The `## Catalog` table is a TOC, not standing instructions, and is carved out. This is a contract rule upheld by author and reviewer — the shipped `verify.sh` has no `first-5K` check today. Source: [`docs/02-artifact-contract.md` § Navigator size budget](https://github.com/nick-railsback/skill-engine/blob/9ba4fae5263448cc32213d199b4580589e69b2b8/plugin/skill-engine/docs/02-artifact-contract.md#L316-L324). See the invariants reference for the full set of contract rules and which are machine-enforced today.

## Related references

For the enumerated invariants (bijection, no-frontmatter, source-entries, trijection) and which are enforced by `verify.sh` vs. reviewer judgment, see invariants. For how DISCOVER and REFRESH read and write `source-paths.json`, probe lifecycle state, and manage the clone/enrichment caches, see discover-refresh. For the engine's overall shape — workflows, the staging-proposal model, and the review/apply gates — see overview.
