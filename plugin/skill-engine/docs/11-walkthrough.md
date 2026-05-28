# 11-Walkthrough: modelcontextprotocol-python-sdk-context

This chapter walks through the engine producing an artifact called `modelcontextprotocol-python-sdk-context` end-to-end. The team is adopting the MCP Python SDK for an internal AI product — they need to teach Claude (or any other AI assistant) how to write MCP servers and clients in the v2 syntax, work through the v1→v2 migration when they hit legacy code, and answer questions about transports, auth, and types without re-reading the spec each time. The references draw directly from the v2 pre-alpha branch of `modelcontextprotocol/python-sdk`; the contextualizer is what keeps those references in sync as the SDK evolves.

The artifact lives in [`examples/modelcontextprotocol-python-sdk-context/`](../../examples/modelcontextprotocol-python-sdk-context/) — that's the actual filesystem output. This chapter is the narrative around it: which questions earned a reference, which were rejected, and how the engine's patterns from this guide compose in practice.

The example is **larger than the recommended starting point** — nine references, not two — and that's part of the lesson. The team didn't start with nine; they started with three (overview, server, client) and grew the catalog as the v2 migration surfaced clean partitions. This chapter shows that growth path.

## The decision flow

The team starts with a problem: every contributor writing MCP servers asks the same five questions on their first day. "Do I use `FastMCP` or `MCPServer`? Wait, those are the same thing? Or are they?" "Why is the constructor taking `on_*` keyword arguments instead of decorators?" "What changed from v1?" The maintainer answers in their own words, ships some links, moves on. A week later, someone else asks the same five questions.

They decide to build a contextualizer.

### Step 1 - Scope the domain

The maintainer makes a list of every "where is X / how does Y work" question they've answered in the last quarter:

* "How do I build an MCP server in v2?"
* "How does the new `on_*` handler kwarg pattern work in the lowlevel `Server` class?"
* "What's the right transport for a remote MCP client — `stdio`, `sse`, `streamable_http`, websocket?"
* "How does OAuth 2.1 auth work end-to-end (`TokenVerifier`, `OAuthClientProvider`, PKCE)?"
* "I have working v1 code — what's the migration path to v2?"
* "Why is `RootModel.root` gone?" / "Why is `AnyUrl` now `str`?"
* "What's the experimental tasks feature for?"

Seven rough domain clusters. Could be seven references. The team pauses — this guide warns against premature reference proliferation (see [02-artifact-contract.md](02-artifact-contract.md)).

### Step 2 - Pick the minimum viable catalog (and let it grow)

The team applies the "3-5 references at the start" heuristic. They start with three:

* `modelcontextprotocol-python-sdk-overview` — orientation, v1.x vs v2 split, package layout
* `modelcontextprotocol-python-sdk-mcpserver` — high-level server (the happy path)
* `modelcontextprotocol-python-sdk-client` — writing MCP clients

Three references. Three months later, the v2 pre-alpha lands breaking changes faster than the team can answer questions in-thread. They split out:

* `modelcontextprotocol-python-sdk-migration-v1-to-v2` — concise port cheatsheet (the team accepts a larger reference here because v2 introduced a lot of surface)
* `modelcontextprotocol-python-sdk-lowlevel-server` — when you must drop down from `MCPServer`
* `modelcontextprotocol-python-sdk-transports` — stdio vs SSE vs streamable HTTP vs websocket
* `modelcontextprotocol-python-sdk-auth` — OAuth 2.1 server + client patterns
* `modelcontextprotocol-python-sdk-types` — the `mcp.types` Pydantic models
* `modelcontextprotocol-python-sdk-experimental-tasks` — opt-in async-tasks feature

