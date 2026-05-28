# MCP Python SDK — High-level server (`MCPServer`)

`MCPServer` is the ergonomic, decorator-driven way to build an MCP server. It is the v2 rename of v1's `FastMCP` — the import is `from mcp.server.mcpserver import MCPServer, Context`. Underneath, `MCPServer` wraps the lowlevel `Server` and handles tool/resource/prompt registration, JSON Schema generation from type hints, content marshalling, context injection, and transport boilerplate. The class definition is at [`src/mcp/server/mcpserver/server.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/server.py) (≈1100 lines); the public package exports at [`src/mcp/server/mcpserver/__init__.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/__init__.py) are `MCPServer`, `Context`, `Image`, `Audio`, `Icon`.

## Minimal server

```python
from mcp.server.mcpserver import MCPServer

mcp = MCPServer("Demo")

@mcp.tool()
def add(a: int, b: int) -> int:
    """Add two numbers."""
    return a + b

@mcp.resource("greeting://{name}")
def greeting(name: str) -> str:
    return f"Hello, {name}!"

@mcp.prompt(title="Code Review")
def review_code(code: str) -> str:
    return f"Please review this code:\n\n{code}"

if __name__ == "__main__":
    mcp.run(transport="stdio")
```

That's the entire shape. The decorators read the function's type hints to build the JSON Schema, the docstring becomes the tool/resource description, and the return value is wrapped into the appropriate MCP result type.

Reference: [`examples/snippets/servers/mcpserver_quickstart.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/examples/snippets/servers/mcpserver_quickstart.py).

## Tools

`@mcp.tool()` registers a sync or async function as a tool. Type-hinted parameters become the input schema; the return type drives the output schema and `structured_content` marshalling. Decorator kwargs: `name` (defaults to function name), `title`, `description` (defaults to docstring), `annotations` (a `ToolAnnotations`), `structured_output` (force enable/disable).

Return types the framework understands (marshalled by [`_convert_to_content`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/utilities/func_metadata.py#L499-L530) in `func_metadata.py`):

- **Scalar/string/dict/list of JSON-serializable values** → wrapped into a `TextContent` JSON payload and the `structured_content` field on `CallToolResult`.
- **Pydantic `BaseModel`, `TypedDict`, `@dataclass`, or annotated plain class** → schema is inferred; instance is serialized via Pydantic.
- **`Image`, `Audio`** (from `mcp.server.mcpserver`) → `ImageContent`/`AudioContent` blocks.
- **`list[ContentBlock]`** → returned as-is. This is the escape hatch for mixed media or pre-built blocks.
- **Async generator** → yields progressive content blocks.

Example with structured output (see [`examples/snippets/servers/structured_output.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/examples/snippets/servers/structured_output.py)):

```python
from pydantic import BaseModel, Field
from mcp.server.mcpserver import MCPServer

mcp = MCPServer("Weather")

class WeatherData(BaseModel):
    temperature: float = Field(description="Temperature in Celsius")
    humidity: float
    condition: str

@mcp.tool()
def get_weather(city: str) -> WeatherData:
    return WeatherData(temperature=22.5, humidity=45.0, condition="sunny")
```

See [`examples/snippets/servers/structured_output.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/examples/snippets/servers/structured_output.py) for the full taxonomy. `add_tool()` is the imperative equivalent if you want to register without a decorator.

## Resources

`@mcp.resource(uri)` registers a static or templated resource. URI templates use RFC-6570 syntax — `"file://documents/{name}"` extracts `name` as a positional parameter. Static URIs require zero parameters. Return types: `str`, `bytes`, or `ReadResourceContents` (from `mcp.server.lowlevel.helper_types`). Decorator kwargs: `name`, `description`, `mime_type`, `title`, `icons`.

```python
@mcp.resource("file://documents/{name}")
def read_document(name: str) -> str:
    return f"Content of {name}"

@mcp.resource("config://settings", mime_type="application/json")
def get_settings() -> str:
    return '{"theme": "dark"}'
```

See [`examples/snippets/servers/basic_resource.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/examples/snippets/servers/basic_resource.py).

## Prompts

`@mcp.prompt()` registers a prompt template. Return `str` (single user message), a `list[base.Message]` (rich multi-turn), or yield messages from an async generator. `Message` lives in `mcp.server.mcpserver.prompts.base` along with `UserMessage` / `AssistantMessage` helpers.

```python
from mcp.server.mcpserver.prompts import base

@mcp.prompt(title="Debug Assistant")
def debug_error(error: str) -> list[base.Message]:
    return [
        base.UserMessage("I'm seeing this error:"),
        base.UserMessage(error),
        base.AssistantMessage("I'll help debug that. What have you tried so far?"),
    ]
```

