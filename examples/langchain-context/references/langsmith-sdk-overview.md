---
name: langsmith-sdk-overview
description: Companion repo langchain-ai/langsmith-sdk — the Python and JS client SDKs for the LangSmith observability platform. Covers the @traceable decorator, framework wrappers, the Client API, evaluations, and how it relates to langchain-core callbacks.
---

# LangSmith SDK (companion repo)

LangSmith is LangChain's hosted observability and evaluation platform — traces, datasets, evaluations, prompt management. The SDK in [langchain-ai/langsmith-sdk](https://github.com/langchain-ai/langsmith-sdk/tree/b3f1b0af0618ead2160b7fde78c894acd1fe2bb2) is the Python and JS/TS client library that ships traces and runs evaluations against the platform. Both top-level READMEs in `langchain-ai/langchain` steer production users here, and `langchain-core`'s callback system has a native LangSmith tracer (`LangChainTracer`, see the contextualizer's [`langchain-core-callbacks.md`](langchain-core-callbacks.md)) — which means *if `LANGSMITH_TRACING=true` and `LANGSMITH_API_KEY` are in the environment, any `langchain` / `langgraph` code already exports traces with no further code changes*.

The SDK is also useful **standalone**, with no LangChain dependency. The `@traceable` decorator and `wrap_openai`-style framework wrappers let you trace plain Python (or JS) code that calls any LLM provider directly. The README's quick-start uses `openai.Client` wrapped with `wrap_openai`, no LangChain imports anywhere.

## Repo layout

A polyglot repo with two top-level SDK trees:

- [`python/`](https://github.com/langchain-ai/langsmith-sdk/tree/b3f1b0af0618ead2160b7fde78c894acd1fe2bb2/python) — publishes `langsmith` on PyPI (v0.8.5). Pure Python; depends only on `pydantic`, `requests`, `httpx`, `orjson`, and small utilities — no `langchain*` runtime dependency. See [`python/langsmith/__init__.py`](https://github.com/langchain-ai/langsmith-sdk/blob/b3f1b0af0618ead2160b7fde78c894acd1fe2bb2/python/langsmith/__init__.py).
- [`js/`](https://github.com/langchain-ai/langsmith-sdk/tree/b3f1b0af0618ead2160b7fde78c894acd1fe2bb2/js) — publishes `langsmith` on npm. JS/TS counterpart with the same `traceable` and `wrapOpenAI` shape. Also ships an experimental Vercel AI SDK integration under [`js/src/experimental/vercel/`](https://github.com/langchain-ai/langsmith-sdk/tree/b3f1b0af0618ead2160b7fde78c894acd1fe2bb2/js/src/experimental/vercel) — `LangSmithTelemetry` (an OTel-compatible telemetry exporter the Vercel SDK can plug into) plus a `wrap()` that decorates Vercel SDK calls; this surface has no Python equivalent.
- [`openapi/`](https://github.com/langchain-ai/langsmith-sdk/tree/b3f1b0af0618ead2160b7fde78c894acd1fe2bb2/openapi) — OpenAPI spec the SDKs are generated against. Source of truth for the LangSmith REST API.

The Python tree is the deeper one and is what most LangChain users will need. The rest of this reference covers Python; the JS surface mirrors it.

## Public Python surface

Re-exported from the top-level `langsmith` package:

- **Tracing**: `traceable` (decorator), `trace` (context manager), `tracing_context`, `get_current_run_tree`, `set_run_metadata`, `get_tracing_context`. From [`langsmith/run_helpers.py`](https://github.com/langchain-ai/langsmith-sdk/blob/b3f1b0af0618ead2160b7fde78c894acd1fe2bb2/python/langsmith/run_helpers.py).
- **Run trees**: `RunTree`, `configure`. Lower-level than `traceable` — manually construct and post a tree of runs. Most users don't touch this.
- **Client**: `Client`, `AsyncClient`, `TracingMode`. The HTTP client to the LangSmith API. Use it for dataset CRUD, run search, prompt push/pull, project management. Available from `langsmith.client` directly.
- **Evaluation**: `evaluate`, `aevaluate`, `evaluate_existing`, `aevaluate_existing`, `EvaluationResult`, `RunEvaluator`. Run a target function over a dataset and produce evaluator scores. From [`langsmith/evaluation/`](https://github.com/langchain-ai/langsmith-sdk/tree/b3f1b0af0618ead2160b7fde78c894acd1fe2bb2/python/langsmith/evaluation).
- **Testing**: `test`, `unit`. Pytest helpers that turn a test into a LangSmith run; combine with the `pytest_plugin` for dataset-driven tests.
- **Prompt cache**: `PromptCache`, `AsyncPromptCache`. Local cache for the LangSmith prompt registry to avoid round-trips on repeated `client.pull_prompt(...)`.
- **Utilities**: `expect` (assertion helpers for LLM outputs in tests), `uuid7` / `uuid7_from_datetime` (sortable UUID v7 used for run ids).

## Framework wrappers and integrations

Two parallel trees cover non-LangChain LLM stacks:

- [`langsmith/wrappers/`](https://github.com/langchain-ai/langsmith-sdk/tree/b3f1b0af0618ead2160b7fde78c894acd1fe2bb2/python/langsmith/wrappers) — drop-in client wrappers: `wrap_openai`, `wrap_anthropic`, `wrap_gemini`, `wrap_openai_agents`. Each takes the provider's client and returns a wrapped instance that emits LangSmith traces on every call. Zero application-code changes beyond the wrap call.
- [`langsmith/integrations/`](https://github.com/langchain-ai/langsmith-sdk/tree/b3f1b0af0618ead2160b7fde78c894acd1fe2bb2/python/langsmith/integrations) — deeper hook-based integrations: `claude_agent_sdk`, `google_adk`, `openai_agents_sdk`, `strands_agents`, plus `otel` (OpenTelemetry export). Use these when wrapping the client isn't enough — typically when the third-party framework manages its own loop.

For OpenTelemetry export specifically: `pip install langsmith[otel]` adds the OTel runtime and lets traces flow into any OTel-compatible backend in addition to (or instead of) LangSmith.

## Sandboxed code execution

`langsmith.sandbox` ([`python/langsmith/sandbox/`](https://github.com/langchain-ai/langsmith-sdk/tree/b3f1b0af0618ead2160b7fde78c894acd1fe2bb2/python/langsmith/sandbox)) is a recent addition for running untrusted code in isolated containers managed by the LangSmith platform. Typical usage:

```python
from langsmith.sandbox import SandboxClient

client = SandboxClient()  # reads LANGSMITH_ENDPOINT and LANGSMITH_API_KEY
with client.sandbox() as sb:
    result = sb.run("python -c 'print(2 + 2)'")
    print(result.stdout)   # "4\n"
    print(result.success)  # True
```

Use `client.create_sandbox()` / `client.delete_sandbox(name)` to keep a sandbox across calls, or `client.get_sandbox(name=...)` to attach to an existing one. Snapshots boot a sandbox from a reusable filesystem image. Async equivalents live alongside (`AsyncSandboxClient`).

By default the client talks HTTP; install `pip install 'langsmith[sandbox]'` to add the `websockets` extra for real-time streaming, callbacks, and `timeout=0` (long-running) execution — without it `sb.run()` falls back to HTTP. The JS SDK ships a parallel `sandbox/` module ([`js/src/sandbox/`](https://github.com/langchain-ai/langsmith-sdk/tree/b3f1b0af0618ead2160b7fde78c894acd1fe2bb2/js/src/sandbox)) with the same shape.

This is the SDK surface most relevant to agents that need to execute model-generated code safely — pair with `create_agent` tool middleware (`langchain-v1-agents.md`) to swap a local shell for a sandboxed runner.

## How LangChain code triggers tracing

LangChain users almost never call this SDK directly. The chain is:

1. App imports `langchain`, `langgraph`, or `langchain-core`.
2. App sets `LANGSMITH_TRACING=true` and `LANGSMITH_API_KEY=ls_...` (and optionally `LANGSMITH_WORKSPACE_ID` for org-scoped keys, plus `LANGSMITH_PROJECT` to override the default project name).
3. Any `Runnable.invoke / .stream / .ainvoke / .astream` call routes through the `LangChainTracer` callback handler, which posts run trees to LangSmith.

This means the *most common LangSmith question from a LangChain user* — "how do I add tracing to my agent?" — has no SDK code answer. It is two environment variables. The SDK only enters the picture when the user wants to **(a)** trace non-LangChain code (`@traceable`), **(b)** add metadata or tags to runs (`set_run_metadata`, `tracing_context`), **(c)** run evaluations (`evaluate`), or **(d)** programmatically manage datasets, projects, or prompts (`Client`).

The contextualizer's [`langchain-core-callbacks.md`](langchain-core-callbacks.md) covers the LangChain side of the integration; this reference covers the SDK side.

## Common gotchas

- **`evaluate` was moved to `Client.evaluate()`.** Importing `from langsmith.evaluation import evaluate` still works but emits a deprecation warning since 0.5.0. The new entry point is `Client().evaluate(...)` — see the `__getattr__` shim in [`langsmith/evaluation/__init__.py`](https://github.com/langchain-ai/langsmith-sdk/blob/b3f1b0af0618ead2160b7fde78c894acd1fe2bb2/python/langsmith/evaluation/__init__.py).
- **Workspace-scoped vs. org-scoped API keys.** Org-scoped keys (`ls_org_*`) require `LANGSMITH_WORKSPACE_ID`; workspace keys (`ls_*`) don't. Misconfiguration here surfaces as 401s with no clear message in the trace dashboard.
- **The Python package was once `langsmith` *and* `langsmith-pyo3`.** The PyO3 variant is an optional perf path enabled via `pip install langsmith[langsmith_pyo3]`. Pure-Python install is the default and works everywhere.
- **`traceable` and `Runnable` traces nest correctly.** A `@traceable` function that calls a `Runnable` produces a single tree with the runnable runs as children — the tracing context propagates via contextvars. No special wiring needed.
- **PII and anonymization.** Use the `langsmith.anonymizer` module to scrub fields before they're posted. There is no server-side scrubbing for already-uploaded runs.

## Documentation pointers

- [docs.smith.langchain.com](https://docs.smith.langchain.com/) — the LangSmith product docs (concepts, how-to, dataset workflows). The SDK README is intentionally short and points here.
- [smith.langchain.com](https://smith.langchain.com/) — the hosted UI.
- [langsmith-cookbook](https://github.com/langchain-ai/langsmith-cookbook) — runnable evaluation and tracing recipes.
- The README's "Quick Start" examples in [`README.md`](https://github.com/langchain-ai/langsmith-sdk/blob/b3f1b0af0618ead2160b7fde78c894acd1fe2bb2/README.md) are the shortest working `traceable` / `wrap_openai` snippets.