Nine references at steady state. Each split came from a real signal (a contributor asking the same question twice; a v2 breaking change that broke an existing reference's narrative). None were preemptive.

### Step 3 - Pick the navigator name

The contextualizer is `modelcontextprotocol-python-sdk-context`. The skill-engine convention is `<area-domain>-context`, where the area domain is your domain's short name. Here the source-id slug already encodes the upstream identity (`modelcontextprotocol-python-sdk`), so the navigator inherits it as the area domain.

The catalog rows reference each primary file with relative paths under `references/`.

### Step 4 - Decide what NOT to include

This is the hardest step. The team rejects four tempting additions:

* **An `mcp-protocol-spec` reference.** That's the wire-format MCP spec — out of scope. This contextualizer documents the *Python SDK's expression* of the spec, not the spec itself. A reader who needs the wire format should follow the source URL pointers to the spec repo directly.
* **An `mcp-typescript-sdk` reference.** A different SDK with its own idioms; would dilute the navigator's domain. Worth a sibling contextualizer (`modelcontextprotocol-typescript-sdk-context`), not a reference here.
* **An `mcp-anthropic-platform` reference.** Anthropic-specific integration patterns (Claude Desktop, Claude API): that's downstream consumer guidance, not SDK guidance. The team decided their internal product's integration patterns live in a separate internal contextualizer.
* **A "getting started" reference.** That's onboarding content; the SDK's `README.md` and `examples/` directory handle it. The contextualizer is for deep questions, not first-touch.

The team writes these rejections into a "deliberately not included" note in the repo's contributing guide.

## Catalog rationale: why nine references at steady state

| Reference | What it covers |
|---|---|
| `overview` | Orientation: package layout, v1.x vs v2, recommended entry points |
| `mcpserver` | High-level server via `MCPServer` (the default path for new code) |
| `lowlevel-server` | When you must drop down — `on_*` kwarg handlers, no decorators |
| `client` | Writing clients — `Client`, `ClientSession`, the four callbacks |
| `transports` | stdio / SSE / streamable HTTP / websocket — when to use each |
| `auth` | OAuth 2.1 server + client patterns, `TokenVerifier`, `OAuthClientProvider` |
| `types` | The `mcp.types` Pydantic models, snake_case vs camelCase, `_adapter` |
| `migration-v1-to-v2` | Port-your-code cheatsheet — search-and-replace strategy |
| `experimental-tasks` | Opt-in async-tasks feature; tracks the draft MCP spec |

**Why not five? Or fifteen?** The split was driven by upstream pressure, not by intuition. v2's pre-alpha cleanly partitions the surface (server vs client, high-level vs lowlevel, transport vs auth, stable vs experimental). Each reference maps to one partition. Going below five would force the team to discuss server and client in the same reference, which breaks the "section per topic" reading model. Going above ten would mean splitting transports into "stdio reference" and "HTTP reference," which the SDK itself does not separate — a partition the engine would create artificially.

Cross-reference map maintenance scales superlinearly with reference count. For nine references the cross-reference map is ten one-liners. That's a budget the team accepts; another reference would push it past the point where a reader can skim it in fifteen seconds.

## Sample queries: what hits each reference

How a Claude Code user would hit each reference, end-to-end:

### Query 1 - "How do I build an MCP server that takes a long time to respond?"

1. User asks. Navigator scans catalog; sees `mcpserver` is the default server reference.
2. Cross-reference map adds: "My tool needs to take a long time → experimental-tasks."
3. Claude reads `mcpserver.md` first (Context/progress patterns for in-flight reporting), then loads `experimental-tasks.md` to evaluate whether opt-in tasks are the right fit.

**Token cost:** ~200 tokens for the catalog scan + ~3,800 tokens for `mcpserver.md` + ~3,400 tokens for `experimental-tasks.md` (only because the cross-reference map flagged the pairing). The other seven references stay unloaded.

### Query 2 - "My v1 code is broken on `main` — what changed?"

1. User asks. Navigator catalog has a row for `migration-v1-to-v2` whose description is "concise port-your-code cheatsheet."
2. Cross-reference map: "My v1 code is broken on `main` → migration-v1-to-v2."
3. Claude reads `migration-v1-to-v2.md`. Search-and-replace strategy applies. If the migration introduces a v2-specific pattern (e.g., `streamable_http_client` signature), the migration ref links into `transports.md` for the depth.

Cross-reference traversal adds 3,500 tokens only when the migration step references a v2-specific pattern. Most migrations don't need it.

### Query 3 - "How do I authenticate an MCP request?"

1. User asks. Navigator catalog row for `auth` mentions "OAuth 2.1 authentication."
2. Cross-reference map: "How do I authenticate? → auth; pairs with transports (streamable HTTP carries the bearer token)."
3. Claude reads `auth.md`. The server-side `TokenVerifier` flow answers most of it. If the user is on streamable HTTP, the auth ref points at `transports.md` for the bearer-token middleware.

This is the **on-demand load** pattern in action. `mcpserver.md`, `client.md`, `types.md`, etc. are never loaded — the question maps cleanly to two references via the cross-reference map.

## A sample DISCOVER run

For `modelcontextprotocol-python-sdk-context` after a year in production, here's what a run looks like under the goal-given posture documented in [08-discover-pipeline.md](08-discover-pipeline.md).

> **Aside — web-doc upstreams.** This example uses `kind: git-managed` because the upstream is a GitHub repo with code, types, and inline docstrings — the engine reads the source directly. If the upstream were a documentation site (e.g., MkDocs / Docusaurus / Sphinx), the team would use `kind: web-doc` with `crawl_mode: sitemap`. The bundled [`inspect-ai-context`](../../examples/inspect-ai-context/) is the canonical example of `web-doc` source kind in action — it pulls both a git-managed source AND a sitemap-crawled docs portal.

The contextualizer's `research/source-paths.json` carries one entry: `modelcontextprotocol-python-sdk` at `status: confirmed`, `lifecycle.state: reachable`, tracking the `main` branch (v2 pre-alpha) by omitting the `branch` field. The team invokes `/skill-engine:discover`; the model reads the repo via `gh repo view` / `git ls-tree` (preferring the CLI over WebFetch for `kind: git-managed`) and considers what to write.

> **Sidebar — no local cache.** If no `~/.cache/skill-engine/modelcontextprotocol-python-sdk-*/` directory exists (the team declined the seed offer at bootstrap, or recently ran `/skill-engine:clean-cache`), DISCOVER's pre-flight step 6 prompts once before reading:
>
> ```
> No local cache for modelcontextprotocol-python-sdk. Pre-clone from
> https://github.com/modelcontextprotocol/python-sdk into
> ~/.cache/skill-engine/? This speeds up this DISCOVER run and future
> REFRESH cycles. Skip if unsure. [y/N]
> ```
>
> On `y`, the skill clones via an atomic-rename idiom so a failed clone never leaves a half-written cache at the canonical path. On `N` (or anything not `y`/`yes`), DISCOVER proceeds via the `gh`/`git` CLI fallback documented in [08-discover-pipeline.md](08-discover-pipeline.md). The choice is sticky for the session; the prompt re-offers on the next DISCOVER if the cache is still missing.

The model finds:

* **Two existing references could grow.** `mcpserver.md` lacks coverage of a new `elicitation` callback variant introduced last week; `transports.md` doesn't yet mention the WebSocket re-handshake quirk discovered in `tests/integration/transport_test.py`.
* **No new top-level references are warranted yet.** A candidate for "mcp resources" was considered and rejected — the resource surface is small enough to fit inside `mcpserver.md` under the `@resource` decorator section.
* **One candidate is excluded.** The model flags an in-progress draft PR (the `/feature/protocol-extensions` branch) as deliberately skipped — the PR's API surface is unstable and will likely be rewritten before merge.

The model writes the proposed additions and presents the diff. The team reviews and approves. The session closes with a paragraph-form post-run summary:

> I read N files across `modelcontextprotocol-python-sdk`. The essence is X. I extended two references (`mcpserver.md` adds the new `elicitation` callback variant; `transports.md` adds the WebSocket re-handshake quirk) and emitted no new top-level references — the resource surface clustered cleanly under `mcpserver.md`. I deliberately skipped one in-progress draft PR. If you'd like me to revise, tell me a hint and rerun: `/skill-engine:discover --hint='<your hint>'` (e.g., `--hint='split out the resources section into its own reference'`).

The total wall-clock is ~5 minutes including human review.

**What the team learns from this run:**
* The transport edge cases produce more candidates than the type-system surface. Not surprising — transports cross network boundaries and surface heterogeneous bugs.
* The summary's skip-reasoning makes the model's exclusion choices legible without a multi-screen review flow.
* The `--hint` invitation keeps lateral revision one keystroke away when the team disagrees with the partition.

## Decisions made along the way

A handful of small judgment calls in building this example:

### Choosing reference filenames

The convention is `<source-slug>-<topic>.md`. For this contextualizer the source-slug is `modelcontextprotocol-python-sdk`, so:
* `modelcontextprotocol-python-sdk-overview.md`
* `modelcontextprotocol-python-sdk-mcpserver.md`
* (and so on)

A common alternative would be `mcp-overview.md` — a shorter, abbreviated name. Don't do this. The contextualizer's `verify.sh` catalog-density check is keyed off the source-slug prefix; an abbreviated filename breaks the per-source row attribution the check needs. The verbose-but-correct prefix also disambiguates if the team grows a second contextualizer for the TypeScript SDK later.

### Should companion files be primary references?

The example doesn't ship companion files. If the team grew a long code example for a transport (say, 300 lines of streamable HTTP setup), they'd put it in `examples/modelcontextprotocol-python-sdk-context/references/streamable-http-fastapi-example.py` — or similar — as a **companion file** with a bare name (no `modelcontextprotocol-python-sdk-` prefix), linked to from `transports.md`. Companion files don't appear in the catalog (see [02-artifact-contract.md](02-artifact-contract.md#companion-files)).

### How much code to include

The nine references together contain several dozen short code snippets — enough to show, not enough to teach. The reference is a navigator into the source code, not a replacement for it. When in doubt, link to the source repo at a SHA-pinned permalink and quote the function signature; don't paste the implementation.

### Voice and length

References range from ~95 lines (`overview`) to ~300 lines (`migration-v1-to-v2`), all under the 500-line ceiling. Could each be longer? Yes. Should they be? No. Past ~300 lines, the reference starts feeling like documentation; before that, it feels like a curated lookup. The example targets the latter.

The `migration-v1-to-v2` reference is the exception — at ~300 lines, it's larger because v2 introduced enough breaking changes that a shorter ref would force the reader to bounce between this ref and the changelog. The team accepted the size because the bounce cost is real.

### Monitoring a non-default branch

The example tracks the SDK repo's `main` branch — that's the v2 pre-alpha, which is HEAD for the current `modelcontextprotocol/python-sdk` repo. When the maintainer ran `/skill-engine:engine-bootstrap`, Step 2.4 prompted:

> For `https://github.com/modelcontextprotocol/python-sdk`:
> Monitor the repo's default branch? Press Enter or `y` to track HEAD
> (main/master/whatever the repo points at). Or type a branch name
> (e.g. `dev`, `nonprod`, `release/v2`) to monitor that branch
> instead. [Enter/y = default]

Pressing Enter omitted the `branch` field — the schema is additive, and an absent field stays correct even if upstream later renames its default. If the team wanted to track the `v1.x` branch instead (e.g., to maintain a sibling contextualizer for v1 stable users), they would answer Step 2.4 with `v1.x`, and the entry would land as `{ "id": "modelcontextprotocol-python-sdk-v1", "kind": "git-managed", "url": "...", "branch": "v1.x", ... }`. REFRESH's SHA comparison and DISCOVER's local clone then follow that branch, and SHA-pinned permalinks cite commits from it — never `main`.

## Working with the example

Look at the example as a unit:

```text
examples/modelcontextprotocol-python-sdk-context/
  SKILL.md                                             # navigator (two-field frontmatter, catalog + cross-ref map)
  references/
    modelcontextprotocol-python-sdk-overview.md        # orientation
    modelcontextprotocol-python-sdk-mcpserver.md       # high-level server
    modelcontextprotocol-python-sdk-lowlevel-server.md # lowlevel server
    modelcontextprotocol-python-sdk-client.md          # writing clients
    modelcontextprotocol-python-sdk-transports.md      # stdio / SSE / streamable HTTP / websocket
    modelcontextprotocol-python-sdk-auth.md            # OAuth 2.1
    modelcontextprotocol-python-sdk-types.md           # mcp.types
    modelcontextprotocol-python-sdk-migration-v1-to-v2.md  # port cheatsheet
    modelcontextprotocol-python-sdk-experimental-tasks.md  # opt-in async tasks
    (no companion files in this example)
  research/
    source-paths.json   # one source: modelcontextprotocol/python-sdk on main
  verify.sh             # stamped from the bootstrap template
```

Running the same conventions this guide preaches:
* **SKILL.md has two-field frontmatter:** `name:` and `description:` only.
* **References have NO YAML frontmatter:** every reference file in this example starts with its `# Reference Title` H1. This matches Anthropic's canonical Agent Skills practice — frontmatter is scoped to `SKILL.md` only; supporting markdown files are pure Markdown.
* **A common reference shape used in this example:** When to Use, Architecture Overview, Critical Patterns, Common Gotchas, Key Components, Related References. Under goal-given DISCOVER, the model varies body shape by what the source domain rewards; this six-section shape is one acceptable form, not a contract requirement.
* **Catalog bijection:** every catalog row has a real file; every primary reference file has a catalog row.
* **Size discipline:** every reference is under 500 lines / 18KB. The `migration-v1-to-v2` reference at ~300 lines is the largest and intentionally so.

If you fork this and start writing your own contextualizer, the example is a structural template, not a content template. Replace every word; keep the shape.

[Next: Back to README full ToC and reading order](README.md)
