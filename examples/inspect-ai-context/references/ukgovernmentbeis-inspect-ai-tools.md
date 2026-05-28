# Tools

A tool is a Python async function exposed to the model via the `@tool` decorator. Inspect handles JSON-schema generation from the function signature and docstring, dispatches tool calls the model emits, returns results, and orchestrates multi-turn tool loops.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools.qmd#L1-L43

```python
from inspect_ai.tool import tool, ToolError
from inspect_ai.util import sandbox

@tool
def list_files():
    async def execute(dir: str):
        """List the files in a directory.

        Args:
            dir: Directory
        """
        result = await sandbox().exec(["ls", dir])
        if result.success:
            return result.stdout
        raise ToolError(result.stderr)
    return execute
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-custom.qmd#L71-L93

The factory pattern (`tool` returns the inner `execute`) is the convention — it lets you parameterize the tool at registration time while the model only sees the inner function's parameters.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/tool/_tool.py#L163-L201

Register tools on a solver state with `use_tools(...)` and let `generate()` consume them:

```python
solver=[
    use_tools([list_files(), bash()]),
    generate(),     # one-shot; model may call tools then return final text
]
```

For an agentic loop where the model keeps calling tools until satisfied, use the agent path (`ukgovernmentbeis-inspect-ai-agents.md`) — or `generate()` is invoked iteratively inside the agent's own scaffold.

## Standard tools

Imported from `inspect_ai.tool`. Computing tools:

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/tool/__init__.py#L47-L65

- `web_search()` — uses a search provider (built into the model when available, else external — Tavily / Exa / Google PSE). Returns summarized results.
- `bash()` / `python()` — execute shell or Python inside the current sandbox.
- `bash_session()` — stateful bash that retains shell state across calls.
- `text_editor()` — view, create, edit text files (Anthropic-style `str_replace`, `create`, `view`, `insert`).
- `computer()` — desktop "computer use" via screenshots and mouse/keyboard.
- `code_execution()` — sandboxed Python execution running in the model provider's infra (provider-side, no local sandbox needed).
- `web_browser()` — headless Chromium with navigation/history/click/type.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-standard.qmd#L11-L20

Agentic tools:

- `skill()` — surface a "skill spec" with specialized knowledge for a task.
- `update_plan()` — let the model maintain a step/progress list.
- `memory()` — persistent memory file directory.
- `think()` — explicit thinking step before final answer.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/tool/__init__.py#L57-L63

Most standard tools require a sandbox (`bash`, `python`, `text_editor`, `web_browser`, etc.). Some are provider-side (`code_execution`, `web_search` when built-in).

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-standard.qmd#L156-L193

## Intervention tools

`ask_user()` and `notify_user()` let the model communicate with a human operator during a running sample. Both are imported from `inspect_ai.tool` and pair with Inspect's Agent Intervention system (`inspect acp`, the in-process Textual panel, and Apprise-based notification channels).

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-standard.qmd#L928-L968

`ask_user()` — lets the model request structured information from the operator. It follows the ACP Elicitation standard and accepts a JSON-Schema `schema` dict describing one or more form fields (text, boolean, enum, integer, array). The sample **pauses** on the call until the operator responds. The call is dispatched to whichever surface is attached: an ACP client (`inspect acp`) if connected, otherwise the in-process Textual panel or console. Returns a JSON object string keyed by the schema's property names. Raises `ToolError` if the operator declines or cancels.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/tool/_tools/_ask_user.py#L1-L133

`notify_user()` — fire-and-forget status message to the operator (no reply awaited). Useful for long-running agents that want to surface progress or a blocking condition without halting the sample. Notifications are delivered via Apprise (Slack, desktop, SMS, email, and many other services) when the eval is configured with a notification target; returns a hint string when no channels are configured.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/tool/_tools/_notify_user.py#L1-L54

```python
from inspect_ai.agent import agent, react
from inspect_ai.tool import ask_user, notify_user, bash, text_editor

