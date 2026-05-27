---
name: langchain-classic
description: The legacy `langchain-classic` package (built from libs/langchain/) — chains, AgentExecutor, memory, and the surface deprecated in v1. Read this when investigating old code, debugging deprecation warnings, or deciding whether to migrate.
---

# langchain-classic: the legacy surface

[`libs/langchain/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain) publishes to PyPI as `langchain-classic` (v1.0.7). The Python module name is `langchain_classic`. This is the home of the entire pre-v1 surface that LangChain accumulated: chains, the AgentExecutor pattern, the memory abstractions, dozens of vectorstore / retriever / document-loader / embedding integrations, and the indexing API.

The package is in maintenance mode. The repo's [`CLAUDE.md`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/CLAUDE.md) describes it as "legacy, no new features." If you have working 0.x code, it should keep working here; if you're starting fresh, use v1 (`langchain-v1-agents.md`).

## How the rename works

The legacy 0.x package was named `langchain`. The v1 rewrite took that name on PyPI, so the legacy surface was moved to `langchain-classic` and the Python import path renamed from `langchain` to `langchain_classic`. Both can be installed in the same environment because they have distinct module names.

For convenience, the new `langchain` package's [`libs/langchain/langchain_classic/__init__.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain/langchain_classic/__init__.py) defines a `__getattr__` that catches top-level legacy imports (`MRKLChain`, `ReActChain`, `SelfAskWithSearchChain`, etc.) and emits a `DeprecationWarning` pointing at the new path. This is how 0.x code surfaces guidance without immediately breaking.

To use legacy chains today: `pip install langchain-classic` and import as `from langchain_classic.chains import LLMChain`.

## Subpackage inventory

Everything below lives under [`libs/langchain/langchain_classic/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain/langchain_classic):

- **`chains/`** — `LLMChain`, `ConversationChain`, `SequentialChain`, `SimpleSequentialChain`, `TransformChain`, `RetrievalQA`, `ConversationalRetrievalChain`, `LLMMathChain`, `MultiPromptChain`, dozens more. All deprecated; the modern replacement is composing Runnables with LCEL.
- **`agents/`** — `Agent`, `AgentExecutor`, `AgentOutputParser`, `BaseSingleActionAgent`, `BaseMultiActionAgent`, plus the `AgentType` enum and the family of named agents (`MRKLChain`, `ReActChain`, `SelfAskWithSearchChain`, `ZeroShotAgent`, `OpenAIFunctionsAgent`, etc.) and `initialize_agent`. Replaced wholesale by `create_agent` in v1.
- **`memory/`** — `ConversationBufferMemory`, `ConversationBufferWindowMemory`, `ConversationSummaryMemory`, `ConversationSummaryBufferMemory`, `ConversationKGMemory`, `EntityMemory`, `VectorStoreRetrieverMemory`, `ReadOnlySharedMemory`. Replaced in v1 by middleware (`summarization.py`, `context_editing.py`) and LangGraph state.
- **`vectorstores/`** — 70+ provider integrations (FAISS, Pinecone, Weaviate, Milvus, Postgres pgvector, Redis, Cassandra, Elasticsearch, OpenSearch, AnalyticDB, AlibabaCloud, etc.). The two newer in-tree partner vectorstores (Chroma, Qdrant) are in `libs/partners/`; everything else stayed here in classic.
- **`retrievers/`** — 48 subdirectories: multi-query, parent-document, contextual compression, ensemble, BM25, time-weighted, Pinecone hybrid, etc.
- **`document_loaders/`** — 149 subdirectories: PDF (multiple parsers), Notion, S3, Google Drive, web scrapers, Confluence, GitHub, Slack, Discord, MongoDB, etc.
- **`embeddings/`** — 53 subdirectories: legacy embedding integrations. New code should prefer the partner-package equivalents (`langchain-openai`, `langchain-nomic`, etc.).
- **`output_parsers/`** — 25+ parsers: the legacy variants. langchain-core has the modern set (see `langchain-core-models.md`).
- **`chat_models/`** — legacy chat-model wrappers, mostly thin re-exports to keep imports working. New code uses partner packages.
- **`callbacks/`** — 34 subdirectories: legacy callback handlers (Aim, WandB, MLflow, Helicone, etc.). Many still functional; LangSmith is the recommended modern path.
- **`indexing.py`** plus the `langchain_classic.indexing` module — the "record manager" abstraction that does incremental re-indexing of document corpora into a vectorstore using content hashes and IDs. This is one of the few non-deprecated, still-recommended classic features for production RAG; see [`libs/langchain/langchain_classic/indexes/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain/langchain_classic/indexes).
- **`runnables/`, `schema/`, `utils/`** — internal glue; mostly re-exports from langchain-core.

