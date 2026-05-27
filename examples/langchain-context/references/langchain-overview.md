---
name: langchain-overview
description: Orientation to the langchain-ai/langchain monorepo — its subprojects, the langchain vs langchain-classic split, and which companion repos live elsewhere. Read this first for any structural question about the codebase.
---

# LangChain monorepo overview

LangChain (the Python project) is a framework for building agents and LLM-powered applications. The repo at [langchain-ai/langchain](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5) is a monorepo of independently versioned Python packages plus a small set of shared resources. The two facts most likely to confuse a new reader are: (1) there are two top-level package directories that look like the same package — `libs/langchain/` and `libs/langchain_v1/` — but they publish to PyPI under different names, and (2) the package called `langchain` on PyPI today is the *new* one, not the legacy one.

## Repo layout

The interesting tree lives entirely under `libs/`:

- [`libs/core/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core) — publishes `langchain-core`. The foundational abstractions every downstream package depends on: Runnable / LCEL, BaseMessage, BaseChatModel, BaseTool, BaseOutputParser, Document, BaseRetriever, callbacks. See `langchain-core-runnables.md`, `langchain-core-models.md`, `langchain-core-retrieval.md`, `langchain-core-callbacks.md`.
- [`libs/langchain_v1/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain_v1) — publishes `langchain` (the package; v1.3.2). Agent-first, middleware-based, runs on LangGraph. Surface is intentionally small: `create_agent`, `AgentState`, a thin `init_chat_model`. See `langchain-v1-agents.md`.
- [`libs/langchain/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain) — publishes `langchain-classic` (v1.0.7). The legacy chains/agents/memory API kept on life support; new development is closed. See `langchain-classic.md`.
- [`libs/partners/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/partners) — 15 in-tree provider packages (anthropic, openai, ollama, groq, mistralai, huggingface, fireworks, deepseek, perplexity, xai, openrouter, chroma, qdrant, nomic, exa). Each is its own PyPI package, e.g. `langchain-anthropic`. Google and AWS integrations live out-of-tree in `langchain-ai/langchain-google` and `langchain-ai/langchain-aws`. See `langchain-partners.md`.
- [`libs/text-splitters/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/text-splitters) — publishes `langchain-text-splitters`. Chunking utilities for ingest pipelines. See `langchain-text-splitters.md`.
- [`libs/standard-tests/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/standard-tests) — publishes `langchain-tests`. Contract test suites partner packages inherit (e.g., `ChatModelUnitTests`, `ChatModelIntegrationTests`). Covered inside `langchain-partners.md`.
- [`libs/model-profiles/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/model-profiles) — publishes `langchain-model-profiles`. CLI tool that fetches model capability metadata (context window, modalities, tool calling, structured output) from upstream models.dev and exposes it as profile JSON for integrations.

There is no `docs/` directory in this repo. Prose documentation lives in the separate `langchain-ai/docs` repo and renders at [docs.langchain.com](https://docs.langchain.com); API reference at [reference.langchain.com/python](https://reference.langchain.com/python).

## The `langchain` vs `langchain-classic` split (read this carefully)

The PyPI package named **`langchain`** is now the *new* agent-first package built from `libs/langchain_v1/`. It declares `langgraph>=1.2.0` as a hard dependency, exposes effectively two public symbols (`create_agent`, `AgentState`), and its README opens with: "LangChain is the easiest way to start building agents." The legacy code is gone from this package; importing old names raises a deprecation warning and points users at `langchain_classic`.

The PyPI package named **`langchain-classic`** is built from `libs/langchain/`. It carries the sprawling 0.x surface: `LLMChain`, `SequentialChain`, `ConversationBufferMemory`, `initialize_agent`, `AgentExecutor`, plus dozens of vectorstore/retriever/document-loader integrations. The Python module name was renamed from `langchain` to `langchain_classic` so the two can coexist. The root `__init__.py` ([libs/langchain/langchain_classic/__init__.py](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain/langchain_classic/__init__.py)) is a deprecation gateway whose only real work is `__getattr__`-warning and re-routing legacy top-level names.

Which to install:

- New project, building an agent: `pip install langchain` → get `create_agent` and middleware.
- Existing 0.x codebase you're maintaining: `pip install langchain-classic` (the legacy module imports become `from langchain_classic.chains import LLMChain`, etc.). No automated codemod exists.
- Both can coexist in the same env (different Python module names), so a partial migration is possible.

There is no in-tree migration guide. The release-policy and versioning pages on docs.langchain.com are the canonical statements; see also [`CLAUDE.md`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/CLAUDE.md) at the repo root for a one-line summary the maintainers wrote for AI-assisted contributors.

## Companion repos

Several repos live outside this tree but are part of the same ecosystem. Each has its own reference in this contextualizer:

- **[langchain-ai/langgraph](https://github.com/langchain-ai/langgraph)** — load-bearing for v1. `create_agent` constructs a LangGraph `StateGraph`; agent execution is graph-node message passing. For any deep question about how an agent actually runs (durable execution, interrupts, checkpointers), the answer is in LangGraph, not in this repo. See `langgraph-overview.md`.
- **[langchain-ai/langsmith-sdk](https://github.com/langchain-ai/langsmith-sdk)** — production tracing, eval, debugging. Both top-level READMEs steer production users here. The Python+JS SDK is also useful standalone via `@traceable` and `wrap_openai`. See `langsmith-sdk-overview.md`.
- **[langchain-ai/deepagents](https://github.com/langchain-ai/deepagents)** — higher-level abstraction layered on `langchain` for agents with planning, subagents, filesystem usage. `create_deep_agent` is the entry point. See `deepagents-overview.md`.
- **[langchain-ai/docs](https://github.com/langchain-ai/docs)** — source of docs.langchain.com (Mintlify MDX). Also home of `packages.yml`, the central registry of every LangChain package across every owning repo. See `docs-overview.md`.
- **[langchain-ai/langchain-google](https://github.com/langchain-ai/langchain-google)** — out-of-tree partner monorepo for Google integrations: `langchain-google-genai` (Gemini API), `langchain-google-vertexai` (GCP Vertex), `langchain-google-community` (Drive/Gmail/BigQuery/etc.). See `langchain-google-overview.md`.
- **[langchain-ai/langchain-aws](https://github.com/langchain-ai/langchain-aws)** — out-of-tree partner monorepo for AWS integrations: `langchain-aws` (Bedrock/SageMaker/Kendra/Neptune/S3-Vectors/AgentCore), `langgraph-checkpoint-aws`, `langchain-agentcore-codeinterpreter`. See `langchain-aws-overview.md`.
- **[langchain-ai/langchainjs](https://github.com/langchain-ai/langchainjs)** — JS/TS port. Coverage in this contextualizer is intentionally a thin pointer: the navigator's `description` drives skill invocation, and a polyglot navigator can't cleanly route JS questions to JS references. The user accepted this companion anyway, so a thin orientation reference exists; for non-trivial JS questions, follow source links into the JS repo and JS docs. See `langchainjs-overview.md`.

## How to navigate from here

Most questions resolve to one of the references below:

- "What's a Runnable / what does `|` do in LangChain?" → `langchain-core-runnables.md`
- "How do I call a chat model / parse its output?" → `langchain-core-models.md`
- "How do I build a RAG pipeline?" → `langchain-core-retrieval.md` (and probably `langchain-text-splitters.md`)
- "How do I trace / stream events?" → `langchain-core-callbacks.md`
- "How do I build an agent?" → `langchain-v1-agents.md`
- "Why is my 0.x code broken / where did `LLMChain` go?" → `langchain-classic.md`
- "How do I add support for provider X?" → `langchain-partners.md`
- "How do I chunk documents for embedding?" → `langchain-text-splitters.md`
