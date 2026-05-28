# MCP Python SDK — Client

The SDK ships three client-side abstractions, ordered from highest- to lowest-level. Source: [`src/mcp/client/client.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/client.py#L37), [`src/mcp/client/session.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/session.py#L101), [`src/mcp/client/session_group.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/session_group.py#L85):

1. **`Client`** (`mcp.client.Client`, also `from mcp import Client`) — a dataclass that owns transport setup and exposes the same protocol methods as `ClientSession`. Accepts a `Server`/`MCPServer` instance (in-memory), a URL string (streamable HTTP), or a custom `Transport`. The canonical end-to-end test shape.
2. **`ClientSession`** (`mcp.ClientSession`) — wraps a `(read_stream, write_stream)` pair. Used inside `stdio_client(...)`, `streamable_http_client(...)`, `sse_client(...)` context managers when you need raw stream control or you're already in a transport-specific code path.
3. **`ClientSessionGroup`** (`mcp.ClientSessionGroup`) — manages multiple concurrent sessions across servers, aggregating tools/resources/prompts and handling name-collision resolution via a user-provided hook.

Sources: [`src/mcp/client/`](https://github.com/modelcontextprotocol/python-sdk/tree/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/client), public surface in [`src/mcp/client/__init__.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/client/__init__.py).

## `Client` — the recommended entry point

```python
from mcp.client import Client
from mcp.server.mcpserver import MCPServer

server = MCPServer("test")

@server.tool()
def add(a: int, b: int) -> int:
    return a + b

async def main():
    async with Client(server) as client:
        result = await client.call_tool("add", {"a": 1, "b": 2})
        print(result.structured_content)  # {"result": 3}
```

[`Client(server)`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/client.py#L62-L66) accepts:

- A `Server` or `MCPServer` instance → wrapped in `InMemoryTransport`. No network, no subprocess. The canonical shape for tests.
- A URL `str` → `streamable_http_client(url)` is used.
- A `Transport` instance → used directly.

Constructor kwargs (all keyword-only after `server`) — see [`src/mcp/client/client.py` L73-L95](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/client.py#L73-L95):

- `raise_exceptions: bool = False` — surface server-side errors as Python exceptions instead of `is_error=True` results.
- `read_timeout_seconds: float | None`.
- `sampling_callback`, `elicitation_callback`, `list_roots_callback`, `logging_callback`, `message_handler` — see "Callbacks" below.
- `client_info: Implementation | None` — `(name, version)` advertised in initialize.

**Migration note:** in v1, the in-memory test helper was `create_connected_server_and_client_session(server)`. That helper was removed in v2 — [`Client(server)`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/client.py#L37) is the replacement. If you need raw streams for transport-level testing, [`mcp.shared.memory.create_client_server_memory_streams()`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/shared/memory.py#L15) is still available.

`Client.initialize_result` is non-nullable inside the `async with` block — initialization is guaranteed, so no `None` check is needed. Use `client.initialize_result.capabilities`, `.server_info`, `.instructions`, `.protocol_version`.

## `ClientSession` — when you have your own streams

`ClientSession(read_stream, write_stream)` wraps a stream pair from any of the transport context managers. The class is at [`src/mcp/client/session.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/client/session.py). The full method surface (all `async`):

- `initialize() -> InitializeResult`
- `send_ping(meta=None) -> EmptyResult`
- `send_progress_notification(progress_token, progress, total=None, message=None)`
- `set_logging_level(level: LoggingLevel) -> EmptyResult`
- `list_resources(params: PaginatedRequestParams | None = None) -> ListResourcesResult`
- `list_resource_templates(...) -> ListResourceTemplatesResult`
- `read_resource(uri: str, meta=None) -> ReadResourceResult`
- `subscribe_resource(uri: str, meta=None) -> EmptyResult`
- `unsubscribe_resource(uri: str, meta=None) -> EmptyResult`
- `list_prompts(params=None) -> ListPromptsResult`
- `get_prompt(name: str, arguments=None, meta=None) -> GetPromptResult`
- `complete(ref: PromptReference | ResourceTemplateReference, argument, meta=None) -> CompleteResult`
- `list_tools(params=None) -> ListToolsResult`
- `call_tool(name: str, arguments: dict | None = None, ...) -> CallToolResult`
- `send_roots_list_changed()`

After `initialize()`, [`session.initialize_result`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/session.py#L195-L200) holds the full `InitializeResult` (this property replaces v1's `session.get_server_capabilities()`). It's nullable on `ClientSession` because you can theoretically use the session without calling `initialize()` first — though in practice you always should.

```python
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

async with streamable_http_client("http://localhost:8000/mcp") as (read, write):
    async with ClientSession(read, write) as session:
        await session.initialize()
        tools = await session.list_tools()
```

Reference: [`examples/snippets/clients/streamable_basic.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/examples/snippets/clients/streamable_basic.py), [`examples/snippets/clients/stdio_client.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/examples/snippets/clients/stdio_client.py).

## Pagination

`list_tools`, `list_resources`, `list_resource_templates`, `list_prompts` all paginate. **v2 removed the bare `cursor=` keyword argument** — pass a `PaginatedRequestParams` instance:

```python
from mcp.types import PaginatedRequestParams

cursor = None
all_resources = []
while True:
    result = await session.list_resources(params=PaginatedRequestParams(cursor=cursor))
    all_resources.extend(result.resources)
    if result.next_cursor:           # snake_case in v2, not nextCursor
        cursor = result.next_cursor
    else:
        break
```

Note `result.next_cursor` (snake_case) — all Pydantic field names are snake_case in v2, regardless of the JSON wire form (which is still camelCase via Pydantic aliases). Pattern: [`examples/snippets/clients/pagination_client.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/examples/snippets/clients/pagination_client.py).

## Calling tools and reading results

`call_tool` returns a `CallToolResult` with three fields you care about: `content` (a `list[ContentBlock]` — text, image, audio, resource), `is_error: bool` (snake_case in v2, not `isError`), and `structured_content` (the JSON-equivalent of the tool's typed return value, when available).

```python
result = await session.call_tool("add", arguments={"a": 5, "b": 3})

# Type-narrow the first content block before reading text
from mcp.types import TextContent
content = result.content[0]
if isinstance(content, TextContent):
    print(content.text)

# Structured output (snake_case)
print(result.structured_content)  # {"result": 8}

# Error handling
if result.is_error:
    ...
```

If you'd rather let the server's `-32xxx` error bubble up as a Python exception, set `Client(server, raise_exceptions=True)`. The exception type is `MCPError` (renamed from v1's `McpError`); see the types reference.

## `ClientSessionGroup` — fan-out across servers

For multi-server scenarios (a single agent connected to several MCP servers concurrently), `ClientSessionGroup` lets you connect/disconnect dynamically and aggregates tools/resources/prompts across all connected sessions. It accepts servers as `StdioServerParameters`, `SseServerParameters`, or `StreamableHttpParameters` (`BaseModel`s defined in [`src/mcp/client/session_group.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/client/session_group.py)).

`call_tool` here takes `arguments` (not `args` — that v1 alias is gone). Provide a `ComponentNameHook` callable in the constructor if you need to namespace conflicting tool names across servers.

## Callbacks

Four callback-shaped extension points are passed to `Client(...)` or [`ClientSession(...)`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/session.py#L115-L131) — see also the default stubs at L63-L96:

- **`sampling_callback: SamplingFnT`** — server requested `sampling/createMessage`. Your callback receives `(ctx: ClientRequestContext, params: CreateMessageRequestParams)` and must return `CreateMessageResult`. Typically wired to an actual LLM call on your end.
- **`elicitation_callback: ElicitationFnT`** — server requested user input via `elicitation/create`. Receives `(ctx, params)`; return `ElicitResult` or `ElicitURLResult`.
- **`list_roots_callback: ListRootsFnT`** — server asked for the client's roots (filesystem-like). Receives `(ctx,)`; return `ListRootsResult`.
- **`logging_callback: LoggingFnT`** — server emitted a `notifications/message`. Receives `(params: LoggingMessageNotificationParams)`. **`params.data` is `Any`**, not a string — the v1 `message`/`extra` pair is unified into `data`.

Stdio client with sampling callback: see the example above ([`examples/snippets/clients/stdio_client.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/examples/snippets/clients/stdio_client.py)).

## Reading resources

`read_resource(uri)` accepts a plain `str` URI in v2 — Pydantic's `AnyUrl` wrapping is gone. Relative paths like `"users/me"` and custom schemes like `"custom://scheme"` both work. Returns a `ReadResourceResult` whose `contents` list holds `TextResourceContents` or `BlobResourceContents` blocks; check the concrete type with `isinstance`.

## Connection errors

[`MCPError`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/shared/exceptions.py#L8-L42) (from `mcp` or `mcp.shared.exceptions`) is the unified protocol error class. v2 simplified the constructor: `MCPError(code, message, data=None)` instead of v1's `McpError(ErrorData(code=..., message=...))`. Use `MCPError.from_error_data(error_data)` when you already have an `ErrorData` instance.

```python
from mcp import MCPError
from mcp.types import INVALID_REQUEST

try:
    result = await session.call_tool("my_tool")
except MCPError as e:
    print(f"Error: {e.message}")  # e.message, not e.error.message
```
