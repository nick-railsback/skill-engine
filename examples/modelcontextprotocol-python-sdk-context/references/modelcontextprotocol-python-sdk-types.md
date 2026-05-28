---
name: modelcontextprotocol-python-sdk-types
description: "`mcp.types` — protocol type models. Covers snake_case Pydantic fields with camelCase wire aliases, the `_adapter` TypeAdapter instances that replaced `RootModel` union types, `ContentBlock` and its variants, the v2 `str`-vs-`AnyUrl` URI shift, jsonrpc-2.0 surface, error code constants, and the `_meta` extension field."
---

# MCP Python SDK — `mcp.types`

Every MCP protocol message is a Pydantic model in `mcp.types`. The module is the wire-format truth: every request, response, notification, content block, capability, and error code is here. It's also where the largest cluster of v2 breaking changes landed — the surface looks deceptively similar to v1 but the field-access patterns differ.

Public surface: [`src/mcp/types/__init__.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/types/__init__.py) re-exports everything from [`src/mcp/types/_types.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/types/_types.py). The protocol-version constants `LATEST_PROTOCOL_VERSION = "2025-11-25"` and `DEFAULT_NEGOTIATED_VERSION = "2025-03-26"` live at the top of `_types.py`; check the [latest schema JSON](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-11-25/schema.json) for the authoritative wire spec.

## snake_case attribute access, camelCase on the wire

All Pydantic models in `mcp.types` use **snake_case attribute names** in Python while serializing/deserializing as **camelCase** on the JSON-RPC wire (the spec is camelCase). The bridge is Pydantic's `populate_by_name=True` plus alias generation:

```python
result = await session.call_tool("my_tool", {"x": 1})
result.is_error           # v2 — snake_case
# result.isError          # v1 — gone

tools = await session.list_tools()
tools.next_cursor         # v2
# tools.nextCursor        # v1 — gone
tools.tools[0].input_schema  # v2 (was inputSchema)
```

[`populate_by_name=True`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L42) means old camelCase **constructor kwargs** still work — `Tool(inputSchema={...})` is accepted — but attribute reads must use snake_case. The full rename table is in the migration reference; the common renames:

| v1 | v2 |
|---|---|
| `inputSchema`, `outputSchema` | `input_schema`, `output_schema` |
| `isError` | `is_error` |
| `nextCursor` | `next_cursor` |
| `mimeType` | `mime_type` |
| `structuredContent` | `structured_content` |
| `serverInfo` | `server_info` |
| `protocolVersion` | `protocol_version` |
| `uriTemplate` | `uri_template` |
| `listChanged` | `list_changed` |
| `progressToken` | `progress_token` |

## Union types: `_adapter` instead of `RootModel`

Seven union types were previously `RootModel` subclasses and could be validated via `ModelClass.model_validate(data)` then `.root` to unwrap. In v2 they are plain `Union` types validated through [`TypeAdapter` instances](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L1615-L1778):

```python
from mcp.types import (
    client_request_adapter,
    server_request_adapter,
    client_notification_adapter,
    server_notification_adapter,
    client_result_adapter,
    server_result_adapter,
    jsonrpc_message_adapter,
)

# v1 — gone
# request = ClientRequest.model_validate(data)
# inner = request.root

# v2
request = client_request_adapter.validate_python(data)
# request IS the actual variant — no .root access needed
```

When constructing — sending a notification, calling `send_request` — the wrapping is also gone (see [`client_notification_adapter`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L1625)):

```python
# v1 — gone
# await session.send_notification(ClientNotification(InitializedNotification()))
# await session.send_request(ClientRequest(PingRequest()), EmptyResult)

# v2
await session.send_notification(InitializedNotification())
await session.send_request(PingRequest(), EmptyResult)
```

