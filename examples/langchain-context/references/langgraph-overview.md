---
name: langgraph-overview
description: Companion repo langchain-ai/langgraph — the low-level graph orchestration framework that powers langchain v1 agents. Covers StateGraph, checkpointers, prebuilt helpers, the SDK and CLI, and how it relates to langchain.create_agent.
---

# LangGraph (companion repo)

LangGraph is a low-level orchestration framework for stateful, long-running agents and workflows. It is published from [langchain-ai/langgraph](https://github.com/langchain-ai/langgraph/tree/add269632bb32c57f3252b7a7006c8115b579fb4) — a separate repo from `langchain-ai/langchain`, but a hard dependency of the new `langchain` package: `langchain.create_agent` returns a LangGraph `StateGraph`, and agent execution is graph-node message passing under the hood. For deep questions about *how an agent actually runs* — durable execution, interrupts, checkpointing, streaming — the answer lives here, not in the `langchain` repo.

LangGraph is usable standalone. It does not require LangChain at runtime — only `langchain-core` for message and runnable types. The [`README.md`](https://github.com/langchain-ai/langgraph/blob/add269632bb32c57f3252b7a7006c8115b579fb4/README.md) is explicit: "LangGraph is built by LangChain Inc … but can be used without LangChain."

## Repo layout

A monorepo of independently versioned packages under `libs/`:

- [`libs/langgraph/`](https://github.com/langchain-ai/langgraph/tree/add269632bb32c57f3252b7a7006c8115b579fb4/libs/langgraph) — publishes `langgraph` (v1.2.2). The core: `StateGraph`, `START`/`END`, `add_messages`, the Pregel runtime, channels, streaming. Public API is re-exported from [`langgraph/__init__.py`](https://github.com/langchain-ai/langgraph/blob/add269632bb32c57f3252b7a7006c8115b579fb4/libs/langgraph/langgraph/graph/__init__.py); the `Command`, `Send`, `Interrupt`, `StateSnapshot`, `RetryPolicy`, `CachePolicy`, etc. types are exported from [`langgraph/types.py`](https://github.com/langchain-ai/langgraph/blob/add269632bb32c57f3252b7a7006c8115b579fb4/libs/langgraph/langgraph/types.py).
- [`libs/prebuilt/`](https://github.com/langchain-ai/langgraph/tree/add269632bb32c57f3252b7a7006c8115b579fb4/libs/prebuilt) — publishes `langgraph-prebuilt` (v1.1.0). High-level helpers: `create_react_agent`, `ToolNode`, `tools_condition`, `InjectedState`, `InjectedStore`, `ToolRuntime`, `ValidationNode`. See [`langgraph/prebuilt/__init__.py`](https://github.com/langchain-ai/langgraph/blob/add269632bb32c57f3252b7a7006c8115b579fb4/libs/prebuilt/langgraph/prebuilt/__init__.py).
- [`libs/checkpoint/`](https://github.com/langchain-ai/langgraph/tree/add269632bb32c57f3252b7a7006c8115b579fb4/libs/checkpoint) — publishes `langgraph-checkpoint` (v4.1.1). Base interfaces for checkpoint savers, stores, and caches. The persistence backbone for "durable execution" and human-in-the-loop pause/resume.
- [`libs/checkpoint-postgres/`](https://github.com/langchain-ai/langgraph/tree/add269632bb32c57f3252b7a7006c8115b579fb4/libs/checkpoint-postgres), [`libs/checkpoint-sqlite/`](https://github.com/langchain-ai/langgraph/tree/add269632bb32c57f3252b7a7006c8115b579fb4/libs/checkpoint-sqlite) — Concrete backends for the checkpoint interface. Use SQLite for local dev/tests, Postgres for production.
- [`libs/cli/`](https://github.com/langchain-ai/langgraph/tree/add269632bb32c57f3252b7a7006c8115b579fb4/libs/cli) — publishes `langgraph-cli`. The `langgraph` command — `langgraph dev` to run a local server with Studio attached, `langgraph build` to package for deploy.
- [`libs/sdk-py/`](https://github.com/langchain-ai/langgraph/tree/add269632bb32c57f3252b7a7006c8115b579fb4/libs/sdk-py) — publishes `langgraph-sdk`. Python client for the LangGraph Server REST API (the hosted/self-hosted runtime).
- [`libs/sdk-js/`](https://github.com/langchain-ai/langgraph/tree/add269632bb32c57f3252b7a7006c8115b579fb4/libs/sdk-js) — JS/TS counterpart of the same SDK. Standalone (no Python deps).
- [`libs/checkpoint-conformance/`](https://github.com/langchain-ai/langgraph/tree/add269632bb32c57f3252b7a7006c8115b579fb4/libs/checkpoint-conformance) — Contract tests every checkpoint backend must pass. Mirrors the `langchain-tests` pattern for partner integrations.

## What LangGraph provides

The framework solves five problems the Runnable/LCEL surface in `langchain-core` does not:

1. **Stateful, multi-step graphs.** `StateGraph(state_schema)` lets you declare a typed state (a TypedDict, dataclass, or Pydantic model) and add nodes that read it and return partial updates. Edges (regular or conditional) decide what runs next. The `add_messages` reducer is the canonical example — it concatenates lists of messages instead of overwriting.
2. **Durable execution via checkpointers.** Pass a `BaseCheckpointSaver` (`InMemorySaver`, `PostgresSaver`, `SqliteSaver`) to `.compile(checkpointer=...)` and the graph snapshots its state after every node. Resumable across processes; the same `thread_id` continues a conversation.
3. **Human-in-the-loop interrupts.** A node can call `interrupt(value)` (from `langgraph.types`) to pause and surface a value to the caller. The caller resumes by invoking the graph again with `Command(resume=...)`.
4. **Multiple streaming modes.** Compiled graphs expose `stream(... , stream_mode=...)` with modes `values`, `updates`, `messages`, `custom`, `debug`, `checkpoints`, `tasks` (see `StreamPart` subtypes in [`types.py`](https://github.com/langchain-ai/langgraph/blob/add269632bb32c57f3252b7a7006c8115b579fb4/libs/langgraph/langgraph/types.py)). Different modes for token streaming vs. state diffs vs. observability.
5. **Concurrency and routing primitives.** `Send(node, state)` to fan out work to N copies of a node with different inputs (map step). `Command(goto=..., update=...)` from a node return value to combine an update with an explicit next-node hop.

## How LangGraph relates to `langchain.create_agent`

The new `langchain` package (v1) layers a small, opinionated agent API on top of LangGraph. `create_agent(model, tools, ...)` constructs a `StateGraph` with two nodes — the model call and a `ToolNode` — and the standard message-loop edges between them, plus middleware. The compiled output *is* a LangGraph `StateGraph` you can `.stream()`, `.invoke()`, attach a checkpointer to, and inspect with the LangGraph SDK. See the contextualizer's [`langchain-v1-agents.md`](langchain-v1-agents.md) for the agent-side surface.

The older `langgraph.prebuilt.create_react_agent` (exported from [`prebuilt/__init__.py`](https://github.com/langchain-ai/langgraph/blob/add269632bb32c57f3252b7a7006c8115b579fb4/libs/prebuilt/langgraph/prebuilt/__init__.py)) predates `langchain.create_agent` and overlaps with it. Both build a similar two-node ReAct-style loop; `langchain.create_agent` is the recommended entry point for new projects because it adds the middleware system and integrates with `init_chat_model`. Existing code calling `create_react_agent` does not need to migrate — the prebuilt helper is supported. Choose `langchain.create_agent` for new code; keep `create_react_agent` for code that already uses it or that needs the lower-level options the langgraph helper exposes.

## Checkpointers and the persistence model

A checkpointer is what makes an agent stateful across invocations. Without one, every `.invoke()` runs the graph from scratch. With one, state is keyed by `thread_id` (passed in `config={"configurable": {"thread_id": "..."}}`) and resumes after every node. The base saver interface lives in [`libs/checkpoint/`](https://github.com/langchain-ai/langgraph/tree/add269632bb32c57f3252b7a7006c8115b579fb4/libs/checkpoint); three concrete savers ship today:

- `langgraph.checkpoint.memory.InMemorySaver` — in-process; for tests and notebooks.
- `langgraph-checkpoint-sqlite` — SQLite file; for local dev and small deployments.
- `langgraph-checkpoint-postgres` — Postgres; for production. Supports both sync (`PostgresSaver`) and async (`AsyncPostgresSaver`) connection pools.

`langgraph-checkpoint` also defines `BaseStore` (a key-value cross-thread store, distinct from per-thread checkpoint state — used for memory across conversations) and `BaseCache` (for caching node outputs to skip re-executing expensive nodes on retry). All three abstractions live in [`libs/checkpoint/langgraph/checkpoint/`](https://github.com/langchain-ai/langgraph/tree/add269632bb32c57f3252b7a7006c8115b579fb4/libs/checkpoint/langgraph/checkpoint).

## The Server / SDK split

LangGraph as installed via `pip install langgraph` is a runtime library you embed in a process. There is also a separate **LangGraph Server** — a long-running HTTP service that hosts compiled graphs, manages threads and checkpoints, and exposes a REST API. `langgraph-sdk` (Python) and the JS SDK in `libs/sdk-js/` are clients for that API. `langgraph-cli` (`langgraph dev`, `langgraph build`, `langgraph up`) is what you use to run the server locally or build it for deploy. The hosted version is part of LangSmith Deployment.

If a question is about agents that "run on a server" or "scale to 1000 conversations", it is the Server + SDK story (the client lives in [`libs/sdk-py/`](https://github.com/langchain-ai/langgraph/tree/add269632bb32c57f3252b7a7006c8115b579fb4/libs/sdk-py)), not the embedded library. The embedded library still works fine in any process you control (web app, CLI, notebook).

## Common gotchas

- **`langgraph.graph.StateGraph` vs. `langgraph.graph.MessageGraph`.** `MessageGraph` is the old single-channel-of-messages-only API; it is still re-exported but `StateGraph` is the recommended choice. New code should use `StateGraph(MessagesState)` if all you need is a list of messages.
- **State updates are merged, not assigned.** A node returns `{"messages": [new_msg]}` not the full state. The reducer (`add_messages` for the messages key) defines how the partial merges in. Forgetting this and returning the full state typically silently wipes other channels.
- **`thread_id` is required when a checkpointer is attached.** Compiling with a checkpointer but invoking without `config={"configurable": {"thread_id": "..."}}` raises at runtime. Use any string per conversation.
- **`Command(goto=...)` vs. conditional edges.** Conditional edges are declared at compile time on the graph. `Command(goto=...)` is a runtime decision returned from inside a node. Use conditional edges when the routing logic is purely about state; use `Command` when the node already had to compute the routing as a side effect of its work.
- **Different `langgraph` and `langgraph-prebuilt` versions.** They are separate PyPI packages with separate version pins. `langgraph 1.2.2` works against `langgraph-prebuilt >=1.1.0,<1.2.0` per the [`pyproject.toml`](https://github.com/langchain-ai/langgraph/blob/add269632bb32c57f3252b7a7006c8115b579fb4/libs/langgraph/pyproject.toml). Pin both, or let `langgraph` pull the prebuilt version it tested against.

## Documentation pointers

- [docs.langchain.com/oss/python/langgraph/overview](https://docs.langchain.com/oss/python/langgraph/overview) — concept guides (durable execution, interrupts, memory, streaming).
- [reference.langchain.com/python/langgraph](https://reference.langchain.com/python/langgraph) — API reference.
- [`AGENTS.md`](https://github.com/langchain-ai/langgraph/blob/add269632bb32c57f3252b7a7006c8115b579fb4/AGENTS.md) at the repo root has the dependency map between the seven Python packages and the maintainer-facing build commands (`make format`, `make lint`, `make test`).
