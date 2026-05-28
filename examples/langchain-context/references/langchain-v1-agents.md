---
name: langchain-v1-agents
description: The new agent surface in the `langchain` package (v1) — create_agent, the middleware system, AgentState, init_chat_model, and the LangGraph backend. Read this for any question about building agents in modern LangChain, what middleware does, or why v1 dropped AgentExecutor.
---

# LangChain v1: create_agent and middleware

The package called `langchain` on PyPI today (built from [`libs/langchain_v1/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain_v1)) is a near-total rewrite of the legacy agent system. Two things are radically smaller than 0.x:

- The public API is tiny. The top-level package exports effectively two symbols: `create_agent` and `AgentState`. There are no `AgentType` enums, no `initialize_agent`, no `AgentExecutor`, no per-style constructors like `create_react_agent` or `create_openai_functions_agent`.
- The runtime is LangGraph. `create_agent` constructs a `StateGraph` and returns a Runnable; the agent loop is implemented as graph-node message passing in LangGraph, not in this repo. `langchain` is the configuration layer; LangGraph is the engine.

The trade is composability: instead of a fixed agent loop with optional toggles, you compose **middleware** to inject behavior at well-defined hook points. Memory, retries, tool filtering, summarization, human-in-the-loop, PII redaction — all of these are middleware now.

## create_agent

`create_agent` is defined in [`libs/langchain_v1/langchain/agents/factory.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain_v1/langchain/agents/factory.py) and re-exported by [`libs/langchain_v1/langchain/agents/__init__.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain_v1/langchain/agents/__init__.py). The canonical call:

```python
from langchain.agents import create_agent

agent = create_agent(
    model="anthropic:claude-3-5-sonnet",
    tools=[search_tool, calculator],
    middleware=[...],
)
result = agent.invoke({"messages": [{"role": "user", "content": "..."}]})
```

The result is a LangGraph Runnable — [`agents/factory.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain_v1/langchain/agents/factory.py) constructs the `StateGraph` and returns it compiled. It accepts the same `invoke / ainvoke / stream / astream / astream_events` surface as any Runnable. The agent's state lives in `AgentState`, which carries `messages` (the conversation), tool-call accounting, and any keys middleware adds.

`model` can be a string (`"provider:name"` resolved through `init_chat_model`), a fully-instantiated `BaseChatModel`, or a callable returning one. `tools` is a list of `@tool`-decorated callables or `BaseTool` instances; the factory calls `model.bind_tools(tools)` for you. `response_format` (see `structured_output.py`) opts the agent into structured-output mode at the final step.

## Middleware: the central abstraction

Middleware is the v1 answer to "how do I customize the agent loop." Each middleware is an object that registers any subset of the lifecycle hooks defined in [`libs/langchain_v1/langchain/agents/middleware/types.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain_v1/langchain/agents/middleware/types.py):

- `before_agent(state) -> state` / `after_agent(state) -> state` — once per agent invocation.
- `before_model(state) -> request: ModelRequest` / `after_model(state, response: ModelResponse) -> state` — runs each turn around the LLM call.
- `wrap_tool_call(state, request: ToolCallRequest, call_next) -> response` — wraps each tool call, MIDDLEWARE-style (call `call_next(request)` to invoke the wrapped tool).

The factory composes the middleware list left-to-right around the agent loop. Middleware can short-circuit the run (e.g., human-in-the-loop returning an `interrupt`), mutate state (e.g., summarization replacing old messages), or wrap tool calls with retries, validation, or redaction.

## Built-in middleware

All under [`libs/langchain_v1/langchain/agents/middleware/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain_v1/langchain/agents/middleware). Each is a self-contained module; the file names map to import paths:

- `human_in_the_loop.py` — pause the agent before a tool call (or before the model) for human approval.
- `tool_retry.py`, `model_retry.py` — exponential-backoff retry on failure.
- `model_fallback.py` — fall back to an alternate model on failure.
- `summarization.py` — fold older messages into a summary when context gets long.
- `todo.py` — running todo list the agent reads from and writes to as state.
- `context_editing.py` — programmatic message editing each turn (trim, dedupe, inject).
- `file_search.py` — built-in tool for searching local files, registered as middleware so it composes uniformly with the agent's tool list.
- `pii.py` — redaction of PII fields from messages and tool outputs.
- `tool_selection.py` — dynamic narrowing of the tool surface per turn (e.g., based on intent).
- `tool_emulator.py` — replace real tool calls with a deterministic fake during testing.
- `shell_tool.py` — built-in shell-execution tool wrapped in safety middleware.
- `model_call_limit.py`, `tool_call_limit.py` — budget caps; raise or short-circuit beyond N calls.

The middleware base class lives in [`types.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain_v1/langchain/agents/middleware/types.py); shared helpers in `_execution.py`, `_retry.py`, `_redaction.py` (all leading-underscore private).

## AgentState

`AgentState` is a `TypedDict` (Pydantic-validated in places). Required key: `messages: list[BaseMessage]` with LangGraph's `add_messages` reducer (so appending is conflict-free across parallel branches). Additional keys are added by middleware — for example, the todo middleware adds a `todo` field, the summarization middleware adds a `summary` field. State persists across turns within a single `.invoke` call; for cross-call persistence, attach a LangGraph checkpointer (see the LangGraph companion).

## init_chat_model

[`libs/langchain_v1/langchain/chat_models.py`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain_v1/langchain/chat_models) provides `init_chat_model(model: str, **kwargs)`. The string form is `"provider:model"`, e.g., `"openai:gpt-5.4"` or `"anthropic:claude-3-5-sonnet"`. The function imports the right partner package on demand (raising a clear error if it's not installed) and returns the instantiated `BaseChatModel`. This is what `create_agent(model="anthropic:claude-3-5-sonnet", ...)` calls under the hood when `model` is a string.

## Structured output

`create_agent(response_format=MyPydanticModel, ...)` binds the structured-output spec to the model and adds a finalization step that validates the agent's final message against the schema. Implementation in [`libs/langchain_v1/langchain/agents/structured_output.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain_v1/langchain/agents/structured_output.py). The agent will route through one of three strategies (`auto`, provider-specific, or tool-based) depending on what the partner advertises.

## What's different from 0.x

- No `AgentExecutor`. The Runnable returned by `create_agent` IS the executor.
- No `AgentType`. Behavior is configured by middleware, not by enum.
- No `initialize_agent`. Just `create_agent`.
- No `agent.run(...)` or `agent.arun(...)`. Use `.invoke(state) / .ainvoke(state)`.
- Memory is gone as a separate object. State and persistence are LangGraph-native; middleware like `summarization` and `context_editing` handle in-context strategies; LangGraph checkpointers handle cross-call persistence.
- Chains are gone. For non-agent pipelines, use LCEL directly (`langchain-core-runnables.md`).

If you're migrating: there is no automated codemod. The shape of the rewrite is "replace `initialize_agent + AgentExecutor + memory + custom callbacks` with `create_agent(model, tools, middleware=[...])`." The middleware catalog above covers most of the historical agent customizations.

## What lives outside this package

LangGraph is the runtime; for any question about how the graph executes, durable checkpoints, branching, parallel nodes, or streaming graph events at the LangGraph level, see [`langgraph-overview.md`](langgraph-overview.md). LangSmith is the production observability layer; the v1 README explicitly directs production users there — see [`langsmith-sdk-overview.md`](langsmith-sdk-overview.md). For higher-level agent abstractions (planning, subagents, filesystem) that layer on top of `create_agent`, see [`deepagents-overview.md`](deepagents-overview.md).

## Gotchas

- The package name on PyPI is `langchain`. Pre-v1 0.x users had `langchain` installed and got chains/agents; new installs get this radically smaller surface. Pinning matters: `pip install "langchain<1"` gives the legacy surface (now renamed `langchain-classic` on PyPI but with the old module name still imported via the legacy install).
- `agent.invoke({"messages": [...]})` is the right call shape — passing a bare string is not supported. Use a `HumanMessage` or a chat dict.
- Middleware ordering matters: think of it as concentric wrapping. Retry middleware listed before fallback retries each model individually; reverse the order and the fallback decides first.
- Custom middleware: subclass the `AgentMiddleware` base class in `types.py`; only define the hooks you need; mutate `state` in place or return a new state dict.
- LangGraph is a hard dependency (`langgraph>=1.2.0`). It is *not* a separate optional install; `pip install langchain` pulls it in.
