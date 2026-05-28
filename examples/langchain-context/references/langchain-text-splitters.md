# langchain-text-splitters

[`libs/text-splitters/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/text-splitters) publishes `langchain-text-splitters` — a small, focused package whose only job is turning long text or `Document` objects into chunk-sized pieces suitable for embedding, retrieval, or LLM context windows. It is a peer of `langchain-core` rather than a subset of it: depending on `langchain-text-splitters` is cheap (no provider SDKs), so it can be pulled into ingest jobs that don't need the rest of LangChain.

## The protocol

The base class [`TextSplitter`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/text-splitters/langchain_text_splitters/base.py) defines two surfaces:

- `split_text(text: str) -> list[str]` — abstract; each subclass implements its splitting strategy.
- `split_documents(documents: list[Document]) -> list[Document]` — concrete; walks each input document, calls `split_text` on its `page_content`, and copies the source metadata onto each output chunk (plus appends chunk-position metadata if the splitter tracks it).

The constructor takes `chunk_size` and `chunk_overlap` (in whatever unit the subclass uses — characters, tokens, structural units), plus `length_function` (defaults to `len`), `keep_separator`, `add_start_index`, and a few other knobs.

Two utility types live in `base.py`: `Language` (the enum of supported code languages for `RecursiveCharacterTextSplitter.from_language(...)`), `Tokenizer` (a structural type for token-based splitters), and `TokenTextSplitter` (HuggingFace `tokenizers`-style splitter base).

## The splitters you'll actually use

**`RecursiveCharacterTextSplitter`** ([`character.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/text-splitters/langchain_text_splitters/character.py)) — the workhorse. It splits on a list of separators in priority order, recursing into chunks that are still too large. Defaults to `["\n\n", "\n", " ", ""]`, which gives paragraph-then-line-then-word-then-character fallback. Best general-purpose splitter for prose. Use `.from_language(language=Language.PYTHON, ...)` to get a separator list tuned for that language's structural boundaries (class/def/keyword markers for Python; `</tag>` and friends for HTML; etc.).

**`CharacterTextSplitter`** (same file) — splits on a single separator string. Simpler, less smart. Use only when you need exact control.

**`TokenTextSplitter`** ([`base.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/text-splitters/langchain_text_splitters/base.py)) — splits by token count using a `Tokenizer` (encode-only structural type — pass any compatible tokenizer, e.g., `tiktoken`'s). The right choice when chunk sizes need to align with LLM context limits.

**`SentenceTransformersTokenTextSplitter`** ([`sentence_transformers.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/text-splitters/langchain_text_splitters/sentence_transformers.py)) — token-based but specifically for sentence-transformer embeddings; respects the model's max sequence length.

**`MarkdownHeaderTextSplitter`** ([`markdown.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/text-splitters/langchain_text_splitters/markdown.py)) — splits on Markdown `#`/`##`/`###` headers, preserving header context in metadata. NOT a subclass of `TextSplitter` — it returns `Document` objects directly, not strings. Pair with `RecursiveCharacterTextSplitter` afterward to enforce a chunk size cap within each section.

**`MarkdownTextSplitter`** (same file) — the simpler form: `RecursiveCharacterTextSplitter` pre-tuned with Markdown-aware separators.

**`HTMLHeaderTextSplitter`, `HTMLSectionSplitter`, `HTMLSemanticPreservingSplitter`** ([`html.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/text-splitters/langchain_text_splitters/html.py)) — HTML-aware splitters. `HTMLHeaderTextSplitter` is the analog of the Markdown header splitter; `HTMLSemanticPreservingSplitter` is the most aggressive at keeping structural elements intact.

**`RecursiveJsonSplitter`** ([`json.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/text-splitters/langchain_text_splitters/json.py)) — splits JSON documents along object/array boundaries; preserves valid JSON in each chunk.

**`PythonCodeTextSplitter`** ([`python.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/text-splitters/langchain_text_splitters/python.py)) — pre-configured `RecursiveCharacterTextSplitter` with Python separators (`\nclass `, `\ndef `, `\n\tdef `, etc.).

**`LatexTextSplitter`** ([`latex.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/text-splitters/langchain_text_splitters/latex.py)), **`JSFrameworkTextSplitter`** ([`jsx.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/text-splitters/langchain_text_splitters/jsx.py)) — niche but useful when the corpus is LaTeX or JSX.

**`NLTKTextSplitter`, `SpacyTextSplitter`, `KonlpyTextSplitter`** — sentence-boundary splitters backed by NLTK / spaCy / KoNLPy respectively. Pulls in those tokenizer dependencies; use only if you need NLP-grade sentence boundaries.

## Picking a splitter

Quick decision guide:

- General prose / unknown structure → `RecursiveCharacterTextSplitter` with defaults.
- Need exact LLM-token-count chunks → `TokenTextSplitter` with `tiktoken` (for OpenAI models) or `SentenceTransformersTokenTextSplitter` (for sentence-transformer embeddings).
- Markdown corpus, want section-aware retrieval → `MarkdownHeaderTextSplitter` first (for section metadata), then `RecursiveCharacterTextSplitter` per section to cap size.
- HTML corpus → analogous: `HTMLSemanticPreservingSplitter`, then size-cap.
- Code corpus → `RecursiveCharacterTextSplitter.from_language(language=Language.X)`.
- JSON corpus → `RecursiveJsonSplitter`.
- NLP-grade sentence boundaries needed → `NLTKTextSplitter` or `SpacyTextSplitter`.

`chunk_size` and `chunk_overlap` tuning is empirical. Common defaults: `chunk_size=1000`, `chunk_overlap=200` characters for `RecursiveCharacterTextSplitter` against generic prose; for token-based splitters scale to your embedding model's max context (most retrieval embeddings cap at 512 or 8192 tokens).

## Position in the pipeline

A typical ingest looks like:

```python
loader = SomeDocumentLoader(...)            # → list[Document]
docs = loader.load()
splitter = RecursiveCharacterTextSplitter(chunk_size=1000, chunk_overlap=200)
chunks = splitter.split_documents(docs)     # → list[Document]
vector_store.add_documents(chunks)
```

Document loaders typically live in `langchain_classic.document_loaders` or `langchain-community` (see `langchain-classic.md`); vectorstore primitives live in `langchain-core` with concrete partners (see `langchain-core-retrieval.md`). `langchain-text-splitters` is the middle step that lets the loader output and the vectorstore input agree on chunk size.

## Gotchas

- `MarkdownHeaderTextSplitter` and `HTMLHeaderTextSplitter` do NOT subclass `TextSplitter` — they return `Document` objects directly. This is called out in the package's [`__init__.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/text-splitters/langchain_text_splitters/__init__.py) docstring. They also do NOT respect `chunk_size`; chain them with a regular splitter if size caps matter.
- `chunk_overlap` is measured in the same units as `chunk_size` — characters for character splitters, tokens for token splitters. Overlap > chunk_size produces an error.
- Token splitters need an explicit `Tokenizer`; the default isn't a real one. For OpenAI-compatible models, install `tiktoken` and use `TokenTextSplitter.from_tiktoken_encoder(encoding_name="cl100k_base", ...)`.
- `add_start_index=True` annotates each chunk with its source-document offset under `metadata["start_index"]` — useful for highlighting retrieval results back in the source.
- Splitting code with `from_language` is best-effort: indentation-sensitive languages (Python) split cleaner than brace languages (JavaScript) because `\ndef` / `\nclass` separators land on real structural boundaries; brace-language splitters fall back to looser heuristics.