@agent
def ctf_agent():
    return react(
        description="Expert at completing cybersecurity challenges.",
        prompt="You are an expert at CTF challenges.",
        tools=[bash(), text_editor(), ask_user(), notify_user()]
    )
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-standard.qmd#L957-L968

## MCP tools

Inspect integrates the Model Context Protocol — point it at an MCP server and its tools become Inspect tools. Three server transports are supported:

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-mcp.qmd#L39-L62

- **stdio** — `mcp_server_stdio(...)`: launch a local MCP server subprocess.
- **HTTP** — `mcp_server_http(...)`: connect to an HTTP-based MCP endpoint. Pass `execution="remote"` to have the provider call the server on your behalf.
- **sandbox** — `mcp_server_sandbox(...)`: run the MCP server inside an Inspect sandbox container.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/tool/__init__.py#L21-L32

The `MCPServer` interface is a `ToolSource`, which means it can be passed anywhere `Tool` or `ToolDef` is accepted in Inspect generation APIs. Use `mcp_tools(server, tools=[...])` to select a subset of a server's tools. For stateful servers, wrap the agent loop in `mcp_connection(server)` to keep a single connection open; `react()` does this automatically.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-mcp.qmd#L127-L138

## Custom tools — signature, errors, async patterns

The model sees parameter names, types, defaults, and docstring `Args:` lines. Type annotations matter — they become JSON schema. Supported parameter types: `str`, `int`, `float`, `bool`, `list[T]`, `dict[str, T]`, `Literal[...]`, `Optional[T]`, plus dataclass/Pydantic-style models for nested objects.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-custom.qmd#L1-L16

Tool return values are stringified for the model unless you return a `ToolResult` with structured content (text and images, for multimodal tools).

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/tool/_tool.py#L35-L47

## Error handling — default and explicit

Inspect distinguishes *expected, recoverable* errors (reported to the model so it can adapt) from *unexpected* errors (which fail the `Sample`). The following are caught and reported by default:

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-custom.qmd#L29-L48

- `TimeoutError` from `subprocess()` / `sandbox().exec()` / `sandbox().read_file()` / `sandbox().write_file()`.
- `PermissionError` reading or writing a file.
- `UnicodeDecodeError` when process output or a file is binary rather than text.
- `OutputLimitExceededError` when an exec output stream exceeds 10 MiB, or when reading a file over 100 MiB.
- `ToolError` — explicit signal from a tool author to "tell the model".

Any other exception is unexpected and fails the sample. To bypass default handling on an expected error, catch and re-raise as a non-handled exception:

```python
try:
    result = await sandbox().exec(cmd=["decode", file], timeout=timeout)
except TimeoutError:
    raise RuntimeError("Decode operation timed out.")
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-custom.qmd#L54-L65

`ToolError` is declared in `_tool.py` (L50–L67); its message string is forwarded verbatim to the model as tool-result content.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/tool/_tool.py#L50-L67

Default handling applies to `generate()`. Custom agent scaffolds can intercept tool errors and apply their own filtering.

## Parallel execution

By default Inspect runs the tool calls in a single assistant turn serially in declared order. A tool with no shared mutable state (no sandbox interaction, no shared `Store` writes, no order-dependent side effects) can opt in to running concurrently with its siblings via `@tool(parallel=True)`:

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-custom.qmd#L102-L123

```python
@tool(parallel=True)
def fetch_url():
    async def fetch_url(url: str) -> str:
        """Fetch a URL and return its contents.

        Args:
            url: The URL to fetch.
        """
        ...
    return fetch_url
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/tool/_tool.py#L152-L160

In a mixed batch, each serial call is a barrier: consecutive parallel-eligible calls coalesce into one concurrent stage, a serial call runs alone, then the next stage begins. Result messages are spliced back in the model's declared order. If a parallel call raises an unhandled exception, its in-flight siblings are cancelled; `ToolError` is *not* unhandled — it becomes tool-result content and siblings continue. Only opt in after auditing for concurrent-safety. Stateful tools like `bash_session()` and `web_browser()` keep the default `parallel=False`.