See [`examples/snippets/servers/basic_prompt.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/examples/snippets/servers/basic_prompt.py).

## `Context` injection

If any parameter on a tool/resource/prompt function is annotated `Context`, the framework injects it. `Context` is parameterized by your lifespan-context type: `Context[AppContext]`. **There is no ambient `get_context()`** in v2 — context is always passed explicitly.

[`Context`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/context.py#L23) exposes:

- `ctx.session` — the `ServerSession` (low-level transport access).
- `ctx.request_context.lifespan_context` — the value yielded by your `lifespan` async-context-manager.
- `ctx.request_id`, `ctx.meta` — request metadata (`meta` is a `RequestParamsMeta` TypedDict, not a Pydantic model — use `meta.get("progress_token")`).
- `ctx.info(data)`, `ctx.debug(data)`, `ctx.warning(data)`, `ctx.error(data)`, `ctx.log(level, data)` — log notifications. **`data` is `Any`**, not `str`; the v1 `message=` / `extra=` parameters are gone. Pass a dict for structured logging.
- `ctx.report_progress(progress, total=None)` — progress notifications.
- `ctx.elicit(message, schema)` — interactive form prompts (form mode).
- `ctx.elicit_url(message, url, elicitation_id)` — out-of-band confirmations (URL mode).
- `ctx.session.create_message(messages, max_tokens, ...)` — LLM sampling via the connected client.
- `ctx.client_id` — **gotcha**: this reads `client_id` from the MCP request's `_meta` params, not from the OAuth bearer token. For OAuth-authenticated identity, import `get_access_token` from [`mcp.server.auth.middleware.auth_context`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/auth/middleware/auth_context.py) and use `get_access_token().client_id` (or `.subject`, `.scopes`, `.claims`) instead. See the [auth](modelcontextprotocol-python-sdk-auth.md) reference.

## Lifespan (typed startup/shutdown)

Pass an async context manager to `lifespan=` to manage startup/shutdown state with type-safe access in tools:

```python
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from mcp.server.mcpserver import Context, MCPServer

@dataclass
class AppContext:
    db: Database

@asynccontextmanager
async def app_lifespan(server: MCPServer) -> AsyncIterator[AppContext]:
    db = await Database.connect()
    try:
        yield AppContext(db=db)
    finally:
        await db.disconnect()

mcp = MCPServer("My App", lifespan=app_lifespan)

@mcp.tool()
def query_db(ctx: Context[AppContext]) -> str:
    return ctx.request_context.lifespan_context.db.query()
```

Full pattern: [`examples/snippets/servers/lifespan_example.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/examples/snippets/servers/lifespan_example.py).

## Elicitation and sampling

Elicitation is the server asking the user for input mid-request. Form mode uses a Pydantic schema for structured input; URL mode delegates to an external page (OAuth, payments). The `UrlElicitationRequiredError` raise pattern is for tools that cannot proceed without authorization — the framework converts it to a `-32042` JSON-RPC error. See [`examples/snippets/servers/elicitation.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/examples/snippets/servers/elicitation.py).

Sampling is the server requesting LLM completions from the connected client. `ctx.session.create_message(messages, max_tokens)` returns a `CreateMessageResult`; with no tools passed, `result.content` is a single content block. See [`examples/snippets/servers/sampling.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/examples/snippets/servers/sampling.py).

## Running the server

`mcp.run(transport=...)` is the simplest entry point. Transports accepted: `"stdio"` (default; pipes), `"sse"` (legacy server-sent events), `"streamable-http"` (recommended HTTP transport per [MCP spec](https://modelcontextprotocol.io/specification/latest/basic/transports)).

**v2 change:** transport-specific parameters (`host`, `port`, `sse_path`, `streamable_http_path`, `json_response`, `stateless_http`, `event_store`, `retry_interval`, `transport_security`) **moved off the constructor** onto [`run()`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/server.py#L249-L307) / `sse_app()` / `streamable_http_app()`. The constructor now only handles identity and auth:

```python
# Correct (v2)
mcp = MCPServer("Demo")
mcp.run(transport="streamable-http", json_response=True, stateless_http=True)

# Wrong — these kwargs no longer exist on the constructor
# mcp = MCPServer("Demo", json_response=True)
```

DNS-rebinding protection auto-enables when `host` is `127.0.0.1`, `localhost`, or `::1` (set in `sse_app()` / `streamable_http_app()`, not the constructor). Source: [`src/mcp/server/mcpserver/server.py#L928-L935`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/server.py#L928-L935).

## Mounting in an ASGI app

For mounting under a custom path or alongside other ASGI routes, call [`mcp.streamable_http_app(...)`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/server.py#L1045-L1070) or `mcp.sse_app(...)` and mount the returned `Starlette` app:

```python
from starlette.applications import Starlette
from starlette.routing import Mount

mcp = MCPServer("App")
app = Starlette(routes=[
    Mount("/api", app=mcp.streamable_http_app(json_response=True)),
])
```

Patterns for multi-server hosts, host-based routing, and path config: [`examples/snippets/servers/streamable_http_*`](https://github.com/modelcontextprotocol/python-sdk/tree/3eb579948a4719d606d2adbd1f3f69371c9c0f48/examples/snippets/servers).

## Reaching the lowlevel

`MCPServer._lowlevel_server` (marked private; subject to change) gives access to the underlying `Server`. The current escape hatch for handlers `MCPServer` doesn't expose (`subscribe_resource`, `unsubscribe_resource`, `set_logging_level`):

```python
mcp._lowlevel_server._add_request_handler("logging/setLevel", handle_set_logging_level)
mcp._lowlevel_server._add_request_handler("resources/subscribe", handle_subscribe)
```

A public registration API is planned. Until then, either use this pattern or build directly on `Server` — see the lowlevel-server reference. Source: [`src/mcp/server/mcpserver/server.py#L170`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/server.py#L170).
