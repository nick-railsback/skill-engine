---
name: langchain-context
description: "Answers questions about the LangChain Python ecosystem — the langchain-ai/langchain monorepo (langchain-core, v1 agents, langchain-classic, in-tree partners, text-splitters) plus companion repos LangGraph, LangSmith SDK, Deep Agents, out-of-tree partner monorepos langchain-google and langchain-aws, and the docs.langchain.com source. Includes a thin orientation pointer for the LangChain.js port. References load on demand from references/."
---

# LangChain context navigator

## Overview

This navigator covers the **LangChain Python ecosystem** in depth, plus a thin orientation pointer for the JS port:

- **Primary**: the [langchain-ai/langchain](https://github.com/langchain-ai/langchain) Python monorepo — `langchain-core`, the new `langchain` package (v1; built from `libs/langchain_v1/`), the legacy `langchain-classic` package (built from `libs/langchain/`), in-tree partner integrations, and the auxiliary libs (text-splitters, model-profiles, standard-tests).
- **Python companion repos**: LangGraph (`langchain-ai/langgraph`), LangSmith SDK (`langchain-ai/langsmith-sdk`), Deep Agents (`langchain-ai/deepagents`), and the out-of-tree partner monorepos `langchain-ai/langchain-google` and `langchain-ai/langchain-aws`. Plus the docs source at `langchain-ai/docs`.
- **JS port (thin coverage only)**: `langchain-ai/langchainjs` is included as a pointer reference for orienting JS questions — full JS depth is out of scope; follow source links into the JS repo for non-trivial questions.

When asked a question this navigator's domain covers:

1. Scan the **Catalog** below for the matching topic.
2. Follow the link to read the reference file.
3. If the question spans multiple references, consult the **Cross-reference map**.
4. If a reference points at a source URL for deeper detail, follow it only if the reference itself didn't answer the question.

For first-time orientation — what packages exist, how `langchain` vs `langchain-classic` differ, where companion repos live — start with `langchain-overview.md`.

## Catalog

### Main monorepo (`langchain-ai/langchain`)

| Reference | Description |
|---|---|
| [langchain-overview](references/langchain-overview.md) | Monorepo layout, `langchain` vs `langchain-classic` split, where every companion repo lives. |
| [langchain-core-runnables](references/langchain-core-runnables.md) | The Runnable protocol and LCEL — `\|` pipe, `.bind`, `.with_config`, RunnableSequence/Parallel/Lambda/Branch, streaming events. |
| [langchain-core-models](references/langchain-core-models.md) | Chat models, LLMs, messages (Human/AI/System/Tool), tools and `bind_tools`, prompts, output parsers, structured output. |
| [langchain-core-retrieval](references/langchain-core-retrieval.md) | Documents, BaseRetriever, VectorStore, similarity search / MMR, Embeddings, document loaders, RAG pipelines. |
| [langchain-core-callbacks](references/langchain-core-callbacks.md) | Callback handlers, tracers, `astream_events` v2, LangSmith integration, run trees, streaming protocol. |
| [langchain-v1-agents](references/langchain-v1-agents.md) | The v1 agent API: `create_agent`, the middleware system, `AgentState`, `init_chat_model`, LangGraph backend. |
| [langchain-classic](references/langchain-classic.md) | The legacy `langchain-classic` package: chains, AgentExecutor, memory, indexing API, and what's deprecated. |
| [langchain-partners](references/langchain-partners.md) | In-tree partner integration packages (anthropic, openai, etc.), the chat-model contract, `langchain-tests` standard suite. |
| [langchain-text-splitters](references/langchain-text-splitters.md) | `langchain-text-splitters`: `RecursiveCharacterTextSplitter`, token splitters, Markdown/HTML/JSON/code splitters. |

### Python companion repos

| Reference | Description |
|---|---|
| [langgraph-overview](references/langgraph-overview.md) | `langchain-ai/langgraph` — `StateGraph`, checkpointers, prebuilt helpers, the SDK and CLI, and how it relates to `langchain.create_agent`. |
| [langsmith-sdk-overview](references/langsmith-sdk-overview.md) | `langchain-ai/langsmith-sdk` — the `langsmith` package: `@traceable`, framework wrappers (`wrap_openai` etc.), `Client`, `evaluate`, and the env-var-only LangChain integration. |
| [deepagents-overview](references/deepagents-overview.md) | `langchain-ai/deepagents` — `create_deep_agent` (planning, filesystem, shell, sub-agent tools), pluggable sandbox backends, the `deepagents-cli`. |
| [langchain-google-overview](references/langchain-google-overview.md) | `langchain-ai/langchain-google` — out-of-tree partner monorepo: `langchain-google-genai` (Gemini API), `langchain-google-vertexai` (GCP Vertex), `langchain-google-community` (Drive/Gmail/BigQuery/etc.). |
| [langchain-aws-overview](references/langchain-aws-overview.md) | `langchain-ai/langchain-aws` — out-of-tree partner monorepo: `langchain-aws` (Bedrock/SageMaker/Kendra/Neptune/S3-Vectors/AgentCore), `langgraph-checkpoint-aws`, `langchain-agentcore-codeinterpreter`. |
| [docs-overview](references/docs-overview.md) | `langchain-ai/docs` — source for `docs.langchain.com` (Mintlify MDX); also the home of `packages.yml`, the central registry of every LangChain package across every owning repo. |

### JS port (thin pointer only)

| Reference | Description |
|---|---|
| [langchainjs-overview](references/langchainjs-overview.md) | `langchain-ai/langchainjs` — orientation pointer for the TypeScript port. Lists the npm package mapping; defers depth to the JS docs. |

## Cross-reference map

- **Building a RAG pipeline** → start at `langchain-core-retrieval` for the protocol shape; cross to `langchain-text-splitters` for the chunking step and `langchain-core-runnables` for composing the prompt-model-parser tail with LCEL.
- **Building an agent** → start at `langchain-v1-agents` for `create_agent` and middleware; cross to `langchain-core-models` for tool definitions and structured output, to `langgraph-overview` for the underlying graph runtime (`create_agent` returns a `StateGraph`), and to `langchain-classic` only if the user has 0.x `AgentExecutor` code to migrate.
- **Building a "batteries-included" agent (planning, filesystem, sub-agents)** → start at `deepagents-overview` for `create_deep_agent`; cross to `langchain-v1-agents` for the underlying `create_agent` it composes with, and to `langgraph-overview` for streaming/persistence.
- **Durable agents / pause-resume / human-in-the-loop / checkpoints** → start at `langgraph-overview` for the LangGraph checkpoint and interrupt surface (the `langchain` repo doesn't implement these — LangGraph does). For AWS-managed checkpoint backends specifically, cross to `langchain-aws-overview` (`langgraph-checkpoint-aws`).
- **Adding support for a new model provider** → start at `langchain-partners` for the in-tree package layout; cross to `langchain-core-models` for the `BaseChatModel` contract details. For Google or AWS specifically, those are out-of-tree — see `langchain-google-overview` or `langchain-aws-overview`.
- **Observability / tracing / streaming UI** → start at `langchain-core-callbacks` for the event surface; cross to `langchain-core-runnables` for how `astream_events` is wired into the Runnable protocol. For LangSmith specifically — when you'd reach for the SDK directly vs. let env vars do the work — cross to `langsmith-sdk-overview`.
- **Migrating 0.x code** → start at `langchain-classic` for what moved where; cross to `langchain-v1-agents` for the v1 replacement of `initialize_agent + AgentExecutor + memory`, and to `langgraph-overview` if the user is asking about graph-level customization the v1 agent surface doesn't expose.
- **"Why is `LLMChain` deprecated / what replaces it"** → start at `langchain-classic`; cross to `langchain-core-runnables` for the LCEL replacement pattern.
- **"Where is the docs page for X / where do I file a docs issue"** → start at `docs-overview` for the docs.langchain.com source layout, the `packages.yml` registry, and the distinction between docs.langchain.com vs. reference.langchain.com.
- **"What's the JS equivalent of <Python class>"** → start at `langchainjs-overview` for the npm package mapping; for non-trivial JS questions follow the source links into the JS repo and JS docs.

## Instructions to Claude

When loading a reference file, the path syntax depends on the platform:

* **Claude Code**: Read the reference using the platform-provided skill-directory variable:
  `Read $CLAUDE_SKILL_DIR/references/<source-slug>-<topic>.md`

* **Claude Desktop**: Read the reference using a relative path; the platform resolves it from the skill's installed location:
  `Read references/<source-slug>-<topic>.md`

Loading rules:

* Load one reference at a time unless the Cross-reference map says to load both.
* If the primary reference doesn't fully answer the question, follow any source URL pointers it provides for deeper detail.
* Do not eagerly load companion files; only follow companion links when the primary reference says to.
* If the user's question is clearly out of scope for this contextualizer, don't invoke this skill at all.
* The repo's two same-looking package directories (`libs/langchain/` and `libs/langchain_v1/`) publish to PyPI under different names (`langchain-classic` and `langchain` respectively). Always disambiguate when discussing them — `langchain-overview` and the first sections of `langchain-v1-agents` and `langchain-classic` cover this.

## Progressive disclosure

References prioritize curated insight over re-specifying upstream sources:

* **Gotchas, cross-system patterns, and "why" context** are kept in the reference (curation value).
* **Exact schemas, API signatures, and parameter lists** are summarized in the reference and linked to their authoritative source via SHA-pinned URLs.

When a reference includes a source URL pointer, follow it only when the reference's own summary didn't cover the question. The contextualizer is optimized for the common case; the upstream source is the long tail.

File URLs in references are pinned to per-source SHAs at the time of the last `/skill-engine:refresh` run (2026-05-18). Each reference's links point at the SHA captured when that source was discovered. Run `/skill-engine:refresh` to re-pin against current HEAD across all sources. Per-source SHAs are recorded in [`research/source-paths.json`](research/source-paths.json).
