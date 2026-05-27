---
name: langchainjs-overview
description: Companion repo langchain-ai/langchainjs — the JavaScript/TypeScript port of LangChain. The rest of this contextualizer is Python-first; this reference is intentionally a thin pointer for orienting JS questions, not deep coverage.
---

# LangChain.js (companion repo, thin coverage)

LangChain.js at [langchain-ai/langchainjs](https://github.com/langchain-ai/langchainjs/tree/dd4a1d6cc5a1f9dc3fc9f2da17e807e311fc6b1d) is the TypeScript counterpart of the Python `langchain` framework. The two stay roughly aligned in concepts (Runnables/LCEL, models, tools, retrievers, agents) but are independently developed: separate release cadence, separate API surface details, and per-language gotchas.

> **Coverage note.** The rest of this contextualizer covers Python (`langchain-ai/langchain` and its companion repos). This reference is intentionally a thin orientation pointer rather than a full per-package walkthrough. Why: the navigator's `description` field is what drives skill invocation, and a polyglot navigator has no clean way to route a JS-only question to JS-only references and a Python-only question to Python-only references — the engine recommended rejecting this companion at proposal time for that reason. The user accepted it anyway, so a reference exists; but for any non-trivial JS question, follow the source links below into the JS repo and docs rather than expecting depth here.

## When to use this reference

- "Where does the JS port live?" → here.
- "Which JS packages exist? What's the JS equivalent of `langchain-anthropic`?" → here, and the table below.
- "Which JS runtimes does it support?" → here (Node 20+, Cloudflare Workers, Vercel/Next.js, Supabase Edge, Deno, Bun, browser).
- Anything API-shaped ("how do I write a JS chain", "what's the right import path for `ChatOpenAI` in TS"), follow the docs link below; the per-package surface drifts faster than this reference can track.

## Repo layout

A pnpm/Turborepo monorepo. Three top-level package categories under `libs/`:

- [`libs/langchain/`](https://github.com/langchain-ai/langchainjs/tree/dd4a1d6cc5a1f9dc3fc9f2da17e807e311fc6b1d/libs/langchain) — publishes [`langchain`](https://www.npmjs.com/package/langchain) (v1.4.3). The main package: agents, prompts, chains, hub.
- [`libs/langchain-core/`](https://github.com/langchain-ai/langchainjs/tree/dd4a1d6cc5a1f9dc3fc9f2da17e807e311fc6b1d/libs/langchain-core) — publishes [`@langchain/core`](https://www.npmjs.com/package/@langchain/core) (v1.1.48). Core abstractions: Runnable, BaseMessage, BaseChatModel, BaseRetriever, callbacks. The Python parallel is `langchain-core`.
- [`libs/langchain-classic/`](https://github.com/langchain-ai/langchainjs/tree/dd4a1d6cc5a1f9dc3fc9f2da17e807e311fc6b1d/libs/langchain-classic) — publishes [`@langchain/classic`](https://www.npmjs.com/package/@langchain/classic) (v1.0.34). The legacy chains/agents surface, mirroring Python's `langchain-classic`.
- [`libs/langchain-textsplitters/`](https://github.com/langchain-ai/langchainjs/tree/dd4a1d6cc5a1f9dc3fc9f2da17e807e311fc6b1d/libs/langchain-textsplitters) — publishes [`@langchain/textsplitters`](https://www.npmjs.com/package/@langchain/textsplitters). Mirrors Python's `langchain-text-splitters`.
- [`libs/langchain-mcp-adapters/`](https://github.com/langchain-ai/langchainjs/tree/dd4a1d6cc5a1f9dc3fc9f2da17e807e311fc6b1d/libs/langchain-mcp-adapters) — publishes [`@langchain/mcp-adapters`](https://www.npmjs.com/package/@langchain/mcp-adapters) (v1.1.3). MCP tool integration. Python has [`langchain-mcp-adapters`](https://github.com/langchain-ai/langchain-mcp-adapters) as a separate repo.
- [`libs/providers/`](https://github.com/langchain-ai/langchainjs/tree/dd4a1d6cc5a1f9dc3fc9f2da17e807e311fc6b1d/libs/providers) — first-party provider integrations. ~30 packages including `langchain-anthropic`, `langchain-openai`, `langchain-google-*` (split into `genai`, `vertexai`, `vertexai-web`, `cloud-sql-pg`, etc.), `langchain-aws`, `langchain-cohere`, `langchain-mistralai`, `langchain-ollama`, `langchain-pinecone`, `langchain-mongodb`, `langchain-pgvector`, `langchain-qdrant`, `langchain-redis`, `langchain-weaviate`, `langchain-tavily`, plus more. Each publishes as `@langchain/<name>`.

There is no separate `libs/langchain_v1/` directory in JS — the JS `langchain` package version is the equivalent of Python's v1 surface, and `@langchain/classic` is the legacy split.

## Python ↔ JS package mapping

For the most common packages, the rough correspondence is:

| Python | JS / npm |
| --- | --- |
| `langchain` (v1) | `langchain` (v1) |
| `langchain-classic` | `@langchain/classic` |
| `langchain-core` | `@langchain/core` |
| `langchain-text-splitters` | `@langchain/textsplitters` |
| `langchain-anthropic` | `@langchain/anthropic` |
| `langchain-openai` | `@langchain/openai` |
| `langchain-google-genai` | `@langchain/google-genai` |
| `langchain-google-vertexai` | `@langchain/google-vertexai` |
| `langchain-aws` | `@langchain/aws` |
| `langchain-mcp-adapters` | `@langchain/mcp-adapters` |

The complete cross-language registry is in [`packages.yml`](https://github.com/langchain-ai/docs/blob/a623fd54dca3b37d00e004ea6feda5ec338eab67/packages.yml) in the docs repo — the `js:` field on each Python entry points at the corresponding npm package. See [`docs-overview.md`](docs-overview.md) for more on `packages.yml`.

## Companion JS repos

Python has dedicated companions for LangGraph, LangSmith, and Deep Agents; JS has the equivalents in separate repos:

- [`langchain-ai/langgraphjs`](https://github.com/langchain-ai/langgraphjs) — LangGraph.js. Same role as Python's [`langgraph`](langgraph-overview.md): low-level orchestration, durable execution, checkpointers.
- [`langsmith-sdk`](https://github.com/langchain-ai/langsmith-sdk) `js/` directory — the JS LangSmith SDK ships from the same monorepo as the Python SDK; see [`langsmith-sdk-overview.md`](langsmith-sdk-overview.md).
- [`langchain-ai/deepagentsjs`](https://github.com/langchain-ai/deepagentsjs) — Deep Agents JS. Same role as Python's [`deepagents`](deepagents-overview.md).

## Where to go for non-trivial JS questions

This reference is intentionally shallow. For deeper material:

- [docs.langchain.com/oss/javascript/langchain/overview](https://docs.langchain.com/oss/javascript/langchain/overview) — JS overview docs.
- [docs.langchain.com/oss/javascript/langgraph/overview](https://docs.langchain.com/oss/javascript/langgraph/overview) — LangGraph.js docs.
- [reference.langchain.com/javascript](https://reference.langchain.com/javascript/) — auto-generated JS API reference.
- [`AGENTS.md`](https://github.com/langchain-ai/langchainjs/blob/dd4a1d6cc5a1f9dc3fc9f2da17e807e311fc6b1d/AGENTS.md) at the JS repo root has the dependency map, supported environments, and developer commands (pnpm + Turborepo, build core first).
- [`CONTRIBUTING.md`](https://github.com/langchain-ai/langchainjs/blob/dd4a1d6cc5a1f9dc3fc9f2da17e807e311fc6b1d/CONTRIBUTING.md) for the contribution flow.
