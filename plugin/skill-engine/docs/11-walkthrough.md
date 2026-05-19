# 11-Walkthrough: library-context

This chapter walks through the engine producing an artifact called `library-context` end-to-end. The team is the maintainers of an open-source library — they have an API surface, a plugin system, configuration knobs, and deployment patterns to document. The references draw from real Flask source code, generalized as `library-context` to highlight the engine's shape rather than Flask itself. The artifact they ship to AI assistants is `library-context`; the engine they run alongside it is what keeps that artifact's references in sync with the upstream library code.

The artifact lives in `examples/library-context/` (../../examples/library-context/) — that's the actual filesystem output. This chapter is the narrative around it: why these choices, why those rejections, and how the engine's patterns from this guide compose in practice.

The example is deliberately small — one navigator, two references, no exotic mechanisms. Real artifacts grow past this in scope but not in shape.

## The decision flow

The team starts with a problem: every new contributor opens a Slack thread asking "where's the entry point?" or "how does the plugin lifecycle work?" The maintainer answers in their own words, ships some links, moves on. A week later, someone else asks the same question.

They decide to build a contextualizer.

### Step 1 - Scope the domain

The maintainer makes a list of every "where is X / how does Y work" question they've answered in the last quarter:

* "What's the public API surface for query operations?"
* "How do I write a plugin?"
* "What config knobs exist for cache behavior?"
* "How does the build/release pipeline actually run?"
* "What does the test harness expect from a fixture?"

Five rough domain clusters. Could be five references. But they pause — this guide warns against premature reference proliferation (see [02-artifact-contract.md](02-artifact-contract.md)).

### Step 2 - Pick the minimum viable catalog

The team applies the "3-5 references at the start" heuristic. They consolidate:

* "Public API for query operations" -> reference 1
* "Plugin lifecycle and authoring" -> reference 2
* "Config knobs" -> folded into reference 1 (config affects API behavior)
* "Build/release pipeline" -> out of scope; that's a different audience (release engineers, not library users)
* "Test harness fixtures" -> folded into reference 2 (plugins ship their own tests)

Two references. They name them `library-api` and `library-plugins`.

### Step 3 - Pick the navigator name

The contextualizer is `library-context`. The skill-engine convention is `<area-domain>-context`, where the area domain is your domain's short name (e.g., `identity`, `inventory`, `billing`). Here it's the library itself; call it `library`.

The catalog rows will reference the two primary references with relative paths.

### Step 4 - Decide what NOT to include

This is the hardest step. The team rejects three tempting additions:

* **A "getting started" reference.** That's onboarding content; the library's website handles it. The contextualizer is for deep questions, not first-touch.
* **A "deployment" reference.** Out of scope as decided in Step 2. Folding it back in would dilute the navigator.
* **A "FAQ" reference.** FAQs degrade fast — the questions change, the answers don't. Better to update the two real references when patterns change than maintain a separate FAQ.

The team writes these rejections into a "deliberately not included" note in the repo's contributing guide.

## Catalog rationale: why two references

The catalog rows look like this:

| Reference | Description |
|---|---|
| [library-api](references/library-api.md) | Public API surface, query operations, configuration knobs, return-value shapes |
| [library-plugins](references/library-plugins.md) | Plugin lifecycle, authoring contract, registration patterns, test fixtures |

**Why not three or four?** Because every reference adds:
* A catalog row to maintain in the navigator
* A bijection check that has to stay in sync
* A reference's worth of content to keep fresh
* Cross-reference pointers from the other references

For two references, the cross-reference map is one line. For five references, it's a small graph. Maintenance scales superlinearly with reference count; pre-empt it by starting small.