The adapter instances are defined late in [`_types.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/types/_types.py) (lines 1615+).

## `ContentBlock` taxonomy

Tool results, prompt messages, and resource read results all carry `ContentBlock` lists. The variants:

- **`TextContent`** — `type="text"`, `text: str`.
- **`ImageContent`** — `type="image"`, `data: str` (base64), `mime_type: str`.
- **`AudioContent`** — `type="audio"`, `data: str` (base64), `mime_type: str`.
- **`EmbeddedResource`** — `type="resource"`, `resource: TextResourceContents | BlobResourceContents`.
- **`ResourceLink`** — `type="resource_link"`, pointing at a `Resource`.
- **`ToolUseContent`**, **`ToolResultContent`** — sampling-side tool blocks.
- **`SamplingMessageContentBlock`** — a separate, narrower union used in `SamplingMessage`.

`Content` was a v1 alias and is removed in v2 — use [`ContentBlock`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L1054).

Type-narrowing pattern (see [`TextContent`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L883)):

```python
from mcp.types import TextContent

content = result.content[0]
if isinstance(content, TextContent):
    print(content.text)
```

## Resource URIs are now `str`

In v1, resource URI fields used Pydantic's `AnyUrl`, which validates the value matches a URL grammar and rejects relative paths like `users/me`. The MCP spec defines URIs as plain strings (any well-formed URI reference), so v2 changed (see [`Resource.uri`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L632-L665)):

- `Resource.uri`, `ReadResourceRequestParams.uri`, `ResourceContents.uri`, `TextResourceContents.uri`, `BlobResourceContents.uri`, `SubscribeRequestParams.uri`, `UnsubscribeRequestParams.uri`, `ResourceUpdatedNotificationParams.uri` — all now `str`.
- `ClientSession.read_resource(uri)`, `.subscribe_resource(uri)`, `.unsubscribe_resource(uri)` — accept `str` only.

If you have an `AnyUrl` instance from elsewhere, convert with `str(my_url)`. Source: [`src/mcp/types/_types.py#L707-L810`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L707-L810).

## Removed type aliases

| Removed | Use instead |
|---|---|
| `Content` | `ContentBlock` |
| `ResourceReference` | `ResourceTemplateReference` |
| `Cursor` | plain `str` |
| `McpError` | `MCPError` (from `mcp.shared.exceptions` or `mcp`) |
| `MethodT`, `RequestParamsT`, `NotificationParamsT` | internal TypeVars — were never public |

## `_meta` is the only extension field

MCP protocol types no longer accept arbitrary extra fields at the top level. This matches the spec: extra fields are allowed only inside [`_meta`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L48-L79). Attempting top-level extras raises a Pydantic ValidationError now:

```python
# Fails in v2
params = CallToolRequestParams(name="my_tool", arguments={}, custom_field="x")

# OK — extra goes in _meta
params = CallToolRequestParams(name="my_tool", arguments={}, _meta={"custom_field": "x"})
```

`RequestParamsMeta` is a TypedDict (not a Pydantic model) — read fields via `meta.get("progress_token")` or `"progress_token" in meta`, not `meta.progress_token`. The wire field is camelCase (`_meta.progressToken`); the TypedDict key is snake_case (`progress_token`).

## JSON-RPC layer

[`src/mcp/types/jsonrpc.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/types/jsonrpc.py) holds the JSON-RPC 2.0 wrappers: `JSONRPCRequest`, `JSONRPCResponse`, `JSONRPCError`, `JSONRPCNotification`, `JSONRPCMessage` (union), `RequestId`. The `jsonrpc_message_adapter` is the right TypeAdapter for arbitrary incoming messages.

## Error codes

JSON-RPC 2.0 error code constants are top-level in `mcp.types`:

- `PARSE_ERROR = -32700`
- `INVALID_REQUEST = -32600`
- `METHOD_NOT_FOUND = -32601`
- `INVALID_PARAMS = -32602`
- `INTERNAL_ERROR = -32603`
- `URL_ELICITATION_REQUIRED = -32042` (MCP-specific)

[`ErrorData`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/jsonrpc.py#L55) is the wire shape; [`MCPError`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/shared/exceptions.py#L8-L13) is the Python exception that wraps it (constructor `MCPError(code, message, data=None)`).

## Tasks (experimental — see experimental-tasks reference)

The task-related type names ([`CreateTaskResult`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py#L459), `GetTaskResult`, `CancelTaskRequest`, `TaskExecutionMode`, `TASK_STATUS_*` literals, `TASK_FORBIDDEN`/`OPTIONAL`/`REQUIRED` literals) are exported from `mcp.types` even though the implementation is in `mcp.server.experimental`. They track the draft spec — names and shapes can change without notice.

## `_types.py` is huge — when to read it

The full [`_types.py`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/_types.py) is ≈1778 lines. Read it when:

- You need to know whether a model has a field you can't find via autocomplete (Pydantic 2 has strict field listings).
- You're debugging a Pydantic ValidationError and want to see the exact field constraints.
- You need to construct a less-common type (`Annotations`, `Implementation`, `Icon` with theme, `BaseMetadata`).

For everything else, the public [`__init__.py` `__all__`](https://github.com/modelcontextprotocol/python-sdk/blob/3eb579948a4719d606d2adbd1f3f69371c9c0f48/src/mcp/types/__init__.py#L207) list is the safe surface to import from.
