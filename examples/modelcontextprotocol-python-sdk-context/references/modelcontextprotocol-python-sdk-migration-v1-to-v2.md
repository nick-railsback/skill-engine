---
name: modelcontextprotocol-python-sdk-migration-v1-to-v2
description: "Cheatsheet for porting v1 MCP Python SDK code to v2 (in development on `main`). Covers the FastMCP→MCPServer rename, McpError→MCPError, decorator handlers→constructor `on_*` kwargs, camelCase→snake_case, AnyUrl→str, streamablehttp_client→streamable_http_client signature changes, union types→TypeAdapter, removed helpers, and reachable replacements."
---

# MCP Python SDK — Migration v1 → v2

This is the dense version. If you have v1 code and want a checklist for porting it to v2 syntax on the `main` branch, read this. The authoritative upstream reference is [`docs/migration.md`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/docs/migration.md) — this reference summarizes that file at SHA `f4753440` and pulls out the patterns that bite hardest.

**Context:** `main` is v2 pre-alpha, anticipated stable Q1 2026. v1.x is the current stable release on the `v1.x` branch. There are **no `@deprecated` shims on `main`** — old APIs are deleted outright. If your import or attribute doesn't work, it's because v2 removed it.

## The big renames

| v1 | v2 | Module |
|---|---|---|
| `FastMCP` | `MCPServer` | `mcp.server.fastmcp` → `mcp.server.mcpserver` |
| `McpError` | `MCPError` | `mcp.shared.exceptions` (also `from mcp import MCPError`) |
| `streamablehttp_client` | `streamable_http_client` | `mcp.client.streamable_http` |
| `Content` | `ContentBlock` | `mcp.types` |
| `ResourceReference` | `ResourceTemplateReference` | `mcp.types` |
| `Cursor` | plain `str` | — |
| `RequestParams.Meta` (Pydantic) | `RequestParamsMeta` (TypedDict) | `mcp.types` |