## Why chains were deprecated

`LLMChain(prompt=..., llm=..., output_parser=...)` was the original 0.x composition primitive. LCEL replaced it: `prompt | llm | parser` is the same thing, and it composes naturally with everything else. `SequentialChain`, `SimpleSequentialChain`, `TransformChain`, `RouterChain`, etc. all map onto LCEL primitives (`RunnableSequence`, `RunnableParallel`, `RunnableBranch`, `RunnableLambda`). The migration from `LLMChain(...)` to `prompt | llm | parser` is mechanical and produces simpler, more transparent code with the same behavior. For LCEL, see `langchain-core-runnables.md`.

## Why AgentExecutor was deprecated

The 0.x agent stack had two big issues: (1) the agent loop was hard-coded with limited extension points (subclassing `BaseAgent` or providing callbacks), so customizations like retries, fallbacks, summarization, and human-in-the-loop required forking the loop; (2) durable execution, persistence, and streaming weren't first-class — every team rebuilt them. LangGraph (the v1 backend) provides those primitives directly, and `create_agent` exposes a middleware composition model that's strictly more powerful than the old "subclass AgentExecutor" pattern. See `langchain-v1-agents.md` for the replacement.

## Indexing API (still useful)

`langchain_classic.indexes.index(...)` plus a `RecordManager` is the canonical way to keep a vectorstore in sync with an evolving document corpus. It tracks per-document IDs and content hashes, computes the diff against the current index, and issues `add_documents` / `delete` calls accordingly. This is one of the few classic features the docs still steer production users toward — there is no v1 replacement because the concern is orthogonal to the agent rewrite.

Implementation: [`libs/langchain/langchain_classic/indexes/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain/langchain_classic/indexes). The `RecordManager` interface in [`_api.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain/langchain_classic/indexes/_api.py); the SQLite backend in [`base.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain/langchain_classic/indexes/base.py) and SQL-backend implementations.

## langchain-community

A separate PyPI package, `langchain-community`, lives in *another* repo (not in this monorepo). It carries the long tail of provider integrations that didn't get their own partner package. Many imports that used to be `from langchain.X import Y` now resolve to `langchain_community.X.Y`. If you hit "cannot import name from langchain_classic," check `langchain-community`.

## Migration path

There is no automated codemod. The pragmatic playbook:

1. Replace `LLMChain` / `SequentialChain` / `RouterChain` etc. with LCEL pipelines. Mechanical.
2. Replace `initialize_agent + AgentExecutor + memory + callbacks` with `create_agent(model, tools, middleware=[...])`. See `langchain-v1-agents.md` for the middleware catalog.
3. Keep vectorstore / retriever / document_loader code as-is if it works; only the chain layer above changes.
4. Keep `langchain_classic.indexes` as-is — no replacement, still production-recommended.
5. Both packages can coexist during migration; the imports are namespaced.

For specifics by topic the docs site (`langchain-ai/docs` repo, rendered at docs.langchain.com) carries per-class migration notes that are too granular to mirror here.

## Gotchas

- `from langchain import LLMChain` still works in `langchain-classic` via the `__getattr__` shim but emits a deprecation warning; it's `from langchain_classic.chains import LLMChain` properly.
- Some legacy vectorstore integrations have been gradually moved to `langchain-community`; if an import fails, check both `langchain_classic.vectorstores` and `langchain_community.vectorstores`.
- Memory objects don't compose cleanly with LCEL — they predate the Runnable protocol. Wrapping them in `RunnableLambda` works but is ugly; treat memory as a migration target rather than a long-term shape.
- Deprecation warnings can be loud in dev environments; the package suppresses them in interactive REPLs (Jupyter, IPython) but not in scripts. Filter with `warnings.filterwarnings("ignore", category=DeprecationWarning, module="langchain_classic.*")` if needed for prod logs.
