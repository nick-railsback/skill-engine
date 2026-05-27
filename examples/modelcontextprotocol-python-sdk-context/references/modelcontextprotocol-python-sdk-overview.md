---
name: modelcontextprotocol-python-sdk-overview
description: "Orientation for the MCP Python SDK at HEAD (v2 pre-alpha on main). Covers what the SDK is, the v1.x-vs-v2 split, top-level package layout, the recommended entry points (`mcp.server.mcpserver.MCPServer` vs `mcp.server.lowlevel.Server`), and the contributor ground rules in AGENTS.md (uv-only, anyio, 100% coverage)."
---

# MCP Python SDK — Overview

The Model Context Protocol (MCP) Python SDK is the official Python implementation of the [MCP specification](https://modelcontextprotocol.io/specification/latest) — a JSON-RPC protocol for connecting LLM applications to context-providing servers. The SDK lets you build both **servers** (which expose tools, resources, and prompts) and **clients** (which connect to any MCP server) without re-implementing the wire protocol.

The contextualizer tracks the `main` branch. **Read this first** — there is a non-obvious version split:

- **v1.x is the current stable release** and lives on the [`v1.x` branch](https://github.com/modelcontextprotocol/python-sdk/tree/v1.x). It is what `pip install mcp` ships today and what most users on the internet are writing about.
- **v2 is in development on `main`** and is pre-alpha (anticipated stable Q1 2026). HEAD of `main` is what every reference in this contextualizer cites. The high-level server class is **renamed from `FastMCP` to `MCPServer`**, Pydantic model fields are **snake_case** (not camelCase), `McpError` is **`MCPError`**, and the lowlevel `Server` uses **constructor `on_*` kwargs** instead of decorator handlers. See the migration reference for the full delta.

If you see code online importing `from mcp.server.fastmcp import FastMCP` or writing `result.isError`, that's v1 syntax — translate it before applying it to a v2 codebase.

## Public API surface

`src/mcp/__init__.py` defines the package's public API via `__all__`. Adding a symbol there is a deliberate API decision per [AGENTS.md](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/AGENTS.md) — these are the names you can safely import directly:

- **Client side**: `Client`, `ClientSession`, `ClientSessionGroup`, `StdioServerParameters`, `stdio_client`.
- **Server side**: `ServerSession`, `stdio_server`. The high-level `MCPServer` and lowlevel `Server` are reached via `mcp.server.mcpserver` and `mcp.server` respectively (intentionally not top-level — server-authoring is a deeper opt-in).
- **Errors**: `MCPError`, `UrlElicitationRequiredError`.
- **Protocol types** (from `mcp.types`): `Tool`, `Resource`, `CallToolRequest`, `ServerCapabilities`, etc.

Source: [`src/mcp/__init__.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/__init__.py).

## Package layout

The interesting code lives under `src/mcp/`:

| Module | What's there |
|---|---|
| `mcp.types` | Pydantic models for every protocol message (`Tool`, `CallToolResult`, `ContentBlock`, etc.) plus `TypeAdapter` instances for the union types. See the types reference. |
| `mcp.server` | The lowlevel `Server` class, transports (`stdio`, `sse`, `streamable_http`, `websocket`), `ServerSession`, `ServerRequestContext`. |
| `mcp.server.mcpserver` | The high-level `MCPServer` class (formerly `FastMCP`) with decorator-style tool/resource/prompt registration. The recommended entry point for new servers. |
| `mcp.server.lowlevel` | The lowlevel `Server` class for direct protocol control. Constructor `on_*` kwargs replace v1's decorator handlers. |
| `mcp.server.auth` | Server-side OAuth 2.1 components: token verifier, bearer middleware, authorization server provider, route handlers. |
| `mcp.client` | `Client` (high-level, in-memory friendly), `ClientSession`, `ClientSessionGroup`, transport clients (`stdio`, `sse`, `streamable_http`, `websocket`). |
| `mcp.client.auth` | `OAuthClientProvider`, `TokenStorage`, PKCE flow. |
| `mcp.shared` | Cross-cutting bits: `MCPError`, `auth` types, `memory` helpers for in-process testing, `exceptions`. |
| `mcp.cli` | The `mcp` console script (`mcp dev`, `mcp install`, etc.) — an optional `[cli]` extra. |

There is also a `mcp.server.experimental` namespace tracking draft-spec features (currently: tasks). See the experimental-tasks reference.

Source tree: [`src/mcp/`](https://github.com/modelcontextprotocol/python-sdk/tree/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp).

## Which entry point should I use?

For servers, almost always start with `MCPServer`:

```python
from mcp.server.mcpserver import MCPServer

mcp = MCPServer("Demo")

@mcp.tool()
def add(a: int, b: int) -> int:
    return a + b

if __name__ == "__main__":
    mcp.run(transport="stdio")
```

The lowlevel `Server` is for callers who need direct protocol access — handler-level control of every request type, custom validation, or features `MCPServer` doesn't yet expose (e.g., `subscribe_resource` registration in pure v2). Picking `MCPServer` does not lock you out of the lowlevel — `MCPServer._lowlevel_server` is reachable as an escape hatch (marked private; subject to change).

For clients, `Client` is the friendliest API — it can take a `Server`/`MCPServer` instance directly for in-memory testing or a streamable HTTP/stdio transport for production. `ClientSession` is the lower-level alternative used inside `streamable_http_client` / `stdio_client` context managers when you need raw stream access.

## Repo ground rules (relevant when patching the SDK)

The [`AGENTS.md`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/AGENTS.md) file documents the development conventions. The non-obvious ones:

- **uv only.** `uv add`, `uv run --frozen <tool>`, `uv lock --upgrade-package`. Never `uv pip install`, never `pip`, never `@latest`. The `--frozen` flag prevents `uv.lock` from being rewritten as a side effect.
- **anyio, not asyncio**, throughout the test suite and the SDK itself.
- **100% coverage gate**, with `strict-no-cover` as a second pass that fails if a line marked `# pragma: no cover` is ever executed. Avoid adding new `# pragma: no cover`, `# type: ignore`, or `# noqa` comments — they usually indicate a missing test.
- **Pytest `filterwarnings = ["error"]`**: warnings fail tests. Fix the underlying cause; don't silence.
- **Async tests** should not use `anyio.sleep()` to wait on events — use `anyio.Event` + `event.wait()` wrapped in `anyio.fail_after(5)`. Reach for threads only when necessary, subprocesses only as a last resort.
- **In-memory `Client(server)`** is the canonical end-to-end test shape — see `tests/client/test_client.py` for the pattern. `create_connected_server_and_client_session` was removed in v2.
- **Public APIs require type hints and docstrings.** Docstring's `Raises:` section covers exceptions a caller would reasonably catch (not argument-validation errors).
- **Breaking changes go in `docs/migration.md`**, grouped with related changes, not added as standalone sections at the bottom.
- **No `@deprecated` shims on `main`**. v2 deletes old APIs outright; v1.x receives backports for at least 6 months after v2 ships.

The pre-commit hook also rejects edits to `README.md` (frozen at v1) — edit `README.v2.md` instead.

## Quickstart links

- High-level server: [`examples/snippets/servers/mcpserver_quickstart.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/examples/snippets/servers/mcpserver_quickstart.py).
- Streamable HTTP client: [`examples/snippets/clients/streamable_basic.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/examples/snippets/clients/streamable_basic.py).
- Stdio client: [`examples/snippets/clients/stdio_client.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/examples/snippets/clients/stdio_client.py).
- OAuth client end-to-end: [`examples/snippets/clients/oauth_client.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/examples/snippets/clients/oauth_client.py).
- Full example servers (auth, sampling, simple stdio): [`examples/servers/`](https://github.com/modelcontextprotocol/python-sdk/tree/f4753440dac8b2b6fa6407808e06c51258b78322/examples/servers).
- v2 README (under construction): [`README.v2.md`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/README.v2.md).
- v1 README (current stable, frozen): [`README.md`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/README.md).

For production today, the [v1.x branch README](https://github.com/modelcontextprotocol/python-sdk/blob/v1.x/README.md) is the authoritative reference; v2 is the right target for new work that can wait for the stable release.