All `mcp.server.fastmcp.*` submodules moved to `mcp.server.mcpserver.*` with the same structure. Common new imports (see [`src/mcp/server/mcpserver/__init__.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/__init__.py#L1-L9) and [`src/mcp/server/mcpserver/exceptions.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/exceptions.py#L1-L18)):

```python
from mcp.server.mcpserver import MCPServer, Context, Image, Audio, Icon
from mcp.server.mcpserver.prompts.base import UserMessage, AssistantMessage
from mcp.server.mcpserver.exceptions import ToolError, ResourceError
```

## Field name changes (Pydantic models)

All `mcp.types` models now use **snake_case** attribute names. The wire format is unchanged (camelCase via Pydantic aliases). `populate_by_name=True` keeps old camelCase **constructor kwargs** working, but attribute reads must use snake_case. Source: [`src/mcp/types/_types.py` L39-L43 `MCPModel`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L39-L43):

```python
# v1
if result.isError: ...
cursor = result.nextCursor
schema = tool.inputSchema

# v2
if result.is_error: ...
cursor = result.next_cursor
schema = tool.input_schema
```

Common renames: `inputSchema`→`input_schema`, `outputSchema`→`output_schema`, `isError`→`is_error`, `nextCursor`→`next_cursor`, `mimeType`→`mime_type`, `structuredContent`→`structured_content`, `serverInfo`→`server_info`, `protocolVersion`→`protocol_version`, `uriTemplate`→`uri_template`, `listChanged`→`list_changed`, `progressToken`→`progress_token`. Source: [`src/mcp/types/_types.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L134-L665).

## Resource URI is now `str`, not `AnyUrl`

The MCP spec defines URIs as plain strings. v2 aligns ([`Resource.uri: str`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L632-L640)):

```python
# v1
from pydantic import AnyUrl
Resource(name="test", uri=AnyUrl("users/me"))  # rejected as invalid URL
await client.read_resource(AnyUrl("test://resource"))

# v2
Resource(name="test", uri="users/me")     # OK — relative paths allowed
Resource(name="test", uri="custom://x")   # OK — any scheme
await client.read_resource("test://resource")  # str only
```

Convert any `AnyUrl` instances with `str(my_url)`. Source: [`docs/migration.md` — Resource URI type changed](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/docs/migration.md#L711).

## Union types: `_adapter` instead of `RootModel`

These types are no longer `RootModel` subclasses, so no `.root` and no direct `.model_validate()`. Source: [`src/mcp/types/_types.py` L1596-L1615 `ClientRequest` union + `client_request_adapter`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L1596-L1615):

`ClientRequest`, `ServerRequest`, `ClientNotification`, `ServerNotification`, `ClientResult`, `ServerResult`, `JSONRPCMessage`. Source: [`src/mcp/types/_types.py` L1596-L1778](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L1596-L1778) and [`src/mcp/types/jsonrpc.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/jsonrpc.py#L79-L83).

```python
# v1
request = ClientRequest.model_validate(data)
inner = request.root

# v2
from mcp.types import client_request_adapter
request = client_request_adapter.validate_python(data)
# request IS the variant — no .root
```

When sending, drop the wrapper (see [`src/mcp/shared/session.py` `send_notification`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/shared/session.py#L310-L320)):

```python
# v1
await session.send_notification(ClientNotification(InitializedNotification()))

# v2
await session.send_notification(InitializedNotification())
```

Adapter names: `client_request_adapter`, `server_request_adapter`, `client_notification_adapter`, `server_notification_adapter`, `client_result_adapter`, `server_result_adapter`, `jsonrpc_message_adapter`. All exported from `mcp.types`. Source: [`src/mcp/types/_types.py` L1615-L1778](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L1615-L1778); [`src/mcp/types/jsonrpc.py` L83](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/jsonrpc.py#L83).

## `MCPError` constructor signature changed

```python
# v1
from mcp.shared.exceptions import McpError
from mcp.types import ErrorData, INVALID_REQUEST
raise McpError(ErrorData(code=INVALID_REQUEST, message="bad input"))

try: ...
except McpError as e: print(e.error.message)

# v2
from mcp.shared.exceptions import MCPError  # or `from mcp import MCPError`
from mcp.types import INVALID_REQUEST
raise MCPError(INVALID_REQUEST, "bad input")
# Or, if you have an ErrorData:
raise MCPError.from_error_data(error_data)

try: ...
except MCPError as e: print(e.message)
```

## Lowlevel `Server`: decorator handlers → constructor `on_*` kwargs

The single largest v2 change for low-level server authors. Decorator handler registration is **gone**. All handlers are registered via constructor kwargs; the `Server.request_handlers` / `notification_handlers` dicts are removed. Source: [`src/mcp/server/lowlevel/server.py` L101-L230](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/lowlevel/server.py#L101-L230).

```python
# v1
from mcp.server.lowlevel.server import Server
server = Server("my-server")

@server.list_tools()
async def handle_list_tools():
    return [types.Tool(name="my_tool", description="A tool", inputSchema={})]

@server.call_tool()
async def handle_call_tool(name: str, arguments: dict):
    return [types.TextContent(type="text", text=f"Called {name}")]

# v2
from mcp.server import Server, ServerRequestContext
from mcp.types import (
    CallToolRequestParams, CallToolResult,
    ListToolsResult, PaginatedRequestParams,
    TextContent, Tool,
)

async def handle_list_tools(
    ctx: ServerRequestContext, params: PaginatedRequestParams | None
) -> ListToolsResult:
    return ListToolsResult(tools=[
        Tool(name="my_tool", description="A tool", input_schema={})
    ])

async def handle_call_tool(
    ctx: ServerRequestContext, params: CallToolRequestParams
) -> CallToolResult:
    return CallToolResult(
        content=[TextContent(type="text", text=f"Called {params.name}")],
        is_error=False,
    )

server = Server(
    "my-server",
    on_list_tools=handle_list_tools,
    on_call_tool=handle_call_tool,
)
```

Key shape differences in handlers (see [`src/mcp/server/lowlevel/server.py` L117-L125](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/lowlevel/server.py#L117-L125)):

- Receive `(ctx, params)` — not the full request, not unpacked arguments.
- Return the **full result type** — `ListToolsResult`, `CallToolResult`, `ReadResourceResult` — not bare lists, dicts, strings, or bytes.
- **No automatic JSON Schema validation** on `on_call_tool` inputs — validate yourself.
- **`params.arguments` can be `None`** (use `params.arguments or {}`).

See the lowlevel-server reference for the full handler-name table. Source: [`src/mcp/server/lowlevel/server.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/lowlevel/server.py).

## `streamable_http_client` signature changes

```python
# v1
from mcp.client.streamable_http import streamablehttp_client
async with streamablehttp_client(
    url=url, headers={"Authorization": "Bearer t"}, timeout=30,
    sse_read_timeout=300, auth=my_auth,
) as (read, write, get_session_id):
    ...

# v2
import httpx
from mcp.client.streamable_http import streamable_http_client

http_client = httpx.AsyncClient(
    headers={"Authorization": "Bearer t"},
    timeout=httpx.Timeout(30, read=300),
    auth=my_auth,
    follow_redirects=True,   # v1 set this internally
)
async with http_client:
    async with streamable_http_client(url, http_client=http_client) as (read, write):
        ...
```

Note the **2-tuple** return (v1 was 3). The `get_session_id` callback is gone; capture the session ID via `httpx` `event_hooks` if you need it (read the `mcp-session-id` response header). `StreamableHTTPTransport`'s `headers`, `timeout`, `sse_read_timeout`, `auth` parameters are gone — all configured on the `httpx.AsyncClient`. `sse_client` is **unchanged** — those parameters survive only on the SSE transport. Source: [`src/mcp/client/streamable_http.py` L519-L541](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/streamable_http.py#L519-L541).

## `MCPServer` (formerly `FastMCP`) constructor params

Transport-specific parameters moved off the constructor onto `run()` / `sse_app()` / `streamable_http_app()`. Source: [`src/mcp/server/mcpserver/server.py` L129-L160 `MCPServer.__init__`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/server.py#L129-L160):

```python
# v1
mcp = FastMCP("Demo", json_response=True, stateless_http=True, host="0.0.0.0", port=9000)
mcp.run(transport="streamable-http")

# v2
mcp = MCPServer("Demo")
mcp.run(transport="streamable-http", json_response=True, stateless_http=True, host="0.0.0.0", port=9000)
```

Moved: `host`, `port`, `sse_path`, `message_path`, `streamable_http_path`, `json_response`, `stateless_http`, `event_store`, `retry_interval`, `transport_security`. Removed entirely: `mount_path` (Starlette's `Mount("/path", app=mcp.sse_app())` already handles sub-path mounting via `root_path`). Source: [`src/mcp/server/mcpserver/server.py` L250-L285 `run()` overloads](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/server.py#L250-L285).

Settings mutations after construction (`mcp.settings.port = 9000`) no longer work — pass to `run()` / app methods instead. Source: [`src/mcp/server/mcpserver/server.py` L81-L115 `Settings`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/server.py#L81-L115).

## `MCPServer.get_context()` is gone — use `ctx: Context` parameter injection

```python
# v1
@mcp.tool()
async def my_tool(x: int) -> str:
    ctx = mcp.get_context()
    await ctx.info("Processing...")
    return str(x)

# v2
from mcp.server.mcpserver import Context

@mcp.tool()
async def my_tool(x: int, ctx: Context) -> str:
    await ctx.info("Processing...")
    return str(x)
```

The ambient ContextVar is gone. Context is always passed explicitly. Source: [`src/mcp/server/mcpserver/context.py` L23-L50](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/context.py#L23-L50).

## `Context` logging API changes

```python
# v1
await ctx.info("Connection failed", extra={"host": "localhost", "port": 5432})
await ctx.log(level="info", message="hello")

# v2 — `data: Any`, no `extra`
await ctx.info({"message": "Connection failed", "host": "localhost", "port": 5432})
await ctx.log(level="info", data="hello")
```

`Context.log()` now also accepts all eight RFC-5424 levels (`debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, `emergency`). Source: [`src/mcp/server/mcpserver/context.py` L188-L209](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/context.py#L188-L209).

## Other removed helpers

- **`create_connected_server_and_client_session(server)`** → use `Client(server)` (in-memory transport happens automatically). For raw streams, `create_client_server_memory_streams()` is still in `mcp.shared.memory`.
- **`mcp.shared.progress`** module (`ProgressContext`, `progress()` context manager) — use `ctx.report_progress()` instead.
- **`ProgressContext`** — never adopted; use `Context.report_progress(progress, total)` or `session.send_progress_notification()`.
- **`mcp.shared.context`** module — `RequestContext` split into `ClientRequestContext` (in `mcp.client.context`) and `ServerRequestContext` (in `mcp.server.context`). Type parameters reduced from 3 to 1.
- **`ClientSession.get_server_capabilities()`** → use `session.initialize_result.capabilities` (`initialize_result` is nullable on `ClientSession`, non-nullable on `Client`).
- **`Client.server_capabilities`** → `client.initialize_result.capabilities`.
- **`@server.experimental.list_tasks()`** / **`get_task()`** decorators → custom handlers via `enable_tasks(on_get_task=...)`.

## `ClientSession` list method `cursor=` is gone

```python
# v1
await session.list_resources(cursor="page2")

# v2
from mcp.types import PaginatedRequestParams
await session.list_resources(params=PaginatedRequestParams(cursor="page2"))
```

Same change for `list_resource_templates`, `list_prompts`, `list_tools`. Source: [`src/mcp/client/session.py` L257-L393](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/session.py#L257-L393).

## `ClientSessionGroup.call_tool(args=...)` is gone

Use `arguments=` (the same name `ClientSession.call_tool` uses). Source: [`src/mcp/client/session_group.py` L193-L210](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/session_group.py#L193-L210).

## What stayed (worth confirming)

- The wire format — every change above is Python-side. JSON on the wire is still camelCase, still spec-compliant.
- `sse_client` parameters (`headers`, `timeout`, `sse_read_timeout`, `auth`) — only `streamable_http_client` was reworked.
- Top-level `__all__` symbols on `mcp` — `Client`, `ClientSession`, `Tool`, etc., are still importable from `mcp`.
- `mcp.cli` console script and `mcp dev` / `mcp install` commands.

## Recovery strategy

If you're porting a v1 codebase (see [`docs/migration.md`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/docs/migration.md)):

1. **Pin to v1.x first.** v2 is pre-alpha; for production today, the [`v1.x` branch](https://github.com/modelcontextprotocol/python-sdk/tree/v1.x) is what you want.
2. **Search-replace the renames** (`FastMCP` → `MCPServer`, `McpError` → `MCPError`, `streamablehttp_client` → `streamable_http_client`, `Content` → `ContentBlock`).
3. **Search for `.isError`, `.nextCursor`, `.inputSchema`, `.mimeType` etc.** — replace with snake_case.
4. **Search for `AnyUrl` adjacent to URI fields** — wrap with `str(...)`.
5. **Search for `@server.list_tools()` / `@server.call_tool()` etc. decorators** — convert to constructor `on_*` kwargs with `(ctx, params)` handler signatures.
6. **Search for `cursor=` keyword in `list_*` calls** — convert to `params=PaginatedRequestParams(cursor=...)`.
7. **Test against `Client(server)`** — the canonical end-to-end shape.

The upstream [`docs/migration.md`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/docs/migration.md) is the definitive reference and is updated as v2 develops. Re-check it before a major port.
