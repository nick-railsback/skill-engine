# 02-Artifact contract

This chapter is the **artifact contract**: the file structure the engine produces and the invariants every reference and navigator must satisfy. The engine in [03-engine.md](03-engine.md) (via the contextualizer-side `verify.sh`) and the fixture-harness test-suite design in [05-invariants.md](05-invariants.md) both treat this contract as the spec they validate against. If a deliverable from the engine doesn't match this shape, the pre-approval validation rejects it.

The conventions are not stylistic. The navigator's loading model and the engine's pre-approval validation both depend on predictable structure - skipping one surfaces as a test failure or a runtime read failure later. The rationale traces back to [01-principles.md](01-principles.md), particularly the frontmatter discipline and the `disable-model-invocation` workaround.

**On this page:**
* [The three artifacts](#the-three-artifacts)
* [The navigator (SKILL.md)](#the-navigator-skillmd)
* [Reference files](#reference-files)
* [Companion files](#companion-files)
* [Progressive disclosure: the keep/replace framework](#progressive-disclosure-the-keepreplace-framework)
* [When to split a reference](#when-to-split-a-reference)
* [The bijection invariant (the load-bearing one)](#the-bijection-invariant-the-load-bearing-one)
* [Why these conventions exist](#why-these-conventions-exist)

> **Pre-fixture-harness scope note.** This chapter describes the artifact-contract surface as a whole. Mentions of the byte-equality fixture and the full test-suite harness below belong to the fixture-harness design (canonical in [05-invariants.md](05-invariants.md)); the pre-fixture-harness state ships with the stamped `verify.sh` as the single validator — covering no-frontmatter, catalog bijection, navigator/reference frontmatter, source-paths schema, and the optional SKILL.json trijection. Inline "(fixture-harness)" tags flag the boundary where it matters; treat the rest as the current pre-fixture-harness contract.

## The three artifacts

The artifact is a single skill directory containing one navigator file and two flavors of supporting reference files:

```text
skills/
  <area-domain>-context/
    SKILL.md                              # navigator (one file, this is the entry point)
    references/
      <area-domain>-<topic>.md            # primary reference in file form (default)
      <area-domain>-<topic>/              # primary reference in directory form (optional, for multimodal)
        <area-domain>-<topic>.md          # canonical primary (basename matches the directory)
        <asset>                           # non-.md assets (diagrams, JSON, screenshots)
      <bare-companion-name>.md            # companion files (deep-dives linked from primaries)
```

That's the whole filesystem surface. Three concepts:

* **The navigator (`SKILL.md`)** - one small markdown file that catalogs the references and tells the AI assistant how to read them.
* **Primary references in `references/`** - one primary per cataloged topic. Every primary appears in the navigator's catalog, and every catalog row points to a primary. A primary takes one of two shapes: a single `.md` file (`references/<area-domain>-<topic>.md`, the default) OR a directory containing a canonical primary of the same basename alongside non-`.md` assets (`references/<area-domain>-<topic>/<area-domain>-<topic>.md`, opt-in for multimodal references). The 1:1 invariant has a name: **catalog bijection**. It's enforced by an automated test (see [05-invariants.md](05-invariants.md)).
* **Companion files (`references/<bare-name>.md`)** - optional deep-dive files. Linked from primaries, but not cataloged. Use bare names without the `<area-domain>-` prefix to make them visually distinct.

There is no `index.md` and no metadata file in `references/`. The structure stays one level deep: `references/` contains either a flat `.md` file or a directory-form reference (which is itself the reference, not a nested namespace). See `### Reference depth (one level)` below for the contract.

### Staging directory shape (DISCOVER and REFRESH write here, not live)

DISCOVER and REFRESH do not write into the live `<slug>-context/` directly. Both write to a sibling staging directory at `<install>/<slug>-context.proposed/` that mirrors the live skill's structure (`SKILL.md`, `verify.sh`, `research/...`, `references/...`) plus a `.review/` subdirectory carrying `manifest.json` (an `entries[]` list of `{path, status, sha_before, sha_after}` records — `status` is one of `added`, `modified`, `removed`, `unchanged`) and a filled-in `REVIEW.md` (the predict-then-compare audit trail stamped from `engine-bootstrap-templates/REVIEW.md.template`). The user reviews the proposal via `/skill-engine:review <name>`, promotes it via `/skill-engine:apply <name>`, or throws it away via `/skill-engine:discard <name>`. Bootstrap is exempt — `engine-bootstrap` stamps directly into the live tree because there is nothing to review at first-scaffold time. The four reference invariants and the named checks in `verify.sh` are evaluated against the staging directory before its `manifest.json` is finalized; a `verify.sh` failure aborts the proposed-dir write and the user never sees a broken proposal.

## The navigator (SKILL.md)

### Frontmatter - exactly two fields

```yaml
---
name: <area-domain>-context
description: Answers questions about the <area-domain> ecosystem. Use when working with <topic-list>.
---
```

No `version`, no `tags`, no `tools`, no `disable-model-invocation`. See [01-principles.md](01-principles.md) for the rationale; in short - non-standard fields produce platform-divergent behavior, and `disable-model-invocation` is broken for plugin-distributed skills.

### Description quality is part of the contract

The description goes into the system prompt of every consuming agent and drives whether the skill fires. Two failure modes the contract guards against:

* **Too vague** (e.g., "Domain context") -> the agent never invokes the skill because the description doesn't match user queries.
* **Too broad** (e.g., "Useful for any technical question") -> the agent invokes the skill on irrelevant queries, polluting context.

Aim for a description that names **what the domain is** and **what kinds of questions trigger it** - e.g., "Answers questions about the Identity ecosystem. Use when working with SSO, MFA, user provisioning, Auth flows, or session management."

### Description = WHEN, never WHAT

The most common description failure is naming what the skill *is* rather than when to invoke it. A description that reads as a label rather than a trigger condition collapses routing accuracy: the agent's matcher cannot decide whether the current query qualifies, so the skill either fires too often or never. The WHAT-style description treats the description field like a catalog entry; the WHEN-style description treats it like the trigger condition the consuming agent actually compares against.

| Bad description (WHAT) | Good description (WHEN) |
|---|---|
| `Identity ecosystem documentation.` | `Answers questions about the Identity ecosystem. Use when working with SSO, MFA, user provisioning, Auth flows, or session management.` |
| `Library for billing logic.` | `Use when implementing billing flows, refund handling, subscription state, or invoicing edge cases.` |
| `Internal payments knowledge base.` | `Use when an engineer needs to navigate payments services, reconcile ledger entries, or trace a money movement event.` |

"WHEN" and "WHAT" are mnemonics. Concretely: the description must answer the agent's matching question (*"is this query mine?"*), not the human's catalog question (*"what does this skill cover?"*). Names belong in `name:`; trigger conditions belong in `description:`.

### Filename prefix should discriminate, not namespace

The `<area-domain>-` prefix in `references/<area-domain>-*.md` is a routing signal, not a namespace. It earns its place when it discriminates which references the agent should consult; it adds noise when it merely brands the file as project-internal.

* **Discriminating prefix.** `billing-refunds.md` tells the matcher this reference is *about billing-domain refund flows*. Specific. Routes well.
* **Branding prefix.** `mycompany-billing-refunds.md` adds a non-discriminating `mycompany-` token. Every reference in the corpus carries the same brand, so the brand contributes nothing to routing - it dilutes the signal.
* **Multi-domain: prefer per-domain prefixes.** When one navigator routes across domains (e.g., a contextualizer that covers billing, support, and engineering), prefix by **per-domain** tokens - `billing-`, `support-`, `eng-` - not by a single contextualizer-name token. Per-domain prefixes preserve discrimination at the file level; a single project-wide prefix collapses it.

The bijection invariant (see "The bijection invariant" below) is unaffected by prefix choice - that contract holds regardless of how `<area-domain>-*` is filled in. The guidance here is about routing UX, not contract compliance.

### `kind: "external-doc"`

A `research/source-paths.json` entry can carry an optional `kind` discriminator that names the harvest treatment the engine applies to a source root. When `kind` is absent — the existing-corpus state for every contextualizer that has shipped before this addition — the entry receives the **git-managed source-root** treatment documented in [`03-engine.md`](03-engine.md): per-source SHA via `git rev-parse HEAD`, then sparse-clone or shallow-clone crawl when the SHA has changed. Back-compat is total — every existing source-paths.json entry continues to behave exactly as it did before the discriminator was introduced; `kind` is purely additive. Entries that explicitly set `kind: "external-doc"` receive the external-doc treatment described below.

```json
{
  "sources": [
    { "path": "references/external/a11y/", "kind": "external-doc" }
  ]
}
```

**What `kind: "external-doc"` means.** The `path` field points at pre-curated markdown content that lives outside any code repository — for example, a generic accessibility reference, a SharePoint-style compliance snapshot, an authored markdown sourced outside the navigated code repos. The engine treats this content as a first-class source for [DISCOVER](08-discover-pipeline.md) without applying the git-managed SHA-then-clone flow. external-doc is **not a bootstrap-intake kind** — it carries a contextualizer-internal `path`, not a URL. Entries of this kind arrive in `research/source-paths.json` via DISCOVER, hand-edit, or a future workflow; the engine-bootstrap scaffolder produces `kind: "web-doc"` for doc-site URLs (see [`kind: "web-doc"`](#kind-web-doc)).

Harvest semantics:

* **Directory `path`.** The `path` resolves to a directory containing one-or-more `.md` files, scanned **recursively** so nested subdirectories are included (the exact walk recipe — `find -L`, the `-type f -o -type l` filter, and symlink handling — is canonicalized in the Symlink containment paragraph below and the `external-doc-frontmatter` named check in the contextualizer-side `verify.sh` the plugin stamps at bootstrap). Recursion is deliberate — external-doc directories typically mirror upstream wiki or SharePoint hierarchies the maintainer has not flattened; a shallow scan would silently skip the bulk of the content.
* **Single-file `path`.** A contextualizer that ships exactly one external-doc `.md` file (the canonical example: one accessibility best-practices markdown injected at a known path) supports `kind: "external-doc"` with `path` resolving directly to the `.md` file rather than wrapping it in a directory. The verify check handles both shapes uniformly.

**`source_id` derivation reuses the existing algorithm.** Each external-doc entry's `source_id` is computed via the algorithm in the [Source identifier (`source_id`)](#source-identifier-source_id) sub-section below (`sha256(path-relative-to-contextualizer-root)[:8]`) without modification. The per-source-SHA enrichment cache (`research/.discover-cache.json`, see [`08-discover-pipeline.md`](08-discover-pipeline.md#persisted-state)) keys on `(source_id, sha)` for external-doc entries just as it does for git-managed sources. `sha` for an external-doc entry is computed deterministically as `sha256` of the concatenation of `<relative-path>:<sha256(contents)>\n` lines for each `.md` file under the directory, in `LC_ALL=C` byte-sorted order — so the SHA changes when any file's contents change OR when files are added, removed, or renamed; cross-machine determinism follows from the byte-sorted ordering and absence of platform-specific metadata. The "crawl-once" property falls out for free. No schema modification to the cache record is required.

**Required provenance frontmatter.** Every external-doc `.md` file must carry three frontmatter keys. The contract is enforced at scaffold time (by the engine-bootstrap scaffolder's validate step) AND at commit time (by the `external-doc-frontmatter` named check in the contextualizer's `verify.sh`; the source template lives at `plugin/skill-engine/engine-bootstrap-templates/verify.sh` in the plugin). The three keys and their pinned format regexes:

* **`source_url`** — the upstream URL the content was crawled from. Pinned regex `^https?://[^[:space:]]+$`. Must be a parseable URL with a non-empty host part and no embedded whitespace; the same regex applies at scaffold time and at commit time so a contextualizer that hand-edits an external-doc file later can't drift below the contract.
* **`crawl_date`** — an ISO-8601 UTC date or datetime. Pinned regex `^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$`. Accepts `2026-05-07` and `2026-05-07T14:32:00Z`. Rejects `"yesterday"`, `"recent"`, `2026-05-07T14:32:00` (missing `Z`), `2026-05-07 14:32` (space separator, no T), and `2026-05-07T14:32:00-05:00` (non-UTC offset). UTC-only with a literal `Z` suffix when time is included; T-separator required; no local-time-without-offset, no space-separator, no fractional seconds in this version. The UTC-only invariant prevents cross-machine cadence drift when contextualizers are shared between maintainers in different timezones. The shape regex does not validate calendar correctness or temporal direction (e.g., `2026-13-45` and future dates pass); this is intentional in v1.
* **`decay`** — the freshness expectation. Pinned regex `^(none|[1-9][0-9]*[dwmy])$`. Canonical values: `none` (crawl-once, no expiry — the canonical "SharePoint snapshot" case), `<N>d` (e.g., `30d`), `<N>w`, `<N>m`, `<N>y`. The leading `[1-9]` explicitly disallows `0d`; the anchors disallow leading minus, internal spaces, and unit-words; lowercase units only. Ambiguous forms like `0d`, `-30d`, `30 d`, `30D`, and `30days` all fail loudly.

Example valid frontmatter:

```markdown
---
source_url: https://docs.example.com/a11y/guide
crawl_date: 2026-05-07
decay: 30d
---
```

**The footgun.** Blending un-tagged generic references with repo-derived signal is a portfolio-grade mistake — the lint check exists precisely to catch it at scaffold time, and the commit-time check enforces it again at the public boundary. A reviewer reading the navigator at consumption time must be able to distinguish "this came from our internal design system's repo" from "this came from a generic best-practices markdown someone dropped in". Provenance tagging via `source_id` plus mandatory `source_url` in frontmatter is the signal that makes the distinction visible; un-tagged content blended into the corpus silently erases it. The lint is the defense.

**Symlink containment.** External-doc paths may legitimately follow symlinks — a `references/external/` symlink to a sibling directory synced from an upstream wiki or compliance source is a real authoring pattern. The harvest walk uses `find -L` to follow symlinks, AND every resolved target is `realpath`-checked for containment within the contextualizer repo root: a resolved target outside the root is rejected at scaffold-lint time (by the engine-bootstrap scaffolder) AND at commit time (by the `external-doc-frontmatter` named check in the contextualizer's `verify.sh`). The cycle cap is 16 hops — symlink-to-self, `A → B → A`, and longer cycles all fail loudly naming both the offending starting symlink and the resolved cycle path. macOS BSD `realpath` and GNU `realpath -e` differ on cycle behavior (BSD silently produces a partial result; GNU errors); the check normalizes by attempting `realpath -e` first and falling back to a pure-bash hop-counting loop (POSIX-bash only, no third-party deps) when `-e` is unsupported, so the check is deterministic across the cross-platform tiers documented in [`01-principles.md`](01-principles.md). The failure message names the offending symlink path AND the resolved target. DISCOVER refuses to harvest any content from outside-root targets — the rejection fires at the harvest entry point, not deeper in the pipeline, so no partial-harvest state is possible.

### `kind: "web-doc"`

Documentation-site content acquired via the model's installed fetch
tool (WebFetch or MCP fetch). Snapshots live in a gitignored cache at
`~/.cache/skill-engine/web-doc/<source_id>-<crawl_id>/`; one `.md` file
per crawled page, with the same provenance frontmatter
(`source_url`, `crawl_date`, `decay`) as `external-doc` files.

Citation form: `source_url + content_hash + crawl_date` — the cache is
gitignored, so the reviewer on a different machine verifies by
re-fetching the URL and comparing content_hash.

Schema fields:

| Field | Required | Notes |
|---|---|---|
| `url` | yes | Root site URL. REFRESH HEAD-probes this. |
| `crawl_mode` | yes | `"sitemap"` or `"list"`. |
| `sitemap_url` | no (sitemap mode only) | Override auto-discovery. |
| `page_list` | yes (list mode only) | URLs sharing the source `url`'s origin. |
| `crawl_filters` | no | `{ include: [glob], exclude: [glob] }`, default `{ include: ["/**"], exclude: [] }`. |
| `crawl_budget` | no | Integer in [1, 5000], default 200. |
| `branch` | **rejected** | Schema violation on web-doc. |

The `_crawl-manifest.json` file at the cache root records the audit
trail (pages, failures, robots-disallows, budget truncation).

The recipe for setting up a web-doc source — sitemap vs. list mode,
filtering, budget, decay — lives in
[`docs/recipes/web-doc-setup.md`](recipes/web-doc-setup.md).

### source-paths.json entry shape

Beyond the `kind` discriminator and the external-doc-specific provenance frontmatter, every `research/source-paths.json` entry carries a small set of engine-managed fields. The schema is additive — `schema_version: 1` remains current because every new field is optional-by-default or has a documented default. The full per-entry shape:

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

**`id`** — a deterministic kebab-case slug derived from the input URL or path at intake time, distinct from `source_id` (the SHA-256-derived stable handle documented in the [Source identifier](#source-identifier-source_id) sub-section below). The slug is user-readable (`vitejs-vite`, `my-monorepo`); the `source_id` is content-addressed (`a1b2c3d4`). Both coexist on each entry — the slug surfaces in user-facing prompts and the navigator catalog; the SHA-derived id keys per-source cache entries. Collisions among slugs are resolved by appending `-2`, `-3` at intake; collisions among SHA-derived ids are governed by the safe-N budget below.

**`status`** — the curation state-machine, one of `intake` / `proposed` / `confirmed` / `rejected`. Tracks how the source got into `source-paths.json` and how the user has curated it. `intake` is the state bootstrap leaves a fresh source in. `proposed` is the state any companion source surfaced by DISCOVER enters. `confirmed` is the state any source moves to once the user explicitly approves it. `rejected` is a closed state — the source is kept in the file (for re-proposal TTL bookkeeping) but DISCOVER and REFRESH skip it. The state-machine is one-directional in normal use: `intake → confirmed`, `proposed → confirmed | rejected`, never the reverse without a manual edit.

**`lifecycle`** — the upstream state-machine, distinct from `status`. Tracks whether the upstream still exists, has moved, or is unreachable. Four `state` values: `reachable` (probe succeeded), `moved` (probe followed a redirect; `proposed_url` carries the resolved target), `removed` (probe returned a definitive not-found), `unknown` (probe failed for transient/network reasons; no state transition recorded). `last_checked` is an ISO-8601 UTC timestamp; `last_checked_sha` is the upstream HEAD SHA for `git-managed` sources at the most recent successful probe. A `confirmed` source can have any of the four lifecycle states — curation and upstream state are orthogonal axes. DISCOVER and REFRESH both update `lifecycle.state` during their runs — DISCOVER on first ingest, REFRESH on every freshness pass. Under the goal-given posture, the model decides how to probe each source and when to write the transition; the engine validates output via the four reference invariants and `verify.sh`. See [`08-discover-pipeline.md`](08-discover-pipeline.md) for the canonical doctrine.

**`archived`** — a user-set boolean. The engine does not auto-detect upstream archival (a GitHub-API dependency for archival detection would require auth-token plumbing the engine deliberately avoids — the contract stays HTTP-HEAD + `git ls-remote` only). When the user manually sets `archived: true`, REFRESH and DISCOVER skip the source's crawl pass, and any lifecycle sweep proposal treats citations to this source the same as it would for a `removed` state — `cut_block` by default. Defaults to `false` when absent.

**`discovered_via`** — null on user-supplied sources; on companion sources surfaced by another source's analysis, an array of `{ parent_source_id, depth, discover_run, signal }` records. Array (not single object) so multiple parents discovering the same companion append rather than overwrite. `depth: 1` for first-hop companions; the v1 single-hop limit means DISCOVER does not recurse past `discovered_via[*].depth >= 1`. Depth is recorded on every provenance record so the decision is reversible without re-scanning.

**`branch`** — optional, `kind: "git-managed"` only. Names the upstream ref REFRESH and DISCOVER track. Absent ⇒ HEAD (the upstream repo's default branch, whatever that resolves to at the moment of the call). Set explicitly when the contextualizer follows a non-default branch (`dev`, `nonprod`, `release/v2`). The string must match `^[A-Za-z0-9._/-]+$` — git-ref-safe characters only. Specifying `branch` on a `kind: "external-doc"` or `kind: "local-path"` entry is a schema violation; the `source-entries` verify check rejects it.

**Citations resolve by path+content-hash.** No per-source sub-region granularity is enforced at the schema level; reference files cite their source by the `(source_id, path, sha)` triple. The chunked-source granularity layer that earlier engine versions carried has retired — DISCOVER now decides the partition it likes during a session, writes references that satisfy the four invariants, and the engine validates output via `verify.sh` rather than constraining the partition shape.

**Required fields per entry post-DISCOVER-first-run.** `id`, `kind`, `url`-or-`path`, `status`, `lifecycle.state`. The contextualizer verify.sh's `source-entries` check (see [`plugin/skill-engine/engine-bootstrap-templates/verify.sh`](plugin/skill-engine/engine-bootstrap-templates/verify.sh)) enforces these required fields and the three enum constraints (`kind`, `status`, `lifecycle.state`) on every contextualizer invocation.

**Two state-machine axes — load-bearing.** `status` (curation) and `lifecycle.state` (upstream) describe distinct things and must not be conflated. A `confirmed` source can become `removed` upstream without invalidating the curation; a `rejected` companion can still have its upstream reach `moved`. The engine surfaces both axes separately — directly in `source-paths.json` and in each workflow's post-run summary — so the two states are never collapsed into one. Conflating them would lose information at the moment the user most needs it.

### Body - five sections in this order

**1. Overview** - two or three paragraphs: what the domain is, what this navigator catalogs, how the AI is meant to use it.

```markdown
# <area-domain> Context Navigator

## Overview

<area-domain> is <one-sentence definition>. This navigator catalogs the
primary subsystems - <subsystem-1>, <subsystem-2>, <subsystem-3> - and
points at on-demand reference files in `references/`.

When asked an <area-domain> question, scan the Catalog below for the
matching topic, follow the link to read the reference, then consult
the Cross-reference map if the question spans multiple subsystems.
```

**2. Catalog** - a markdown table. One row per primary reference. Two columns:

```markdown
## Catalog

| Reference | Description |
|---|---|
| [<area-domain>-sso](references/<area-domain>-sso.md) | SSO patterns, SAML/OIDC flows, identity-provider integrations |
| [<area-domain>-mfa](references/<area-domain>-mfa.md) | Multi-factor authentication: TOTP, WebAuthn, SMS fallback, recovery codes |
| [<area-domain>-provisioning](references/<area-domain>-provisioning.md) | User lifecycle: SCIM, just-in-time provisioning, deprovisioning workflows |
```

The first column is a markdown link to the reference file. The second is a one-line factual summary that helps the AI route correctly. The catalog is bijective with `references/<area-domain>-*.md` - `verify.sh` enforces this (catalog-bijection check); see "The bijection invariant" below.

**3. Cross-reference map** - a bullet list of multi-domain query patterns: when does a question naturally span two or more references?

```markdown
## Cross-reference map

* Any question about user lifecycle start at `<area-domain>-provisioning`.
  It covers the full SCIM flow and points at `<area-domain>-sso` for the IdP-side
  of the handshake.
* Any MFA reset question read `<area-domain>-mfa`; `<area-domain>-provisioning`'s
  recovery flows touch both.
* Anything about session expiration `<area-domain>-sso` covers the token side; the
  client-side cookie behavior lives in the companion file `session-cookie-deep-dive.md`.
```

**4. Instructions to Claude** - the load-syntax contract. Path syntax differs by platform:

```markdown
## Instructions to Claude

When loading a reference file:

* **Claude Code:** Read the reference using the platform-provided
    skill-directory variable:
    `Read $CLAUDE_SKILL_DIR/references/<area-domain>-<topic>.md`

* **Claude Desktop:** Read the reference using a relative path; the platform
    resolves it from the skill's installed location:
    `Read references/<area-domain>-<topic>.md`

Loading rules:
* Load one reference at a time unless the Cross-reference map says to load both.
* If the primary reference doesn't fully answer the question, follow any
    source-repo URL pointers it provides for deeper detail.
* Do not eagerly load companion files; only follow companion links when the
    primary reference says to.
```

Keeping the syntax explicit prevents the AI from guessing the path (which it will get wrong on at least one platform).

**5. Progressive Disclosure note** - a short closing section stating that references curate and point; they don't re-specify upstream sources.

```markdown
## Progressive Disclosure

References prioritize curated insight: gotchas, cross-system patterns, and
adoption guidance. When an upstream source doc exists and is maintained,
the reference summarizes the key points and points at the source for full
detail. Don't follow source-repo links eagerly; only when the reference
itself doesn't answer the question.
```

The full keep/replace decision framework lives in the [Progressive disclosure](#progressive-disclosure-the-keepreplace-framework) section below.

### Navigator size budget

**Hard invariant.** The navigator's **standing instructions** - invariants, critical rules, and dispatch logic - must fit in the first **5K bytes** of `SKILL.md` body, with frontmatter excluded. The verify gate enforces this with the `first-5K` check (see [05-invariants.md](05-invariants.md)).

The platform constraint motivating the rule is auto-compaction. When the orchestrator re-attaches skills mid-conversation, the budget for all attached skills is roughly 25K bytes. Reserving 5K for any one navigator's standing instructions leaves headroom for multi-skill scenarios; a navigator that exceeds it will be silently truncated by the platform.

**Catalog-as-TOC carve-out.** The `## Catalog` table is a TOC, not standing instructions; it does not count against the 5K budget. Multi-domain navigators (see [Multi-domain navigators](#multi-domain-navigators) below) therefore keep large sectioned catalog tables without violating the rule. Standing instructions are explicitly the three categories above — invariants, critical rules, dispatch logic — and catalog content is excluded.

The navigator is a router, not a knowledge base. If your navigator's standing instructions are approaching the budget, you're probably putting reference content into the navigator instead of into reference files.

### Multi-domain navigators

A navigator that routes across multiple domains — one `<area-domain>-context` skill cataloging more than one domain — is contractually equivalent to a single-domain navigator: same two-field frontmatter, same first-5K standing-instructions budget (with the catalog-as-TOC carve-out, which lets a sectioned catalog grow as needed), same six prescribed reference sections, same bijection invariant extended to per-section bijection across the sectioned catalog.

The engine is scope-agnostic. Multi-domain navigators are first-class — covered by their own template `navigator-multi-domain.md.template` (find at `plugin/skill-engine/engine-bootstrap-templates/navigator-multi-domain.md.template` in your installed plugin, or at <https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/engine-bootstrap-templates/navigator-multi-domain.md.template>) — not a special case of the single-domain shape. The trade-offs around when to pick one shape over the other live in [04-delivery.md](04-delivery.md).

### SKILL.json (optional machine-readable sibling)

A navigator MAY ship an optional `SKILL.json` file alongside `SKILL.md` in the same skill directory (`skills/<area-domain>-context/SKILL.json`). The sibling is a future-proofing primitive for downstream tools and non-Claude consumers that benefit from structured metadata without parsing markdown — it is **opt-in additive**, never a forcing function. Contextualizers that ship without `SKILL.json` continue to pass `verify.sh` unchanged.

**Shape.** A JSON object with these top-level keys:

* `name` — string, mirrors the navigator's frontmatter `name`.
* `description` — string, mirrors the navigator's frontmatter `description`. Same WHEN-not-WHAT discipline applies (see [Description = WHEN, never WHAT](#description--when-never-what) above).
* `catalog` — array of objects, one per cataloged primary reference. Each entry carries `tag` (string), `path` (string, relative to the skill directory), `description` (string), and an optional boolean `draft` field.
* `cross_references` — array of objects, one per pre-computed query-pattern routing hint. Each entry carries `query_pattern` (string), `primary` (tag string), `also_load` (array of tag strings), and `rationale` (string).
* `schema_version` — integer, optional; pins the SKILL.json schema major version for forward compatibility.

**Description-quality rule on catalog entries.** The `description` field on each `catalog[]` entry follows the same WHEN-not-WHAT discipline as the navigator's own description. The same bad/good distinction applies:

| Bad description (WHAT) | Good description (WHEN) |
|---|---|
| `"Refund handling reference."` | `"Use when handling refund timing, partial refunds, or refund-vs-chargeback decisions."` |

**The `draft: true` tolerance.** An entry carrying `"draft": true` is **excluded** from the trijection check (see Invariant 11 in [05-invariants.md](05-invariants.md)). Draft entries may sit in `SKILL.json` without a corresponding `## Catalog` row in `SKILL.md` or a `references/<area-domain>-*.md` file on the filesystem. The intent is to let in-progress entries live alongside shipped ones — the verify check surfaces a one-line summary at run time so draft entries remain visible rather than silently passing.

**Predicate semantics — pin these.** The `draft` field is a JSON **boolean** (`true` or `false`). A stringified `"true"` is NOT the draft marker; the schema treats it as a non-draft entry whose `draft` field carries an out-of-spec string value, and the trijection check includes the entry. Absence of the `draft` field is equivalent to `draft: false`. Set equality is computed over `tag` field values; the `path` and `description` fields are not part of the trijection key.

**Trijection summary.** When `SKILL.json` is present, the three-way correspondence is:

```text
SKILL.md ## Catalog rows  ↔  SKILL.json non-draft catalog entries  ↔  references/<area-domain>-*.md files
```

The pairwise `SKILL.md ↔ filesystem` bijection (the existing Invariant 2 / `catalog-bijection` check; see [The bijection invariant](#the-bijection-invariant-the-load-bearing-one) below) continues to hold orthogonally; the trijection extends it without replacing it.

**Canonical example.**

```json
{
  "name": "billing-context",
  "description": "Use when working with billing flows, refund handling, subscription state, or invoicing edge cases.",
  "schema_version": 1,
  "catalog": [
    { "tag": "billing-refunds", "path": "references/billing-refunds.md",
      "description": "Use when handling refund timing, partial refunds, or refund-vs-chargeback decisions." },
    { "tag": "billing-disputes", "path": "references/billing-disputes.md",
      "description": "Use when investigating chargebacks or evidence-window deadlines." },
    { "tag": "billing-tax", "path": "references/billing-tax.md",
      "description": "Use when computing tax for invoices in multi-jurisdiction billing.",
      "draft": true }
  ],
  "cross_references": [
    { "query_pattern": "refund.*chargeback",
      "primary": "billing-refunds",
      "also_load": ["billing-disputes"],
      "rationale": "Refund + chargeback queries need both refund timing and dispute lifecycle context." }
  ]
}
```

The two non-draft catalog entries (`billing-refunds`, `billing-disputes`) participate in the trijection; the `billing-tax` entry is draft-excluded and surfaces only as a one-line `[WARN] skill-json-trijection: 1 draft entries excluded from trijection` summary at verify time.

## Reference files

### Frontmatter is optional; description-only when present

A reference file MAY carry a minimal frontmatter block containing only a `description:` field, or it MAY omit frontmatter entirely. When present, the block carries exactly the two delimiter lines and the `description:` line — no `name:`, no `version:`, no other fields.

```yaml
---
description: <one-line purpose statement — what this reference covers and when to read it>
---
```

The `description:` field is the **canonical, model-readable statement of the reference's purpose** and is the diff target for SELF-AUDIT's Check 4 (catalog-vs-content; see [`03-engine.md`](03-engine.md)). Recommended length: under ~200 characters so a reviewer scanning the catalog can read it inline. Style: noun-phrase or imperative — `"<Topic> patterns, gotchas, and recipes for <use-case>."` — same WHEN-not-WHAT discipline as the navigator's own description.

When frontmatter is absent, Check 4 falls back to a body-section heuristic — the first paragraph under the H1, or the bullets under a `## When to Use This Reference` section if one is present. Pre-existing references that ship without frontmatter remain compliant; the optional block is a sharpening, not a forcing function.

**Why optional, not required.** The navigator's loading model originally expected raw Markdown content from the first line and a stray YAML block could be treated as content by some platforms. The two-line `description:` block is small enough to render cleanly on the platforms that don't parse it; the platforms that do parse it get the canonical purpose statement. References that emit no frontmatter remain valid — the bijection invariant and the four reference invariants do not depend on this field.

The first line of the reference body remains `# Reference Title` (the H1). This is enforced by an automated test ([05-invariants.md](05-invariants.md)) whether or not a frontmatter block precedes it.

### A common reference shape

Under goal-given DISCOVER, the model varies a reference's body shape by what the source domain rewards — the engine validates output via the four reference invariants and `verify.sh` rather than constraining body section structure. A reference satisfies the contract as long as the invariants hold; the section names below are one acceptable shape, not a contract requirement.

The six-section shape below tends to render well across a wide range of domains and is the shape the example contextualizer at [`examples/library-context/`](examples/library-context/) uses. A reference may add, remove, rename, or reorder sections when the source's natural structure calls for it.

```markdown
# Reference Title

<One paragraph: what this reference covers and the architectural shape of the subsystem.>

## When to Use This Reference

* <2-4 bullet points: the specific question types this reference answers.
    The AI uses this to confirm it loaded the right reference.>

## Architecture Overview

<The mental model: what are the components, how do they fit together,
where are the boundaries. ASCII or mermaid diagrams welcome. ~30-60 lines.>

## Critical Patterns

<The "how to do common things correctly" section. Code snippets, the
right way to wire something up, the standard recipe. This is usually
the longest section. ~50-200 lines.>

## Common Gotchas

<Pitfalls, edge cases, footguns. Each gotcha gets its own bullet or
sub-heading. The "things you'd only know after debugging this for a day"
section. ~30-80 lines.>

## Key Components

<A short reference of the named pieces - file paths, class names,
service names - with one-line descriptions. ~10-30 lines.>

## Related References

<Bullet list of other primary references this one links to, and any
companion files that go deeper.>
```

### Voice characteristics

References are direct, imperative, code-forward, and concrete. Show the code, then explain the gotcha. Use source-repo URL pointers for deep dives instead of inlining 200-line API surfaces.

### Reference size budget
**< 500 lines, < 18KB** per file. If you're at the limit, split the reference - don't compress the prose. Splitting also forces a useful question: are you covering one topic or two?

The max-line-count and max-byte-count constraint is part of the fixture-harness invariants design — see [05-invariants.md](05-invariants.md). The pre-fixture-harness state relies on reviewer eyeball-judgment against this budget until the fixture-harness lands; `verify.sh` does not currently enforce it.

### Reference depth (one level)

From `SKILL.md`, every reference is reachable in exactly one link traversal — no nested reference directories. Catalog rows link directly to a `*.md` file in the navigator's sibling `references/` directory; that file does not delegate further to a sub-directory of references.

The failure mode this prevents is shallow probes. When references nest, Claude is tempted to `head -100` a reference to "preview" it before deciding whether to follow a deeper link, instead of reading the reference fully. The depth-1 rule keeps every reference a single, complete unit.

Companion files (bare-named, linked from primaries) live in the same `references/` directory and remain depth 1 — the rule constrains directory nesting, not the link graph between siblings. The verify gate enforces this with the `max-ref-depth` check (see [05-invariants.md](05-invariants.md)).

**Optional directory form for multimodal references.** A reference MAY take a second shape: a directory at `references/<area-domain>-<topic>/` containing a canonical primary `.md` file whose basename matches the directory basename — so a directory `references/billing-refunds/` contains `references/billing-refunds/billing-refunds.md` as its primary. Non-`.md` asset files (architecture diagrams, JSON schemas, SVG flows, screenshots, example payloads) MAY sit alongside the primary at the same depth; there is no extension restriction beyond "not `.md`." Both shapes are first-class. The flat file form `references/<area-domain>-<topic>.md` remains the default for text-only references — it is lighter to maintain (a rename touches one file). The directory form exists for references whose value is genuinely visual or asset-bearing: a diagram explains a flow more vividly than 200 words of prose; a JSON schema is most useful when shipped alongside the prose that describes it. The size budget above is text-token-only; an asset's effect on the model's attention is real even though the asset itself does not count toward Markdown bytes.

The depth-1 rule treats the directory itself as the reference. Assets inside the directory are not "nested references" — they are content owned by the reference. The same-basename convention for the canonical primary (the inner file's name matches the directory's name) is load-bearing: it pins exactly one primary per directory, makes the bijection check straightforward without slug-parsing, preserves the discriminating filename prefix, and lets a maintainer migrate from file form to directory form via `mkdir <slug> && mv <slug>.md <slug>/` without renaming the file. **Exactly one `.md` file is permitted at depth-2 inside a directory-form reference, and its basename must match the directory's basename.** Any other `.md` at depth-2 is a contract violation. Non-`.md` files at depth-2 are unconstrained. Sub-directories under `references/<area-domain>-<topic>/` are forbidden; depth-3+ paths fail loudly regardless of file extension. A reference may not exist in both forms simultaneously — if both `references/<slug>.md` and `references/<slug>/` are present for the same `<slug>`, the bijection check surfaces a duplicate-primary failure.

Reserve the directory form for references that genuinely benefit from accompanying assets. Do not migrate text-only references to the directory form on speculation — the directory form is heavier to maintain (renames touch multiple paths; assets need separate version-control consideration; an unintentional second `.md` at depth-2 becomes a contract violation). Companion files (bare-named, linked from primaries) continue to live flat at the top of `references/`; they are NOT placed inside a directory-form reference's directory.

```
references/
├── billing-refunds.md                  File form (text-only reference)
└── billing-mfa/                        Directory form (multimodal reference)
    ├── billing-mfa.md                  Canonical primary (basename matches directory)
    ├── flow-diagram.png                Asset
    └── recovery-paths.svg              Asset
```

### Long references must have a TOC (>100 lines)

Any reference body exceeding 100 lines must contain a Markdown TOC marker — typically `## Contents` — within the first 30 lines of the body. The TOC tells Claude where to land when the reference is loaded, instead of forcing a top-to-bottom read of a long file.

Short references (under 100 lines) do not need a TOC; they are short enough to scan directly. The verify gate enforces this with the `long-ref-toc` check (see [05-invariants.md](05-invariants.md)).

### Empowerment prose: where each voice belongs

References use **imperative** prose - *"read `auth/jwt-rotation.md` before modifying the token issuer"* - to give Claude direct guidance at the point of decision. The navigator uses **descriptive** prose - *"this skill covers identity; consult `references/identity-mfa.md` for MFA flows"* - because the navigator's job is to route, not to dictate.

The mixed voice is principled, not stylistic drift. Different artifacts at different altitudes deserve different tone: a descriptive navigator with imperative references reads like good architecture documentation; picking one voice uniformly bureaucratizes the navigator or under-directs the references.

**Empowerment guardrail.** Empowerment prose - *"you may Read/Grep into `<repo>` to drill deeper"* - belongs **only** in a reference's `## Edge cases and deeper investigation` sub-section. Spread anywhere else, the house style drifts toward delegated docs (the documentation equivalent of an LLM that always says "let me check"). Confine the empowerment voice to one structural place per reference; everything else is direct.

### See also: cross-cutting references

Add a `## See also` block at the bottom of any reference body that points at sibling references in the same `references/` directory. Entries are flat links — no nesting; the depth-1 rule above is unaffected. See-also entries point sideways, not down.

A reference may include an optional `cross-cutting` marker in its front-of-body prose to signal it is reachable from many other primaries — a hint to a future verify check that the reference must carry a `## See also` block. In v1 the marker is informational and the block is a convention, not a hard invariant.

## Companion files

Companion files are optional deep-dives that primary references link to:

```text
references/
  <area-domain>-sso.md          # primary
  saml-binding-deep-dive.md     # companion (bare name, no <area-domain>- prefix)
```

**Conventions:**
* **Bare names** (no `<area-domain>-` prefix) - visually distinct from primaries.
* **Live in the same `references/` directory** as primaries (one level deep - multiple platforms truncate references nested deeper).
* **NOT cataloged** in `SKILL.md`. They're discovered via link traversal from primaries.
* **Linked** from a primary's "Related References" section: `[saml-binding-deep-dive.md](saml-binding-deep-dive.md)`

**When to use one.** A deep-dive that distracts from the primary's job goes in a companion; the primary stays scannable. Don't hide content in a companion that the catalog should advertise - if the deep dive *is* the primary purpose of a topic, make it a longer primary or split into two primaries.

## Progressive disclosure: the keep/replace framework

This is the discipline for deciding what content lives in a reference vs. what gets summarized + pointed-to-source. Apply it to every paragraph of every reference.

### The four-question gate

1.  **Does this explain *why* something matters or warn about a gotcha?**
    * **KEEP.** Curation value. The source doc rarely captures "why" or warns about subtle pitfalls.
2.  **Does this synthesize information from multiple repos or systems into one view?**
    * **KEEP.** No single upstream source has the whole story. Synthesis is the reference's reason to exist.
3.  **Does this re-specify an exact JSON schema, API signature, or parameter list?**
    * **REPLACE** with a one-paragraph summary + a source-repo URL pointer. Specs drift; you don't want two copies.
4.  **Does an authoritative, maintained source doc already exist for this content?**
    * **REPLACE or SUMMARIZE-AND-POINTER**, depending on quality (see source-doc quality gate below).

### Source-doc quality gate

When you're about to replace your content with a pointer, evaluate the destination first:

| Source quality | Action |
|---|---|
| **Complete** (>50 lines, recently maintained) | REPLACE with summary + pointer |
| **Partial** (covers some of the topic, gaps elsewhere) | KEEP your summary, ADD pointer for depth |
| **Stub** (<20 lines, sparse) | KEEP your full content, ignore the source |
| **Outdated** (>1 year stale, contradicts current behavior) | KEEP your content, file an issue against the source |

If the source doc is wrong, your reference is the better source. Don't replace good content with a bad pointer just to be tidy.

### Pointer format convention

Source-repository URLs are the universal pointer format. They work regardless of project type, don't depend on local filesystem layout, and survive being read from a project that doesn't have the source repo cloned. **Avoid** filesystem paths like `node_modules/<pkg>/path`; they only work in specific project types and break the moment the consuming project doesn't have that dependency installed.

#### SHA-pinned permalinks (the canonical form)

The canonical URL form for any source pointer in a primary reference is a commit-SHA permalink with a line range:

```
https://github.com/<owner>/<repo>/blob/<sha>/<path>#L<start>-L<end>
```

`<sha>` is a 40-char commit SHA captured at harvest time. The engine captures it during the SHA-comparison phase of the freshness algorithm (see [03-engine.md](03-engine.md)) and persists it in the per-source enrichment cache; the emitter renders it back into the URL at write time. Stable version tags (`v1.2.3`) are accepted equivalently - the verify gate treats them as immutable.

**The failure mode this prevents** is link rot. GitHub's own permalink documentation warns that a URL on `blob/main/...` survives only as long as the file is at that path on the default branch; industry estimates place the rot rate on branch-pinned source URLs at 38-66% over a one-to-two-year horizon. The same observation drives the LSP `Location` shape (line-pinned references that survive refactors) and TypeDoc's defaults (commit SHA, not branch, for source-link generation). Branch-pinned URLs in a curated reference are a slow-burn correctness regression: they pass review, then quietly stop pointing at the right code as the source repo evolves.

#### When to keep an unpinned URL

Pin everything in references corpus content. The exception is **intentional latest** - pointers that are *meant* to drift with `main`, not freeze:

| Pointer purpose | Form | Where it appears |
|---|---|---|
| "Read this section as it is now" (the curated default) | SHA-pinned + line range | reference bodies in `references/<area-domain>-*.md` |
| "Read whatever is current upstream" (e.g., the project README, a stable spec page) | unpinned (`blob/main/...`, `tree/main/...`) | navigator prose, README pointers, "see the project" hints |
| "Read this exact stable release" | tag-pinned (`blob/v1.2.3/...`) | reference bodies; accepted equivalently to SHA-pinned |

The verify gate enforces this distinction: the SHA-pin invariant scans references corpus only - navigator prose, chapter prose, and READMEs may carry unpinned URLs without flagging.

#### Source identifier (`source_id`)

The SHA-pinned URL above pins a source's *contents* at a moment in time. The companion identifier `source_id` does a different job: it gives each source root a stable handle the engine can use to key per-source records — cache entries, harvested-artifact frontmatter, and pipeline discriminators — across maintainers and across machines.

```
source_id = sha256(path-relative-to-contextualizer-root)[:8]
```

Five properties this form pins:

* **The input is the source path relative to the contextualizer root, not the absolute path.** Absolute paths are local to one maintainer's filesystem; hashing them would give a different `source_id` to a colleague who clones the contextualizer to a different directory, breaking the per-source cache the moment the work crossed machines.
* **The hash function is SHA-256**, matching the project's choice for the fixture-harness byte-equality-fixture design (and the same family the engine already uses for SHA-pinned permalinks).
* **The output is the first 8 hex characters** of the digest — 32 bits, roughly 4.3 billion values.
* **The relative path is normalized to POSIX-canonical form before hashing.** Trailing slashes, leading `./`, and repeated separators are stripped; `./foo/`, `foo`, and `foo/` all produce the same `source_id`. Symlinks are not expanded — the path is treated as a logical name. The chapter prescribes the normalization semantically; the specific shell, scripting-language, or library invocation is an implementation concern, not contract surface.
* **The normalized path is rendered as UTF-8 bytes in NFC Unicode normalization, with forward-slash separators, case-preserving, before SHA-256 is applied.** Filesystems disagree on these defaults — some return NFD-decomposed filenames where others return NFC; some accept backslashes where others reject them — so without an explicit normalization the same logical path would hash differently across operating systems and the cross-machine stability promised at the top of this section would not hold. Case is preserved as-typed: `Foo` and `foo` produce different `source_id`s; on case-insensitive filesystems the maintainer's responsibility is to use consistent casing in the source-paths configuration across machines.

**Collision-resistance budget.** Eight hex characters give a 32-bit value space, with a birthday-collision probability of about 50% at roughly 77 thousand inputs (`1.177 · √(2³²)`). For a contextualizer with `N` source roots, the collision probability is about `N² / 2³³`:

* At `N = 10` sources, ~10⁻⁸ — comfortably below the bit-error rate of typical storage.
* At `N = 10,000` sources, ~10⁻² — no longer acceptable.

A contextualizer approaching `N ≈ 1000` source roots should plan ahead — well before crossing the 10⁻² threshold around `N = 10,000` — to widen `source_id` to 16 hex characters (multiplying the safe-N collision budget by 2¹⁶, since safe-N scales with the square root of the value space). v1 of the engine ships at 8 characters; the upgrade to 16 characters is future work, and no versioning field is defined yet.

**Downstream consumers.** Three places the engine relies on `source_id`:

* The per-root cache record under which the freshness algorithm in [`03-engine.md`](03-engine.md) groups per-file `<source_file_hash>` entries, so a source's classification survives between maintenance cycles.
* The provenance tag the harvest pipeline writes into the frontmatter of every harvested artifact, so an artifact's source of origin survives the journey from crawl to emission.
* The discriminator the emission stage uses to keep per-source artifacts under distinct `source_id` records when two source roots produce disagreeing material on the same topic, so the reviewer sees both side-by-side rather than having one silently shadow the other at consumption time.

**Frontmatter contract.** Every harvested artifact — a file the pipeline writes into the references corpus as the result of a source-root crawl — carries `source_id` in its frontmatter. This is a harvested-artifact rule, not a reference rule: hand-authored references at `references/<area-domain>-*.md` follow the [optional-description-only convention](#frontmatter-is-optional-description-only-when-present) (frontmatter present carries only a `description:` field, or is omitted entirely); harvested artifacts carry the richer `source_id` block. Harvested artifacts are discriminated from hand-authored references by a dedicated sub-directory (`references/_harvest/`) so the description-only-or-omitted scan and the SHA-pin scan continue to apply only to the top-level `references/*.md` shape, without false positives on pipeline output.

### Never-remove list

Some content has no source-doc equivalent. Don't replace it; keep it always:
* **Gotchas** ("this looks safe but isn't")
* **Cross-system patterns** ("when X needs to talk to Y, do Z")
* **Why context** (the reasoning behind a non-obvious decision)
* **Adoption data** (which teams use it, with what shape)
* **Dependency chains** (what breaks downstream when this changes)
* **Event/contract specifications synthesized from multiple sources**

These are the *curation* in a curated reference. They're why the AI assistant reaches for the contextualizer instead of grepping the source repo directly.

## When to split a reference

A reference outgrows itself before the size budget says it does. The numerical limit (500 lines / 18KB) is a backstop, not the primary signal. Watch for these signs and split before the cap forces the issue.

### Signals that a reference has outgrown one file

* **Approaching the size budget.** The reference is past ~80% of 500 lines or 18KB. You're one or two updates away from the cap; the cap will arrive at an inconvenient moment.
* **Mixed audiences.** The reference now serves two different reader types - say, application authors and platform infrastructure operators - who care about different sections. Each audience reads half the file and skips the other half.
* **Distinct query patterns.** When you trace which sections get loaded for which questions, two clusters emerge. One cluster is "API shape and consumption"; another is "authoring and extension." The reference is doing two jobs.
* **Repeated cross-references from outside.** A specific subset of the reference is linked to from many other references. That subset wants its own home.

If you see one signal, watch. If you see two, plan a split. If you see three, split now.

### How to choose the split shape

Two patterns cover most splits:

**Prefix family.** Tightly related sub-domains stay sibling-named:
* `<area-domain>-foo` (stays; becomes a router or shared-content reference)
* `<area-domain>-foo-X` (new; covers the X sub-domain)
* `<area-domain>-foo-Y` (new; covers the Y sub-domain)

Use this when the new references would feel "wrong" without the `foo` qualifier - when the sub-domains are distinct but cohesive (e.g., `<area-domain>-widgets`, `<area-domain>-widgets-modules`, `<area-domain>-widgets-infrastructure`).

**Domain split.** Genuinely separate concerns get their own top-level names:
* `<area-domain>-foo` (stays; loses the "bar" content)
* `<area-domain>-bar` (new; was previously a section of foo, now its own reference)

Use this when the sections are truly independent - they don't share gotchas, audiences, or examples. The split is breaking a cohabitation, not factoring a sub-domain.

### Checklist to execute a split

1.  Identify content boundaries (usually H2 section-level - mid-section splits indicate a forced split).
2.  Draft new reference files following the six prescribed sections; each is *complete*, not a fragment.
3.  Update the navigator catalog (add rows; update the source reference's description to reflect what remains).
4.  Add cross-reference map entries that route old query patterns to the new destinations.
5.  *(pre-fixture-harness aspirational, once the byte-equality fixture harness ships.)* Add byte-equality fixture entries for each new reference — see [05-invariants.md](05-invariants.md). The pre-fixture-harness state skips this step.
6.  Re-point existing references' "Related References" sections.
7.  Run pre-approval validation: catalog bijection, no-frontmatter, `./verify.sh`.

If the source reference loses everything to the split, delete it - don't leave an empty husk. Splits are reversible; merge back if the new references feel artificial.

## The bijection invariant (the load-bearing one)

The navigator's catalog table and the set of primary references form a bijection: every catalog row points to a real primary, and every primary appears as a catalog row.

A **primary** is either a single `.md` file at `references/<area-domain>-<topic>.md` (file form) OR a directory at `references/<area-domain>-<topic>/` containing the canonical primary `.md` of the same basename inside (directory form — see `### Reference depth (one level)` above). The bijection maps each catalog row to exactly one primary regardless of form. The catalog row's target text MAY be either `references/<area-domain>-<topic>.md` (file form) or `references/<area-domain>-<topic>/` (directory form, trailing-slash to disambiguate). Both render in Markdown as a working link; the directory link renders to the directory listing when followed. The bijection's set-equality is computed over canonical reference IDs (the slug without `.md` and without trailing `/`), so file form and directory form for the same `<slug>` collapse to one ID — and a same-slug present in both forms surfaces as a duplicate-primary failure.

### Why this is load-bearing

* An **orphaned file** (file exists, no catalog row) is invisible to the AI - wasted authoring effort.
* A **phantom row** (catalog row, no file) makes the AI try to read a file that doesn't exist - runtime failure mid-conversation.

Drift between the two is the most common form of bit-rot in this pattern.

The bijection is enforced by an automated test (`test_catalog_bijection` in [05-invariants.md](05-invariants.md)). The engine ([03-engine.md](03-engine.md)) re-checks the bijection before surfacing any change for human approval. Companion files are explicitly excluded from the bijection - only primaries (matching `<area-domain>-*.md`) participate.

When you add a reference, add the catalog row in the same change. When you rename a reference, update the catalog row in the same change. Treat them as one unit.

## Why these conventions exist

Pulling this together: every convention in this chapter exists to make either the navigator's loading model or the engine's pre-approval validation possible.

| Convention | What would break without it |
|---|---|
| **Two-field frontmatter** | Cross-platform navigator loading (some platforms drop unknown fields, others reject them) |
| **No frontmatter on references** | Navigator loading model breaks on at least one platform |
| **Six prescribed reference sections** | AI can't predict where to find a gotcha vs. a pattern; loads inefficiently |
| **Catalog bijection** | Orphaned files invisible; phantom rows cause runtime read failures |
| **Bare-named companion files** | AI can't distinguish primary from deep-dive; loads inefficiently |
| **Size budgets (< 500 lines, < 18KB)** | Reference reads burn context budget; defeats the on-demand-loading point |
| **Source-repo URL pointers** | Pointers break in consuming projects without the source dependency |

If you skip one, expect the corresponding failure mode.

[Next: 03-engine.md - Engine surface: workflows, freshness checks, circuit breaker, pre-approval validation](03-engine.md)