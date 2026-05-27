---
name: langchain-core-retrieval
description: Documents, retrievers, vector stores, embeddings, and document loaders — the RAG building blocks. Read this for any question about Document, BaseRetriever, VectorStore, similarity search, MMR, Embeddings, BaseDocumentLoader, or how to wire a RAG pipeline.
---

# langchain-core: retrieval and RAG primitives

The retrieval surface in langchain-core is intentionally thin: a few base classes that any concrete vector DB, embedding model, or document loader implements. The interesting integrations (Chroma, Qdrant, FAISS, Postgres pgvector, Pinecone, etc.) live in partner packages or in `langchain_classic.vectorstores` for the legacy implementations. This reference covers the base abstractions and the patterns; for a specific provider, the entry point is "find its partner package and read its `vectorstores.py` or `embeddings.py`."

## Documents

`Document` ([`libs/core/langchain_core/documents/base.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/documents/base.py)) is the unit of retrieval. Two fields:

- `page_content: str` — the text.
- `metadata: dict[str, Any]` — anything you want to filter on or display (source URL, chunk index, timestamps, doc ID, etc.).

`Blob` (same file) is the binary-content counterpart used by document loaders that parse PDFs, images, etc. before producing `Document`s.

Identity matters when you re-index: a `Document` with a stable ID lets a vectorstore upsert rather than duplicate. The `id` field is optional but encouraged for any pipeline that reruns. The companion `langchain.indexing` API (in `langchain-classic`) uses these IDs plus content-hash to do incremental re-indexing — see `langchain-classic.md` for that surface.

## Retrievers

`BaseRetriever` ([`libs/core/langchain_core/retrievers.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/retrievers.py)) is a Runnable from `str` (the query) to `list[Document]`. Subclasses implement `_get_relevant_documents(query, run_manager)` (sync) and/or `_aget_relevant_documents(...)` (async). Every concrete retriever — `VectorStoreRetriever`, BM25, Cohere rerank, multi-query, ensemble, parent-document — subclasses this.

Because `BaseRetriever` is a Runnable, it slots straight into LCEL pipelines: `{"context": retriever, "question": RunnablePassthrough()} | prompt | model` is the canonical RAG shape. The retriever takes the question string, returns documents; the prompt template formats them into context.

Retrieval config typically lives on the retriever instance, not in the call: `vector_store.as_retriever(search_type="mmr", search_kwargs={"k": 6, "fetch_k": 30})` returns a `VectorStoreRetriever` with those parameters baked in.

## Vector stores

`VectorStore` ([`libs/core/langchain_core/vectorstores/base.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/vectorstores/base.py)) is the contract a vector DB integration implements. Key methods:

- `add_documents(documents, **kwargs) -> list[str]` — embed + write, return doc IDs.
- `add_texts(texts, metadatas, **kwargs) -> list[str]` — text-only convenience.
- `similarity_search(query, k=4, **kwargs) -> list[Document]` — top-k by similarity.
- `similarity_search_with_score(...) -> list[tuple[Document, float]]`.
- `max_marginal_relevance_search(query, k=4, fetch_k=20, lambda_mult=0.5, ...)` — MMR for diversity.
- `as_retriever(search_type=..., search_kwargs=...)` — returns a `VectorStoreRetriever` wrapping this store.
- Classmethods `from_documents` / `from_texts` for one-shot index construction.

The base class provides default implementations for many methods so partners typically only implement the embed/store/search/delete primitives. Filter syntax for `similarity_search(filter=...)` is partner-specific — each integration's docs spell out the supported predicate shape (e.g., Chroma uses a Mongo-style dict, Postgres pgvector uses SQL).

The in-tree vector store integrations live in `libs/partners/chroma/` and `libs/partners/qdrant/`. The legacy bulk of vectorstore integrations (FAISS, Pinecone, Weaviate, Milvus, etc.) lives in `langchain_classic.vectorstores` — see `langchain-classic.md`. New code should prefer either an in-tree partner or `langchain-community` (a separate PyPI package, not in this repo).

## Embeddings

`Embeddings` ([`libs/core/langchain_core/embeddings/embeddings.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/embeddings/embeddings.py)) is the simplest of the contracts:

- `embed_documents(texts: list[str]) -> list[list[float]]` — batched embedding for indexing.
- `embed_query(text: str) -> list[float]` — single embedding for query-side use.

Why two methods? Some providers offer asymmetric models (different model variant or different query-vs-doc prefix). The base class lets partners distinguish even when the underlying vectors are the same.

Concrete embeddings live in partner packages: `OpenAIEmbeddings` in `langchain-openai`, `OllamaEmbeddings` in `langchain-ollama`, `NomicEmbeddings` in `langchain-nomic`, etc. A factory analogous to `init_chat_model` does not exist in v1 for embeddings — instantiate the partner class directly.

`CacheBackedEmbeddings` ([`libs/core/langchain_core/embeddings/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/embeddings) module also carries this wrapper) layers a key-value cache in front of an embeddings instance — useful in dev to avoid re-embedding identical chunks.

## Document loaders

`BaseDocumentLoader` ([`libs/core/langchain_core/document_loaders/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/document_loaders)) is the abstraction for "turn an input source into a stream of `Document`s." Methods: `load()` returns a list eagerly; `lazy_load()` returns an iterator; `aload()` / `alazy_load()` are the async versions.

The concrete loaders for files, websites, S3, Notion, etc. live overwhelmingly in `langchain_classic.document_loaders` and `langchain-community`. In-tree, only the abstract layer is here.

## A complete RAG pipeline

A typical retrieval-augmented chain composes the pieces with LCEL:

```python
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.runnables import RunnablePassthrough
from langchain_core.output_parsers import StrOutputParser

retriever = vector_store.as_retriever(search_kwargs={"k": 4})
prompt = ChatPromptTemplate.from_template("Answer based on context:\n{context}\n\nQ: {question}")

chain = (
    {"context": retriever, "question": RunnablePassthrough()}
    | prompt
    | chat_model
    | StrOutputParser()
)
chain.invoke("What is X?")
```

`retriever` is a Runnable from `str` to `list[Document]`; passing it directly into a `RunnableParallel` produces the `context` value. The prompt template's f-string substitution accepts the document list and calls `repr` — for nicer formatting, slot a `format_docs` `RunnableLambda` in between, or use a `ChatPromptTemplate` with explicit `MessagesPlaceholder`.

## Gotchas

- `Document.metadata` keys must be JSON-serializable for most vectorstore backends; nested dicts and arbitrary objects break write paths in providers like Chroma.
- MMR (`max_marginal_relevance_search`) needs `fetch_k > k`; the over-fetch budget is what drives diversity.
- Embedding caches (`CacheBackedEmbeddings`) key on the text content; if you re-embed with a different model the cache silently returns the wrong vectors unless you scope the cache namespace per model.
- `BaseRetriever.invoke` accepts a single string and returns `list[Document]`; passing a list of strings does NOT batch — use `retriever.batch([q1, q2])`.
- The vector store API does not enforce a tenancy model; multi-tenant isolation lives in your filter conventions.

For ingestion-side chunking (the typical step before `add_documents`), see `langchain-text-splitters.md`.
