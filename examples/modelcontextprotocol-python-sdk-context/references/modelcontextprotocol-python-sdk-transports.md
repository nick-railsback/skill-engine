# MCP Python SDK — Transports

MCP supports four transports in this SDK. Stdio is the canonical pipe-based transport for local subprocess servers (the Claude Desktop integration uses it). Streamable HTTP is the recommended transport for everything else and is what new servers should target — the [spec section](https://modelcontextprotocol.io/specification/latest/basic/transports) describes the bidirectional HTTP+SSE behavior. SSE (server-sent events as standalone, the older pattern) and websockets are still supported but less commonly used in new code. Source: [`src/mcp/client/stdio.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/stdio.py), [`src/mcp/client/streamable_http.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/streamable_http.py), [`src/mcp/client/sse.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/sse.py), [`src/mcp/client/websocket.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/websocket.py).

## Stdio

**Client:** [`mcp.client.stdio.stdio_client`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/stdio.py#L105)`(server_params)` — spawns the server as a subprocess and streams JSON-RPC over stdin/stdout. [`StdioServerParameters`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/stdio.py#L71) (`BaseModel`) carries the spawn config:

```python
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

server_params = StdioServerParameters(
    command="uv",
    args=["run", "my-mcp-server"],
    env={"API_KEY": "..."},
    cwd=None,             # default: inherit
    encoding="utf-8",     # default
    encoding_error_handler="strict",  # "strict" | "ignore" | "replace"
)

async with stdio_client(server_params) as (read, write):
    async with ClientSession(read, write) as session:
        await session.initialize()
        ...
```

Source: [`src/mcp/client/stdio.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/client/stdio.py). The default-inherited env vars (`PATH`, `APPDATA`, `HOME`, etc.) preserve the parent process's basics; pass `env=...` to override.

**Server:** `mcp.server.stdio.stdio_server()` is the corresponding async context manager. It re-wraps stdin/stdout as UTF-8 text streams to dodge Windows codec footguns. Most users go through `MCPServer.run(transport="stdio")` rather than calling `stdio_server()` directly. Source: [`src/mcp/server/stdio.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/server/stdio.py).

## Streamable HTTP

The recommended HTTP transport. Server returns a Starlette ASGI app you can mount anywhere.

**Server side, single app** (see [`MCPServer.run()`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/server.py#L265)):

```python
mcp = MCPServer("Demo")
mcp.run(transport="streamable-http", stateless_http=True, json_response=True)
```

Transport options on [`run()`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/server.py#L265):

- `host`, `port` — default `127.0.0.1:8000`. DNS-rebinding protection auto-enables on loopback addresses.
- `streamable_http_path` — default `/mcp`. The path the client connects to.
- `stateless_http: bool` — `True` for stateless one-shot calls (no session, no resumability), `False` for stateful sessions.
- `json_response: bool` — `True` returns plain JSON; `False` (default) returns SSE-streamed responses, enabling progress notifications and resumability.
- `event_store: EventStore | None` — pluggable event-replay store for session resumption.
- `retry_interval: int` — SSE retry hint.
- `transport_security: TransportSecuritySettings | None` — DNS rebinding config (see below).

Reference: [`examples/snippets/servers/streamable_config.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/examples/snippets/servers/streamable_config.py).

**Server side, mounted in Starlette** (multiple MCPServers on one process, or alongside other ASGI routes):

```python
import contextlib
from starlette.applications import Starlette
from starlette.routing import Mount

echo_mcp = MCPServer(name="EchoServer")
math_mcp = MCPServer(name="MathServer")

@contextlib.asynccontextmanager
async def lifespan(app):
    async with contextlib.AsyncExitStack() as stack:
        await stack.enter_async_context(echo_mcp.session_manager.run())
        await stack.enter_async_context(math_mcp.session_manager.run())
        yield

app = Starlette(
    routes=[
        Mount("/echo", echo_mcp.streamable_http_app(stateless_http=True, json_response=True)),
        Mount("/math", math_mcp.streamable_http_app(stateless_http=True, json_response=True)),
    ],
    lifespan=lifespan,
)
```

Clients connect to `http://host/echo/mcp` and `http://host/math/mcp`. To strip the `/mcp` suffix, pass `streamable_http_path="/"` to `streamable_http_app(...)`. Reference: [`examples/snippets/servers/streamable_starlette_mount.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/examples/snippets/servers/streamable_starlette_mount.py). For host-based routing patterns, see [`streamable_http_host_mounting.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/examples/snippets/servers/streamable_http_host_mounting.py).

**Client side** (v2 signature — the v1 `streamablehttp_client` is removed):

```python
import httpx
from mcp.client.streamable_http import streamable_http_client

async with streamable_http_client("http://localhost:8000/mcp") as (read, write):
    async with ClientSession(read, write) as session:
        await session.initialize()
```

Or, for headers, auth, custom timeouts, you supply an [`httpx.AsyncClient`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/streamable_http.py#L522) via the `http_client=` parameter:

```python
http_client = httpx.AsyncClient(
    headers={"Authorization": "Bearer token"},
    timeout=httpx.Timeout(30, read=300),
    auth=my_auth,
    follow_redirects=True,        # set explicitly — v1 set this internally
)
async with http_client:
    async with streamable_http_client(url, http_client=http_client) as (read, write):
        ...
```

`streamable_http_client` yields a **2-tuple** `(read, write)` in v2 (down from v1's 3-tuple — the `get_session_id` callback was removed). To capture the session ID, attach an `event_hooks={"response": [...]}` callback to your `httpx.AsyncClient` that reads the `mcp-session-id` response header. The signature lives at [`src/mcp/client/streamable_http.py:519`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/client/streamable_http.py#L519).

```python
captured_session_ids: list[str] = []

async def capture(response):
    sid = response.headers.get("mcp-session-id")
    if sid:
        captured_session_ids.append(sid)

http_client = httpx.AsyncClient(event_hooks={"response": [capture]}, follow_redirects=True)
```

## SSE (server-sent events as standalone)

Older transport; new servers should prefer streamable HTTP. The client signature in [`src/mcp/client/sse.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/client/sse.py) still accepts `headers`, `timeout`, `sse_read_timeout`, `auth` directly (these were NOT moved off — only the streamable HTTP client was changed):

```python
from mcp.client.sse import sse_client

async with sse_client(
    url="http://localhost:8000/sse",
    headers={"Authorization": "Bearer token"},
    timeout=5.0,
    sse_read_timeout=300.0,
    auth=my_auth,
) as (read, write):
    ...
```

Server side: [`MCPServer.run(transport="sse")`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/server.py#L919) or `MCPServer.sse_app()` for mounting. `mount_path` was removed in v2 — use Starlette's `Mount("/path", app=mcp.sse_app())` which sets `root_path` in the ASGI scope and is read automatically by [`SseServerTransport`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/sse.py#L63).

## Websocket

[`mcp.client.websocket`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/websocket.py) and [`mcp.server.websocket`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/websocket.py) provide a websocket transport. Requires the `[ws]` extra (`pip install mcp[ws]`). Used much less commonly than the HTTP transports — it's primarily useful when you have an existing websocket pipeline you want to route MCP through.

## DNS rebinding protection

A `TransportSecurityMiddleware` checks `Host` and `Origin` headers against allowlists. `TransportSecuritySettings` ([`src/mcp/server/transport_security.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/server/transport_security.py)) has three fields:

- `enable_dns_rebinding_protection: bool` (default `True` when configured).
- `allowed_hosts: list[str]` — exact-match allowlist for `Host` header.
- `allowed_origins: list[str]` — exact-match allowlist for `Origin` header.

It auto-enables when `host` is `127.0.0.1`, `localhost`, or `::1` to protect dev servers from DNS-rebinding attacks (see [`streamable_http_app()`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/server.py#L1045) and [`sse_app()`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/server.py#L919)). Pass `transport_security=` to `mcp.run()` / `streamable_http_app()` / `sse_app()` to override. For production with reverse proxies, supply your allowed external hostnames explicitly.

Note: the source includes maintainer TODOs flagging that this middleware is awkward and may be reworked — the API may evolve. Source: [`src/mcp/server/transport_security.py#L12`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/transport_security.py#L12).

## CORS for browser-based clients

Browser MCP clients need CORS. Add Starlette's `CORSMiddleware` around [`streamable_http_app()`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/server/mcpserver/server.py#L1045):

```python
from starlette.middleware import Middleware
from starlette.middleware.cors import CORSMiddleware

cors = Middleware(CORSMiddleware,
    allow_origins=["https://my-frontend.example.com"],
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["mcp-session-id", "content-type"],
    expose_headers=["mcp-session-id"],
)
app = Starlette(routes=[...], middleware=[cors])
```

The [`mcp-session-id`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/client/streamable_http.py#L44) header is the one to expose so JS clients can capture it for follow-up requests. Per the v1 README (still accurate for transport behavior): the session ID is set on the initial response and must be echoed back on subsequent requests in a stateful session.
