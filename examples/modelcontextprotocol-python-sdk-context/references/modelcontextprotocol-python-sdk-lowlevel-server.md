# MCP Python SDK — Lowlevel `Server`

The lowlevel [`Server`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/lowlevel/server.py#L101-L115) class is the minimal-magic alternative to `MCPServer`. Use it when you need direct protocol control — every request and notification handler registered explicitly, no automatic content marshalling, no JSON Schema inference from type hints, and full access to typed `params` and `ctx`. In v2 it is intentionally bare: it provides no convenience layer, and the migration guide is blunt — "If you want these conveniences, use `MCPServer` (previously `FastMCP`) instead."

Import paths ([`src/mcp/server/__init__.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/__init__.py#L1-L6), [`src/mcp/server/lowlevel/__init__.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/lowlevel/__init__.py)):

```python
from mcp.server import Server, ServerRequestContext
# or
from mcp.server.lowlevel import Server
```

Source: [`src/mcp/server/lowlevel/server.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/server/lowlevel/server.py).

## What changed in v2

The breaking changes versus v1 are extensive and they are the reason this reference exists. If you're carrying v1 muscle memory:

- **Decorators are gone.** `@server.list_tools()`, `@server.call_tool()`, etc., were removed. Handler registration is **constructor-only** via `on_*` keyword arguments.
- **Handlers receive `(ctx, params)`** instead of unpacked arguments or the raw request. `ctx: ServerRequestContext` carries `session`, `lifespan_context`, `experimental`, `request_id`, `meta`. `params` is the typed Pydantic params object — never the wrapper request.
- **No automatic return-value wrapping.** Handlers return the full result type (`CallToolResult`, `ListToolsResult`, `ReadResourceResult`) — not bare lists, not dicts, not strings/bytes. The old `call_tool` decorator's auto-wrapping of dicts into `structured_content` and strings into `TextResourceContents` is gone.
- **No `jsonschema` validation** on `on_call_tool` inputs. The old decorator validated `params.arguments` against the registered tool's input schema; v2 does not. Validate yourself if you need it.
- **`request_handlers` and `notification_handlers` dicts are gone.** No public introspection — track registered handlers yourself.
- **`request_context` property removed.** `ctx` is passed directly to handlers; the `request_ctx` module-level contextvar is also gone.
- **Constructor parameters after `name` are keyword-only.** `Server("my-server", version="1.0")`, not `Server("my-server", "1.0")`.
- **`Server` type parameters reduced from 2 → 1.** `Server[LifespanResultT]` (RequestT removed).
- **`params.arguments` can be `None`** in `on_call_tool`. The old decorator defaulted it to `{}`; v2 doesn't. Use `params.arguments or {}` to preserve old behavior.

## Constructing a server

```python
from mcp.server import Server, ServerRequestContext
from mcp.types import (
    CallToolRequestParams,
    CallToolResult,
    ListToolsResult,
    PaginatedRequestParams,
    TextContent,
    Tool,
)

async def handle_list_tools(
    ctx: ServerRequestContext,
    params: PaginatedRequestParams | None,
) -> ListToolsResult:
    return ListToolsResult(
        tools=[Tool(name="echo", description="Echo input", input_schema={"type": "object"})]
    )

async def handle_call_tool(
    ctx: ServerRequestContext,
    params: CallToolRequestParams,
) -> CallToolResult:
    args = params.arguments or {}
    return CallToolResult(
        content=[TextContent(type="text", text=f"Called {params.name} with {args}")],
        is_error=False,
    )

server = Server(
    "my-server",
    version="1.0",
    on_list_tools=handle_list_tools,
    on_call_tool=handle_call_tool,
)
```

## Full handler reference

All handlers receive `ctx: ServerRequestContext` as their first argument. The second is the typed params (`None`-allowed where the spec permits no params). Return types are the full result objects from `mcp.types`. The constructor kwarg name in the right-hand column is what you pass to `Server(...)`. ([`src/mcp/server/lowlevel/server.py#L117-L186`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/lowlevel/server.py#L117-L186))

| Operation | Constructor kwarg | `params` type | Return type |
|---|---|---|---|
| List tools | `on_list_tools` | `PaginatedRequestParams \| None` | `ListToolsResult` |
| Call tool | `on_call_tool` | `CallToolRequestParams` | `CallToolResult \| CreateTaskResult` |
| List resources | `on_list_resources` | `PaginatedRequestParams \| None` | `ListResourcesResult` |
| List resource templates | `on_list_resource_templates` | `PaginatedRequestParams \| None` | `ListResourceTemplatesResult` |
| Read resource | `on_read_resource` | `ReadResourceRequestParams` | `ReadResourceResult` |
| Subscribe resource | `on_subscribe_resource` | `SubscribeRequestParams` | `EmptyResult` |
| Unsubscribe resource | `on_unsubscribe_resource` | `UnsubscribeRequestParams` | `EmptyResult` |
| List prompts | `on_list_prompts` | `PaginatedRequestParams \| None` | `ListPromptsResult` |
| Get prompt | `on_get_prompt` | `GetPromptRequestParams` | `GetPromptResult` |
| Completion | `on_completion` | `CompleteRequestParams` | `CompleteResult` |
| Set logging level | `on_set_logging_level` | `SetLevelRequestParams` | `EmptyResult` |
| Ping | `on_ping` | `RequestParams \| None` | `EmptyResult` |
| Progress notification | `on_progress` | `ProgressNotificationParams` | `None` |
| Roots list-changed | `on_roots_list_changed` | `NotificationParams \| None` | `None` |

Notification handlers (`on_progress`, `on_roots_list_changed`) return `None`. Request handlers return their result type — never `list[Tool]` or `dict`. Capabilities are inferred from which handlers you provide; for example, supplying `on_subscribe_resource` correctly advertises `resources.subscribe: true` in the initialize result (a v1 bug where this was hardcoded `false` is fixed). ([`src/mcp/server/lowlevel/server.py#L283-L328`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/lowlevel/server.py#L283-L328))

## Returning results — no automatic wrapping

In v1, returning a `dict` from a `@server.call_tool()` handler auto-wrapped into `structured_content` + a JSON `TextContent`. In v2, you build the result ([`src/mcp/server/lowlevel/server.py#L122-L126`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/lowlevel/server.py#L122-L126)):

```python
import json

async def handle_call_tool(
    ctx: ServerRequestContext, params: CallToolRequestParams
) -> CallToolResult:
    data = {"temperature": 22.5, "city": "London"}
    return CallToolResult(
        content=[TextContent(type="text", text=json.dumps(data, indent=2))],
        structured_content=data,
    )
```

For `on_read_resource`, you build [`TextResourceContents`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L738-L745) or [`BlobResourceContents`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L748-L752) directly. Binary content must be base64-encoded by you:

```python
import base64
from mcp.types import BlobResourceContents, ReadResourceResult, ReadResourceRequestParams

async def handle_read(
    ctx: ServerRequestContext, params: ReadResourceRequestParams,
) -> ReadResourceResult:
    return ReadResourceResult(
        contents=[BlobResourceContents(
            uri=str(params.uri),
            blob=base64.b64encode(b"\x89PNG...").decode("utf-8"),
            mime_type="image/png",
        )]
    )
```

The deprecated `str`/`bytes` shorthand return types for `read_resource` are removed. ([`src/mcp/server/lowlevel/server.py#L137-L141`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/lowlevel/server.py#L137-L141))

## Streamable HTTP from the lowlevel

A v2 new feature: [`streamable_http_app()`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/lowlevel/server.py#L562-L578) is exposed directly on `Server`, not just on `MCPServer`. This lets you run the lowlevel server over Streamable HTTP without the `MCPServer` wrapper:

```python
server = Server("my-server", on_list_tools=handle_list_tools)
app = server.streamable_http_app(
    streamable_http_path="/mcp",
    json_response=False,
    stateless_http=False,
)
```

[`server.session_manager`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/lowlevel/server.py#L345-L357) (a `StreamableHTTPSessionManager`) is accessible after `streamable_http_app()` is called.

## `ServerRequestContext`

[`ctx: ServerRequestContext`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/context.py#L17-L23) (from `mcp.server.context` or re-exported as `mcp.server.ServerRequestContext`) carries:

- `ctx.session` — `ServerSession` for sending notifications, log messages, progress updates.
- `ctx.lifespan_context` — the value yielded by your lifespan async-context-manager.
- `ctx.experimental` — `ExperimentalHandlers` (currently only `enable_tasks()`).
- `ctx.request_id`, `ctx.meta` — request-scoped data (`None` in notification handlers).

`ctx.meta` is now a [`RequestParamsMeta`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L48) TypedDict, not a Pydantic model. Read fields via dict access:

```python
if ctx.meta and "progress_token" in ctx.meta:
    await ctx.session.send_progress_notification(ctx.meta["progress_token"], 0.5, 100)
```

## When to use `Server` instead of `MCPServer`

- You need a handler `MCPServer` doesn't expose (`set_logging_level`, `subscribe_resource`, `unsubscribe_resource`) and you don't want to reach into `mcp._lowlevel_server` via the private workaround.
- You want strict-typing of every request: typed params in, typed result out, no inference.
- You want to skip the JSON Schema generation overhead of `MCPServer` for hot paths.
- You want zero magic — auto-wrapping, decorator metadata, ambient contextvars are all surface area for confusion. `Server` has none of it.

Most servers should still use [`MCPServer`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/server.py#L129). The lowlevel is the precise tool, not the default.
