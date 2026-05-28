---
name: modelcontextprotocol-python-sdk-context
description: "Answers questions about the official Model Context Protocol (MCP) Python SDK (`mcp` package on PyPI, `modelcontextprotocol/python-sdk` on GitHub). Tracks the `main` branch (v2 pre-alpha — `MCPServer`/snake_case/constructor-`on_*` handlers). Use when working with MCP servers or clients in Python, debugging v1→v2 migrations, or answering questions about tools, resources, prompts, transports, OAuth, or experimental tasks. References load on demand from `references/`."
---

# Context navigator

## Overview

This navigator catalogs references for the official MCP Python SDK at GitHub SHA `3eb579948a4719d606d2adbd1f3f69371c9c0f48` (HEAD of `main` on 2026-05-26). HEAD is **v2 pre-alpha**; the current stable release lives on the [`v1.x` branch](https://github.com/modelcontextprotocol/python-sdk/tree/v1.x) and uses the older `FastMCP` / camelCase / decorator-based APIs. All references in this contextualizer document v2 syntax — if you have v1 code in front of you, start with the migration reference.

When asked a question this navigator's domain covers:

1. Scan the **Catalog** below for the matching topic.
2. Follow the link to read the reference file.
3. If the question spans multiple references, consult the **Cross-reference map**.
4. If a reference points at a source URL for deeper detail, follow it only if the reference itself didn't answer the question.

## Catalog

| Reference | Description |
|---|---|
| [overview](references/modelcontextprotocol-python-sdk-overview.md) | Orientation: what the SDK is, v1.x vs v2 split, top-level package layout, recommended entry points (`MCPServer` vs lowlevel `Server`), AGENTS.md ground rules (uv-only, anyio, 100% coverage). Start here for new readers. |
| [mcpserver](references/modelcontextprotocol-python-sdk-mcpserver.md) | High-level server via `MCPServer` (formerly `FastMCP`): `@tool/@resource/@prompt` decorators, `Context` injection, structured output, `Image`/`Audio`/`Icon`, lifespan, elicitation, sampling, `run()` and ASGI mounting. The default path for new server code. |
| [lowlevel-server](references/modelcontextprotocol-python-sdk-lowlevel-server.md) | Lowlevel `Server` class: constructor `on_*` keyword handlers (no decorators in v2), full handler-name reference table, when to drop down from `MCPServer`, no automatic return-value wrapping, `streamable_http_app()` from the lowlevel. |
| [client](references/modelcontextprotocol-python-sdk-client.md) | Writing MCP clients: `Client` (in-memory or remote), `ClientSession` for raw streams, `ClientSessionGroup` for fan-out, calling tools/resources/prompts, paginated lists with `PaginatedRequestParams`, the four callbacks (sampling, elicitation, list-roots, logging). |
| [transports](references/modelcontextprotocol-python-sdk-transports.md) | MCP transports in the Python SDK: stdio, SSE (legacy), streamable HTTP (recommended), and websocket. Covers `stdio_client` / `streamable_http_client` / `sse_client` signatures, server-side `stdio_server` and `MCPServer.streamable_http_app()`, mounting in Starlette/ASGI, the v2 `httpx.AsyncClient` injection pattern, DNS-rebinding protection, and the session-ID capture workaround. |
| [auth](references/modelcontextprotocol-python-sdk-auth.md) | OAuth 2.1 authentication in the MCP Python SDK. Server-side: `TokenVerifier` protocol, `OAuthAuthorizationServerProvider`, `AuthSettings`, bearer-token middleware, and the resource-server vs. authorization-server modes. Client-side: `OAuthClientProvider` with PKCE, `TokenStorage` interface, callback flow. |
| [types](references/modelcontextprotocol-python-sdk-types.md) | `mcp.types` — protocol Pydantic models with snake_case attribute access (camelCase wire), `_adapter` TypeAdapter instances that replaced `RootModel` unions, `ContentBlock` taxonomy, `str`-vs-`AnyUrl` URI shift, JSON-RPC error code constants, `_meta` extension field. |
| [migration-v1-to-v2](references/modelcontextprotocol-python-sdk-migration-v1-to-v2.md) | Concise port-your-code cheatsheet. `FastMCP`→`MCPServer`, `McpError`→`MCPError`, decorators→`on_*` kwargs, `streamablehttp_client`→`streamable_http_client`, camelCase→snake_case, `AnyUrl`→`str`, removed helpers, search-and-replace strategy. |
| [experimental-tasks](references/modelcontextprotocol-python-sdk-experimental-tasks.md) | Experimental async-tasks feature: lifecycle states, `enable_tasks()` setup, `ServerTaskContext`, client-side `call_tool_as_task` + `poll_task`, `TaskStore` interface. Tracks the draft MCP spec — API may change without notice. |

## Cross-reference map

- **"How do I build a server?"** → start at `mcpserver` for the happy path; drop to `lowlevel-server` only if you need handler-level protocol control. The `auth` reference layers on top of either.
- **"My v1 code is broken on `main`."** → `migration-v1-to-v2` is the entry point; it links out to `mcpserver`, `lowlevel-server`, `transports`, and `types` for the patterns the migration touches.
- **"Why won't my client connect?"** → `transports` first (especially the `httpx.AsyncClient` injection pattern and DNS-rebinding rules); `client` second for `ClientSession` vs `Client` semantics.
- **"What does this field name mean?"** or **"Why is `RootModel.root` gone?"** → `types`.
- **"How do I authenticate?"** → `auth`; pairs with `transports` (streamable HTTP carries the bearer token) and the URL-elicitation pattern in `mcpserver`.
- **"How do I get the authenticated OAuth user inside my tool?"** → `auth` for the `get_access_token()` accessor and `AccessToken.subject`/`.claims`; pairs with `mcpserver` (the `Context.client_id` gotcha — that property reads MCP `_meta`, not the bearer token).
- **"My tool needs to take a long time."** → `experimental-tasks`; pairs with `mcpserver` (Context/progress) and `lowlevel-server` (where tasks register today).
- **"What ground rules apply to patches against the SDK?"** → `overview`'s "Repo ground rules" section (uv-only, anyio, 100% coverage, no `@deprecated` shims on `main`).

## Markdown style for generated references

Reference files use **soft wrapping**: one paragraph per line, no hard line breaks at fixed column widths. Editors and rendered Markdown reflow at viewport width. Do not insert manual line breaks within a paragraph to keep lines under ~80 columns — that produces mid-sentence breaks in rendered output and makes diffs noisier. Code blocks, tables, bullet lists, and headings follow their own rules; this directive applies to prose paragraphs only.

## Instructions to Claude

When loading a reference file, the path syntax depends on the platform:

* **Claude Code**: Read the reference using the platform-provided skill-directory variable: `Read $CLAUDE_SKILL_DIR/references/<source-slug>-<topic>.md`

* **Claude Desktop**: Read the reference using a relative path; the platform resolves it from the skill's installed location: `Read references/<source-slug>-<topic>.md`

Loading rules:

* Load one reference at a time unless the Cross-reference map says to load both.
* If the primary reference doesn't fully answer the question, follow any source URL pointers it provides for deeper detail.
* Do not eagerly load companion files; only follow companion links when the primary reference says to.
* If the user's question is clearly out of scope for this contextualizer, don't invoke this skill at all.

## Progressive disclosure

References prioritize curated insight over re-specifying upstream sources:

* **Gotchas, cross-system patterns, and "why" context** are kept in the reference (curation value).
* **Exact schemas, API signatures, and parameter lists** are summarized in the reference and linked to their authoritative source via source URLs.

When a reference includes a source URL pointer, follow it only when the reference's own summary didn't cover the question. The contextualizer is optimized for the common case; the upstream source is the long tail.

## Optional SKILL.json sibling

This navigator MAY ship a `SKILL.json` sibling alongside this `SKILL.md` for machine-readable consumers (downstream tools and non-Claude agents that prefer structured metadata to markdown parsing). The sibling is purely opt-in additive — contextualizers without it pass verification unchanged.

When `SKILL.json` is present, the `## Catalog` table above, the SKILL.json `catalog[]` entries, and the `references/<source-slug>-*.md` files on disk must be in three-way correspondence. Entries carrying `"draft": true` in SKILL.json are excluded from this trijection and surface as a one-line summary at verify time. The `skill-json-trijection` named check fires only when SKILL.json is present; absence is a silent-skip pass.

Full schema: see [`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md) §"SKILL.json".