## Stateful tools

A tool that needs to retain state across invocations (e.g. message history, an external session) should use `store_as()` against a `StoreModel` so that state lives in the per-sample store. Pass an `instance: str | None = None` parameter through to `store_as(..., instance=instance)` (and any inner tools it composes) so callers can spin up independent copies in the same sample:

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-custom.qmd#L126-L229

```python
from inspect_ai.util import StoreModel, store_as

class WebSurferState(StoreModel):
    messages: list[ChatMessage] = Field(default_factory=list)

@tool
def web_surfer(instance: str | None = None) -> Tool:
    async def execute(input: str, clear_history: bool = False) -> str:
        state = store_as(WebSurferState, instance=instance)
        ...
    return execute
```

Stateful tools should generally not be marked `parallel=True`.

## Tool choice

`use_tools(..., tool_choice=...)` overrides the model's default of deciding whether to call a tool. Values: `"auto"` (default), `ToolFunction(name="...")` to force a specific call, or `"none"` to disable tool use for the next generation (handy after a forced first turn).

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-custom.qmd#L231-L256

## Tool descriptions and `tool_with()`

Well-crafted tool and parameter descriptions materially affect how reliably models call a tool. `tool_with()` lets you adapt an existing tool's name, description, and parameter descriptions without re-implementing it:

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-custom.qmd#L258-L289

```python
from inspect_ai.tool import tool_with

my_add = tool_with(
    tool=addition(),
    name="my_add",
    description="a tool to add numbers",
    parameters={"x": "the x argument", "y": "the y argument"},
)
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/tool/_tool_with.py#L14-L78

`tool_with()` mutates the passed tool in place — to make multiple variants, construct the underlying tool multiple times (one per `tool_with()` call).

## Dynamic tools — `ToolDef`

For tools whose schema or behaviour depends on runtime (e.g. a per-sample variable command list, or wrapping a plain function with no `@tool` decorator), construct a `ToolDef`:

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-custom.qmd#L293-L331

```python
from inspect_ai.tool import ToolDef

async def addition(x: int, y: int):
    return x + y

add = ToolDef(
    tool=addition,
    name="add",
    description="A tool to add numbers",
    parameters={"x": "the x argument", "y": "the y argument"},
)

use_tools([add])
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/tool/_tool_def.py#L35-L80

`ToolDef` requires real type annotations on the wrapped function (they become JSON schema). It is accepted anywhere `Tool` is accepted in Inspect APIs; use `ToolDef.as_tool()` to hand it to a third-party API that only takes `Tool`. Passing an existing `Tool` to `ToolDef(...)` reverses the operation — useful for discovering a tool's name, description, and parameters.

## Tool approval

`Task(approval=...)` plugs in an `ApprovalPolicy` that gates each tool call. Built-in policies handle auto-approve, prompt-each, and pattern-based approval. Human-in-the-loop CTF-style evaluations use this. See `approval.qmd` and `ukgovernmentbeis-inspect-ai-sandboxing.md`.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools.qmd#L36-L43

## See also

- `ukgovernmentbeis-inspect-ai-agents.md` — agents wrap tool-loops with planning and memory.
- `ukgovernmentbeis-inspect-ai-sandboxing.md` — `sandbox()` for `bash()` / `python()` / `text_editor()` execution.
- `ukgovernmentbeis-inspect-ai-solvers.md` — `use_tools` and `generate(tool_calls=...)`.

## Source

- `docs/tools.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools.qmd
- `docs/tools-standard.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-standard.qmd
- `docs/tools-custom.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-custom.qmd
- `docs/tools-mcp.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/tools-mcp.qmd
- `docs/approval.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/docs/approval.qmd
- `src/inspect_ai/tool/` — implementation: https://github.com/UKGovernmentBEIS/inspect_ai/tree/6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40/src/inspect_ai/tool
- Repo SHA / as of: `6a78eff7a7bf99a58d1b9fe981cbbbdab978bb40 (as of 2026-05-27)`