**When would this contextualizer split?** [02-artifact-contract.md "When to split a reference"](02-artifact-contract.md#when-to-split-a-reference) covers the signals. For `library-context`, the most likely split is plugin authoring growing past the size budget — at which point the team would split `library-plugins` into `library-plugins` (lifecycle, registration) + `library-plugins-authoring` (the deeper authoring guide). That's a Phase-2 decision the contextualizer earns over time.

## Sample queries: what hits each reference

How a Claude Code user would hit each reference, end-to-end:

### Query 1 - "What's the entry point for running a query?"

1. User asks the question in Claude Code with `library-context` installed.
2. Navigator's catalog has a row for `library-api` with the description "Public API surface, query operations, configuration knobs, return-value shapes."
3. Navigator's cross-reference map has a one-line rule: "Query / API questions start at library-api."
4. Claude reads `library-api.md`. Section "Critical Patterns" has the entry-point pattern with a code example.

**Token cost:** ~200 tokens for the catalog scan + ~3,500 tokens for `library-api.md`. The `library-plugins.md` reference is never loaded.

### Query 2 - "How do I write a plugin that runs before query parsing?"

1. User asks. Navigator scans catalog, sees `library-plugins` is the right reference.
2. Cross-reference map confirms: "Plugin authoring start at library-plugins."
3. Claude reads `library-plugins.md`. Section "Architecture Overview" describes the lifecycle hooks; "Critical Patterns" shows the pre-parse hook signature.
4. Section "Related References" points at `library-api` if the user needs query-shape details.

Cross-reference traversal adds 3,500 tokens only if needed. Most plugin questions don't need it.

### Query 3 - "What's the cache TTL config?"

1. User asks. Navigator catalog row for `library-api` mentions "configuration knobs."
2. Claude reads `library-api.md`. Section "Architecture Overview" lists the config knobs with a TTL row.
3. Query closes without loading `library-plugins.md`.

This is the **on-demand load** pattern in action. `library-plugins.md` could be 200 lines of plugin-specific detail; the cache-TTL question never reads any of it.

## A sample DISCOVER run

For `library-context` after a year in production, here's what a run looks like under the goal-given posture documented in [08-discover-pipeline.md](08-discover-pipeline.md).

> **Aside — web-doc upstreams.** If the upstream is a documentation site (e.g. MkDocs / Docusaurus / Sphinx), use `kind: web-doc` with `crawl_mode: sitemap`. The walkthrough below shows `git-managed` as the primary example; the `web-doc` flow differs only in step 3.6 (sitemap crawl) and step 5.5 (frontmatter check on the cache). See [recipes/web-doc-setup.md](recipes/web-doc-setup.md).

The contextualizer's `research/source-paths.json` carries three entries: `library` (the main repo), `library-cli` (a downstream CLI consumer), and `library-bench` (the benchmark suite that consumes both). All three are at `status: confirmed`, `lifecycle.state: reachable`. The team invokes `/skill-engine:discover`; the model reads each source via `gh repo view` / `git ls-tree` (preferring the CLI over WebFetch for `kind: git-managed`) and considers what to write.

> **Sidebar — no local cache.** If no `~/.cache/skill-engine/library-*/` directory exists (the team declined the seed offer at bootstrap, or recently ran `/skill-engine:clean-cache`), DISCOVER's pre-flight step 6 prompts once per git-managed source before reading:
>
> ```
> No local cache for library. Pre-clone from
> https://github.com/example/library into ~/.cache/skill-engine/?
> This speeds up this DISCOVER run and future REFRESH cycles. Skip
> if unsure. [y/N]
> ```
>
> On `y`, the skill clones via an atomic-rename idiom so a failed clone never leaves a half-written cache at the canonical path. On `N` (or anything not `y`/`yes`), DISCOVER proceeds via the `gh`/`git` CLI fallback documented in [08-discover-pipeline.md](08-discover-pipeline.md). The choice is sticky for the session; the prompt re-offers on the next DISCOVER if the cache is still missing.

The model finds:

* **Two existing references could grow.** `library-plugins.md` lacks coverage of two plugin variants (`library-plugins-redis`, `library-plugins-postgres`); `library-api.md` doesn't yet mention the CloudFront cache path (`library-cache-cloudfront`).
* **No new top-level references are warranted yet.** The candidates the model surfaced cluster cleanly under the existing two references.
* **Three candidates are excluded.** The model flags one archived prototype, one unclear-domain repo, and one old fork as deliberate skips.

The model writes the proposed additions and presents the diff. The team reviews and approves. The session closes with a paragraph-form post-run summary:

> I read N files across `library`, `library-cli`, and `library-bench`. The essence is X. I extended two references (`library-plugins.md` adds two plugin variants; `library-api.md` adds the CloudFront cache path) and emitted no new top-level references — the candidates clustered under the existing partition. I deliberately skipped one archived prototype, one repo whose domain was unclear, and one old fork. If you'd like me to revise, tell me a hint and rerun: `/skill-engine:discover --hint='<your hint>'` (e.g., `--hint='include the bench harness internals at high priority'`).

The total wall-clock is ~6 minutes including human review.

**What the team learns from this run:**
* The plugin ecosystem is producing more candidates than the API ecosystem. Not surprising — plugins are the open-extension surface.
* The summary's skip-reasoning makes the model's exclusion choices legible without a multi-screen review flow.
* The `--hint` invitation keeps lateral revision one keystroke away when the team disagrees with the partition.

## Decisions made along the way

A handful of small judgment calls in building this example:

### Choosing reference filenames

The convention is `<area-domain>-<topic>.md`. For this contextualizer the area domain is `library`, so:
* `library-api.md`
* `library-plugins.md`

A common alternative would be `library-context-api.md` — putting the full contextualizer name in the filename. Don't do this. The contextualizer name (`library-context`) is the **navigator** skill's name; the references live **under** it in `skills/library-context/references/`. Including `context` in every reference filename adds clutter without disambiguation. The directory path already disambiguates.

### Should companion files be primary references?

The example doesn't ship companion files. If the team grows a long code example for plugin authoring (say, 300 lines of TypeScript), they'd put it in `examples/library-context/references/plugin-authoring-example.ts` — or similar — as a **companion file** with a bare name (no `library-` prefix), linked to from `library-plugins.md`. Companion files don't appear in the catalog (see [02-artifact-contract.md](02-artifact-contract.md#companion-files)).

### How much code to include

The two references together contain maybe a dozen short code snippets — enough to show, not enough to teach. The reference is a navigator into the source code, not a replacement for it. When in doubt, link to the source repo and quote the function signature; don't paste the implementation.

### Voice and length

Each reference is ~170-200 lines, well under the 500-line ceiling. Could each be longer? Yes. Should they be? No. Past ~250 lines, the reference starts feeling like documentation; before that, it feels like a curated lookup. The example targets the latter.

### Monitoring a non-default branch

The example tracks the library repo's default branch — that's the common case. When the maintainer ran `/skill-engine:engine-bootstrap`, Step 2.4 prompted once per `kind: git-managed` source:

> For `<url>`:
> Monitor the repo's default branch? Press Enter or `y` to track HEAD
> (main/master/whatever the repo points at). Or type a branch name
> (e.g. `dev`, `nonprod`, `release/v2`) to monitor that branch
> instead. [Enter/y = default]

Pressing Enter omitted the `branch` field — the schema is additive, and an absent field stays correct even if upstream later renames its default. If the team wanted to track a non-default branch (say, the integration branch a release train runs on), they would answer Step 2.4 with `release/v2` instead, and the entry would land as `{ "id": "library", "kind": "git-managed", "url": "...", "branch": "release/v2", ... }`. REFRESH's SHA comparison and DISCOVER's local clone then follow that branch, and SHA-pinned permalinks cite commits from it — never the default branch.

## Working with the example

Look at the example as a unit:

```text
examples/library-context/
  SKILL.md                 # navigator (two-field frontmatter, 5 sections)
  references/
    library-api.md         # six prescribed sections, well under size budget
    library-plugins.md     # six prescribed sections, well under size budget
    (no companion files in this example)
```

Running the same conventions this guide preaches:
* **SKILL.md has two-field frontmatter:** name and description only.
* **References have NO frontmatter:** first line is the H1.
* **A common reference shape used in this example:** When to Use, Architecture Overview, Critical Patterns, Common Gotchas, Key Components, Related References. Under goal-given DISCOVER, the model varies body shape by what the source domain rewards; this six-section shape is one acceptable form, not a contract requirement.
* **Catalog bijection:** every catalog row has a real file; every primary reference file has a catalog row.
* **Size discipline:** both references are well under 500 lines / 18KB.

If you fork this and start writing your own contextualizer, the example is a structural template, not a content template. Replace every word; keep the shape.

[Next: Back to README full ToC and reading order](README.md)