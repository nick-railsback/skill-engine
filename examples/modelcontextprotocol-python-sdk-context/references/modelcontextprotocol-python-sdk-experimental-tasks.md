---
name: modelcontextprotocol-python-sdk-experimental-tasks
description: "The experimental tasks feature: async/long-running MCP operations that decouple request-issued from result-returned. Covers task lifecycle states, `enable_tasks()` setup, `ServerTaskContext`, client-side `call_tool_as_task` + `poll_task`, `TaskStore` interface, and the spec-status caveats."
---

# MCP Python SDK — Experimental tasks

Tasks are MCP's mechanism for **async request handling** — operations that don't return their result inline. The receiver creates a task, returns a `CreateTaskResult` immediately with a `task_id`, and the requestor polls for status and eventual result. The feature is **experimental and tracks the draft MCP specification** — APIs may change without notice. The implementation lives at [`src/mcp/server/experimental/`](https://github.com/modelcontextprotocol/python-sdk/tree/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/server/experimental) and [`src/mcp/shared/experimental/tasks/`](https://github.com/modelcontextprotocol/python-sdk/tree/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/shared/experimental/tasks). Authoritative docs: [`docs/experimental/tasks.md`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/docs/experimental/tasks.md), [`tasks-server.md`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/docs/experimental/tasks-server.md), [`tasks-client.md`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/docs/experimental/tasks-client.md).

## When to use tasks

- Operations that take seconds to minutes (data pipelines, multi-step workflows).
- Operations that need user input mid-execution (elicitation, sampling).
- Operations that should not block the requestor's request loop.
- OAuth flows where the user must complete an out-of-band browser interaction.

Tasks are **bidirectional**: client → server (most common, for long-running tool calls) and server → client (less common, for elicitation/sampling that need to wait on user action).

## Task lifecycle

A task moves through five states:

```text
              working
               │
   ┌───────────┼───────────┐
   ▼           ▼           ▼
completed   failed     cancelled
   ▲
   │
input_required ◄─── working
```

| Status | Meaning |
|---|---|
| `working` | Task is being processed. |
| `input_required` | Receiver needs input from requestor (elicitation or sampling). Transitions back to `working` once supplied. |
| `completed` | Task finished successfully — result is available via `tasks/result`. |
| `failed` | Task encountered an error. |
| `cancelled` | Requestor cancelled the task. |

Terminal states (`completed`, `failed`, `cancelled`) are final — tasks cannot transition out of them.

Status literal constants are exported from `mcp.types`: `TASK_STATUS_WORKING`, `TASK_STATUS_INPUT_REQUIRED`, `TASK_STATUS_COMPLETED`, `TASK_STATUS_FAILED`, `TASK_STATUS_CANCELLED`. Tool execution modes: `TASK_FORBIDDEN`, `TASK_OPTIONAL`, `TASK_REQUIRED` (set via `Tool.execution = ToolExecution(task_support=TASK_REQUIRED)`).

## Server: `enable_tasks()`

```python
from mcp.server import Server, ServerRequestContext
from mcp.server.experimental.task_context import ServerTaskContext
from mcp.types import (
    CallToolRequestParams, CallToolResult, CreateTaskResult,
    ListToolsResult, PaginatedRequestParams,
    TextContent, Tool, ToolExecution,
    TASK_REQUIRED,
)

async def handle_list_tools(
    ctx: ServerRequestContext, params: PaginatedRequestParams | None
) -> ListToolsResult:
    return ListToolsResult(tools=[
        Tool(
            name="process_data",
            description="Process data asynchronously",
            input_schema={"type": "object", "properties": {"input": {"type": "string"}}},
            execution=ToolExecution(task_support=TASK_REQUIRED),
        ),
    ])

async def handle_call_tool(
    ctx: ServerRequestContext, params: CallToolRequestParams,
) -> CallToolResult | CreateTaskResult:
    if params.name == "process_data":
        ctx.experimental.validate_task_mode(TASK_REQUIRED)

        async def work(task: ServerTaskContext) -> CallToolResult:
            await task.update_status("Processing...")
            result = (params.arguments or {}).get("input", "").upper()
            return CallToolResult(content=[TextContent(type="text", text=result)])

        return await ctx.experimental.run_task(work)

    return CallToolResult(
        content=[TextContent(type="text", text=f"Unknown tool: {params.name}")],
        is_error=True,
    )

server = Server(
    "my-server",
    on_list_tools=handle_list_tools,
    on_call_tool=handle_call_tool,
)
server.experimental.enable_tasks()  # one-line registration
```

`server.experimental.enable_tasks(store=..., queue=...)` registers task-related handlers (`tasks/get`, `tasks/list`, `tasks/cancel`, `tasks/result`). The default `store` is `InMemoryTaskStore`; pass a custom `TaskStore` for production persistence. Optional `on_get_task`, `on_task_result`, `on_list_tasks`, `on_cancel_task` kwargs override specific handlers.

**v2 change:** the v1 `@server.experimental.list_tasks()` / `@server.experimental.get_task()` decorators are removed. All custom handlers go through `enable_tasks(on_*=...)` constructor-style kwargs.

The notation `params.arguments or {}` is important — `arguments` can be `None` in v2 (the v1 default-to-`{}` magic is gone in the lowlevel server).

`ServerTaskContext.update_status(message)` emits a status notification while the task is in `working`. The eventual return value from your `work(task)` callable becomes the task's result.

## Client: `call_tool_as_task` + `poll_task`

```python
from mcp.client.session import ClientSession
from mcp.types import CallToolResult

async with ClientSession(read, write) as session:
    await session.initialize()

    # Submit the tool call as a task
    result = await session.experimental.call_tool_as_task(
        "process_data",
        {"input": "hello"},
        ttl=60000,                 # ms — how long the task and result are retained
        meta={"trace_id": "abc"},  # optional, attached to all task messages
    )
    task_id = result.task.task_id

    # Poll until terminal
    async for status in session.experimental.poll_task(task_id):
        print(f"{status.status}: {status.status_message or ''}")

    # Retrieve the final result, typed
    final = await session.experimental.get_task_result(task_id, CallToolResult)
    print(final.content[0].text)
```

`poll_task` yields `GetTaskResult` instances until the status becomes terminal. The `CallToolResult` type passed to `get_task_result` lets the SDK validate the result payload — pass the type matching the operation you submitted (e.g., `ElicitResult` for server→client elicitation tasks).

## TaskMetadata

When augmenting a request with task execution, attach `TaskMetadata`:

```python
from mcp.types import TaskMetadata
task = TaskMetadata(ttl=60000)  # TTL in milliseconds
```

The `ttl` is the retention window for the task record and its result after completion. Beyond that, the store may garbage-collect the entry — query before TTL or persist the result yourself.

## TaskStore — pluggable persistence

The default `InMemoryTaskStore` ([`src/mcp/shared/experimental/tasks/in_memory_task_store.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/shared/experimental/tasks/in_memory_task_store.py)) is fine for development and single-process servers. For production with multi-worker deployments or task persistence across restarts, implement the `TaskStore` interface (`get`, `set`, `delete`, `list`, `update_status`). The base class is at [`src/mcp/shared/experimental/tasks/store.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/shared/experimental/tasks/store.py).

The `TaskMessageQueue` (also pluggable; default `InMemoryTaskMessageQueue`) carries status update notifications. Both are passed to `enable_tasks(store=..., queue=...)`.

## Capabilities advertised

The SDK manages capability negotiation automatically when `enable_tasks()` is called:

- **Server**: `tasks.requests.tools.call` — server accepts task-augmented tool calls. Additional flags (`tasks.list`, `tasks.cancel`) added depending on which handlers are registered.
- **Client**: `tasks.requests.sampling.createMessage`, `tasks.requests.elicitation.create` — client accepts task-augmented sampling/elicitation requests.

Both sides must advertise the capability for tasks to work — clients without task support cannot call task-required tools.

## Stability caveats

Tasks are **draft-spec**. Treat the API as unstable until the specification is finalized. Concrete risks:

- Type names (`CreateTaskResult`, `GetTaskPayloadResult`, etc.) may rename.
- The status set may expand (e.g., a `paused` or `timed_out` state).
- The polling protocol may grow long-poll or push variants.
- The `task_support` execution-mode literal set may change.
- `enable_tasks()` may move or restructure as the API stabilizes.

The maintainer warning is in the source: `WARNING: These APIs are experimental and may change without notice.` ([`src/mcp/server/lowlevel/experimental.py`](https://github.com/modelcontextprotocol/python-sdk/blob/f4753440dac8b2b6fa6407808e06c51258b78322/src/mcp/server/lowlevel/experimental.py)). Pin your SDK version and re-test on upgrades.

## What's not in here

- The `MCPServer` (high-level) tasks integration — currently you reach the experimental layer via the lowlevel `Server`. `MCPServer._lowlevel_server.experimental.enable_tasks(...)` is the private path; a public high-level API is not yet exposed.
- Task progress notifications — these go through the standard `Context.report_progress()` / `ServerSession.send_progress_notification()`, independent of the task lifecycle.
