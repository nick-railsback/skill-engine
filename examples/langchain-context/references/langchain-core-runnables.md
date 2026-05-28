# langchain-core: Runnables and LCEL

Almost everything in LangChain is a `Runnable`. Prompts, chat models, output parsers, retrievers, tools — they all implement the same four-method protocol and compose with the same operators. This is **LCEL**, the LangChain Expression Language. Understanding the Runnable abstraction is the single biggest leverage point in the codebase: most "how do I…" questions resolve to "compose these Runnables."

## The protocol

`Runnable[Input, Output]` is the abstract base class defined in [`libs/core/langchain_core/runnables/base.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/runnables/base.py). Every subclass implements four methods:

- `invoke(input, config=None) -> Output` — sync, single call.
- `ainvoke(input, config=None) -> Output` — async, single call.
- `batch(inputs, configs=None) -> list[Output]` — parallel sync; default impl uses a thread pool but subclasses can override (e.g., a chat model that natively supports batched requests).
- `abatch(inputs, configs=None) -> list[Output]` — parallel async via `asyncio.gather`.

Streaming is the second axis: `stream`, `astream`, and `astream_events` yield chunks instead of one final result. Not every Runnable streams meaningfully (a Runnable that calls a sync HTTP endpoint just yields one chunk), but the protocol is uniform.

`RunnableConfig` ([`libs/core/langchain_core/runnables/config.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/runnables/config.py)) is the per-call execution context: `callbacks`, `tags`, `metadata`, `run_name`, `max_concurrency`, `recursion_limit`, `configurable` (for `.configurable_fields` overrides). Configs merge through a chain — child Runnables inherit and extend the parent's config — so callbacks attached at the top of a pipeline reach every node below.

## LCEL operators

The composition story is three operators plus a coercion rule:

**`|` (pipe).** `__or__` is defined at [`runnables/base.py:619`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/runnables/base.py#L619). `a | b` returns a `RunnableSequence[Input_a, Output_b]`. The right operand is coerced to a Runnable: a plain Python function becomes `RunnableLambda(fn)`, a `dict` of Runnables becomes `RunnableParallel(...)`. So `prompt | chat_model | StrOutputParser()` and `{"a": chain_a, "b": chain_b} | combiner` both work without explicit wrapping.

**`.bind(**kwargs)`** ([`base.py:1788`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/runnables/base.py#L1788)). Pre-attaches kwargs to every future `.invoke` call. Canonical use: `chat_model.bind(stop=["\n\n"])` or `chat_model.bind_tools([my_tool])`. Returns a `RunnableBinding` that wraps the original.

**`.with_config(config)`** ([`base.py:1822`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/runnables/base.py#L1822)). Pre-attaches a `RunnableConfig` (callbacks, tags, retry policy, etc.). Used to tag sub-pipelines for observability or to scope concurrency limits.

There are several other "with_" decorators worth knowing: `.with_retry(...)`, `.with_fallbacks([alt1, alt2])`, `.with_listeners(on_start, on_end, on_error)`, `.with_types(input_type, output_type)`. All return wrapped Runnables.

## Common Runnable subclasses

All live in [`libs/core/langchain_core/runnables/base.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/runnables/base.py) (it is intentionally a large file — the protocol and the most-used implementations are co-located so that LCEL operations don't have to chase imports):

- **`RunnableSequence`** (≈ line 2995). Pipes Runnables left to right. Built by `|` but also constructible directly: `RunnableSequence(first=a, middle=[b, c], last=d)`.
- **`RunnableParallel`** (≈ line 3743). Maps a single input to a dict of branches, each running in parallel. Built from a `dict` on the right of `|`. Output is `dict[str, Output]`.
- **`RunnableLambda`** (≈ line 4577). Wraps a plain function (sync or async). The function may take a single positional `input`, or `(input, config)` for callback awareness.
- **`RunnableBranch`** (in [`runnables/branch.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/runnables/branch.py)). If/else routing: takes a list of `(predicate, runnable)` pairs plus a default.
- **`RunnablePassthrough`** (in [`runnables/passthrough.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/runnables/passthrough.py)). Identity function for slotting into a `RunnableParallel` to forward the input alongside derived values. Idiomatic for RAG: `{"context": retriever, "question": RunnablePassthrough()} | prompt | model`.

## Configurability and serialization

`ConfigurableField` lets a Runnable expose runtime-tunable knobs. `chat_model.configurable_fields(temperature=ConfigurableField(id="temp"))` followed by `.with_config(configurable={"temp": 0.0})` swaps the value per call. This is how the canonical "swap model at runtime" pattern works without rebuilding the pipeline.

Serialization comes from the [`Serializable`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/load/serializable.py) mixin. Runnables that subclass `Serializable` can be dumped to a portable dict (`dumpd`) and loaded back via the registry in [`libs/core/langchain_core/load/mapping.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/load/mapping.py). This is what powers LangSmith's "save this chain" feature and what makes LCEL pipelines portable across processes.

## Streaming events

`astream_events(input, version="v2")` is the modern streaming surface — it yields a typed event stream covering every node in the pipeline (start, stream-chunk, end, on-tool-call, on-retrieval, etc.). Each event carries `run_id`, `tags`, and the chunk payload. This replaces the older `astream_log` API. The implementation lives in [`libs/core/langchain_core/tracers/event_stream.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/tracers/event_stream.py). For the broader callbacks story, see `langchain-core-callbacks.md`.

## Gotchas

- A `dict` on the right of `|` is auto-coerced to `RunnableParallel`. If you actually want to pass a literal dict downstream (rare), wrap it in `RunnableLambda(lambda _: my_dict)`.
- `RunnableLambda` is single-input only by convention. If the function needs multiple values, pass them as a dict and have the function unpack — this composes with `RunnableParallel` cleanly.
- `batch` is parallel by default; for ordered sequential semantics, iterate `invoke` yourself.
- Async/sync mixing works (sync Runnables in an async pipeline get auto-wrapped), but you pay a thread-pool hop. Prefer all-async pipelines for production.
- LCEL is the building block of both langchain-classic chains and langchain v1 agents. The same `prompt | model | parser` triplet works in both packages.

For depth: read the docstrings inside [`runnables/base.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/runnables/base.py) — the file is heavily annotated and is the authoritative spec for the protocol.
