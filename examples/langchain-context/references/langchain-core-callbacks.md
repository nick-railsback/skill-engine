---
name: langchain-core-callbacks
description: Callbacks, tracers, and the streaming events system — how to observe and instrument LangChain pipelines. Read this for any question about BaseCallbackHandler, CallbackManager, astream_events, run_id, tags, on_llm_start/on_chain_end/on_tool_call, or how LangSmith integrates.
---

# langchain-core: callbacks, tracers, streaming events

LangChain has a single uniform observability surface: every node in a `Runnable` pipeline fires lifecycle events that any registered handler can receive. This is the mechanism behind LangSmith tracing, the per-token streaming UI, structured event streams, retry/fallback logging, and custom telemetry. Understanding it once unlocks all four use cases.

## The callback contract

`BaseCallbackHandler` ([`libs/core/langchain_core/callbacks/base.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/callbacks/base.py)) defines a wide method surface, but the conceptually meaningful events split into a few categories. For each pair of `on_*_start` / `on_*_end` (plus `on_*_error`) handler methods, there is also an `on_*_new_token` for streaming-capable nodes:

- **Chain lifecycle.** `on_chain_start(serialized, inputs, run_id, parent_run_id, tags, metadata, ...)` and `on_chain_end(outputs, run_id, ...)`. "Chain" here is any composite Runnable (a `RunnableSequence`, `RunnableParallel`, etc., or anything user code labels as a chain).
- **LLM lifecycle.** `on_llm_start(serialized, prompts, ...)`, `on_chat_model_start(serialized, messages, ...)`, `on_llm_new_token(token, chunk, ...)`, `on_llm_end(response, ...)`. The chat-model variant is what fires for `BaseChatModel`; the plain LLM variant is for `BaseLLM`.
- **Tool lifecycle.** `on_tool_start(serialized, input_str, ...)`, `on_tool_end(output, ...)`. Fires for any `BaseTool.invoke`.
- **Retriever lifecycle.** `on_retriever_start(serialized, query, ...)`, `on_retriever_end(documents, ...)`.
- **Agent lifecycle.** `on_agent_action(action, ...)`, `on_agent_finish(finish, ...)`. Legacy `langchain_classic` agent surface; v1 agents stream LangGraph events instead.
- **Generic.** `on_text(text, ...)` for unstructured strings, `on_retry(...)`.

Each callback method gets a `run_id: UUID` and `parent_run_id: UUID | None`. The pair lets a handler reconstruct the call tree across async boundaries — LangSmith uses this to render the trace as a nested span tree.

`AsyncCallbackHandler` is the async-method twin. A handler can implement either or both. There is also an `ignore_*` family of class attributes (`ignore_llm = True`, etc.) to opt out of categories the handler doesn't care about, which avoids the cost of constructing event payloads it would throw away.

## Attaching handlers

Three places callbacks attach:

- **Constructor.** `ChatOpenAI(callbacks=[handler], ...)`. Permanent on that instance.
- **Per-call config.** `chain.invoke(input, config={"callbacks": [handler]})`. Scoped to one invocation; propagates down through every nested Runnable. This is how LangSmith's `tracing_v2_enabled` context manager works under the hood.
- **`.with_config(callbacks=[...])`.** Returns a new Runnable that has the handler baked into its default config.

Handlers compose: lists from constructor + per-call + `.with_config` are concatenated and all fire. `CallbackManager` ([`libs/core/langchain_core/callbacks/manager.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/callbacks/manager.py)) is the dispatcher that fans events out to the registered handlers; there is also `AsyncCallbackManager` for the async path.

Tags and metadata on a `RunnableConfig` propagate into every callback event. Use them to bucket spans by feature flag, user ID, request ID, etc.

## Tracers

A *tracer* is a callback handler that builds a tree of runs rather than just consuming events. They live in [`libs/core/langchain_core/tracers/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/tracers):

- [`base.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/tracers/base.py) — `BaseTracer` building block.
- [`event_stream.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/tracers/event_stream.py) — the v2 streaming-events tracer (powers `astream_events`).
- [`log_stream.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/tracers/log_stream.py) — the legacy `astream_log` tracer.
- [`root_listeners.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/tracers/root_listeners.py) — implementation of `.with_listeners(on_start, on_end, on_error)`.
- [`schemas.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/tracers/schemas.py) — `Run` typed dict and friends.

The LangSmith tracer (`LangChainTracer`) lives here too; it batches runs and ships them to the LangSmith API. Set `LANGSMITH_TRACING=true` plus `LANGSMITH_API_KEY` in the environment and the tracer attaches automatically to every Runnable invocation — no code changes required. For the LangSmith side of the integration, see [`langsmith-sdk-overview.md`](langsmith-sdk-overview.md).

## astream_events v2

`runnable.astream_events(input, version="v2", **kwargs)` is the modern streaming surface. It yields events shaped like:

```python
{"event": "on_chat_model_stream",
 "name": "ChatOpenAI",
 "run_id": "...",
 "tags": [...],
 "metadata": {...},
 "data": {"chunk": AIMessageChunk(...)}}
```

Event names mirror the callback methods: `on_chain_start`, `on_chat_model_stream`, `on_tool_end`, `on_retriever_end`, etc. Filter by event name or by tag to subscribe to only the events you want. This is the recommended API for building token-streaming UIs, debug consoles, or real-time progress indicators because it captures the entire pipeline (not just the LLM tokens) in a single typed stream.

`astream_log` (v1 streaming) still works for backward compat, but `astream_events` is what new code should use.

## Streaming tokens vs streaming events

These are two distinct surfaces and they answer different questions:

- `chat_model.astream(input)` yields raw `AIMessageChunk`s from a single model. Use it when you want only the model's token output.
- `chain.astream(input)` yields whatever the *last* Runnable in the chain yields, which is often the parser's incremental output. Use it for "stream the final answer."
- `chain.astream_events(input, version="v2")` yields typed events from *every* node. Use it for instrumented streaming and observability.

For background detail on the Runnable streaming protocol, see `langchain-core-runnables.md`.

## Gotchas

- `astream_events` only emits events for Runnables that participate in the LCEL graph. A plain Python function called inside an LCEL chain is opaque unless wrapped in `RunnableLambda(fn)`.
- Callbacks set via constructor do NOT propagate to nested Runnables created by `.bind(...)` or `.with_config(...)`; per-call callbacks DO propagate. Prefer per-call config for cross-cutting handlers.
- Handlers run inline by default, on the calling thread (or in the event loop for async). A slow handler is a backpressure source. For heavy work, queue the event and process out-of-band.
- The `run_id` is generated per invocation, not per Runnable instance — repeated invocations of the same chain produce distinct trees.
- Tags and metadata merge, not replace, as the config propagates downward. To overwrite at a particular node, use `.with_config(tags=[...])` explicitly.
- The legacy callbacks `on_agent_action` / `on_agent_finish` fire from `langchain_classic.agents.AgentExecutor`. v1 agents (LangGraph-based) emit LangGraph events that surface through `astream_events` — there is no equivalent `on_agent_*` for v1 in this package.
