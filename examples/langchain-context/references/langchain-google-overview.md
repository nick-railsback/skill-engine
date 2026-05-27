---
name: langchain-google-overview
description: Companion repo langchain-ai/langchain-google — out-of-tree partner monorepo for Google integrations. Hosts langchain-google-genai (Gemini API), langchain-google-vertexai (Vertex AI), and langchain-google-community (everything else Google).
---

# langchain-google (companion repo)

[langchain-ai/langchain-google](https://github.com/langchain-ai/langchain-google/tree/b86ee2fccd97b8afbea6850c8c23df45c8d44894) is a partner-integration monorepo that lives **outside** the main `langchain-ai/langchain` tree. It exists for the same reason `langchain-ai/langchain-aws` does: Google's surface area is wide enough — three independently versioned packages, four if you count the JS port — that bundling it in the main monorepo would force lockstep releases on integrations that move at different tempos. The in-tree [`libs/partners/README.md`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/partners/README.md) calls this out: Google integrations were moved out for independent versioning. The contextualizer's [`langchain-partners.md`](langchain-partners.md) covers the in-tree partner pattern; this reference covers the Google split.

## Repo layout

Three Python packages under `libs/`:

- [`libs/genai/`](https://github.com/langchain-ai/langchain-google/tree/b86ee2fccd97b8afbea6850c8c23df45c8d44894/libs/genai) — publishes [`langchain-google-genai`](https://pypi.org/project/langchain-google-genai/) (v4.2.3). Integrations for **Google Generative AI (Gemini API)** — the consumer-facing developer-API track at [ai.google.dev](https://ai.google.dev/). Backed by the `google-genai>=1.65.0` SDK. Public surface: `ChatGoogleGenerativeAI`, `GoogleGenerativeAI` (the LLM class), `GoogleGenerativeAIEmbeddings`. Source files in [`langchain_google_genai/`](https://github.com/langchain-ai/langchain-google/tree/b86ee2fccd97b8afbea6850c8c23df45c8d44894/libs/genai/langchain_google_genai) — `chat_models.py`, `llms.py`, `embeddings.py`, plus internal helpers for function-calling, image utilities, and enum mapping.
- [`libs/vertexai/`](https://github.com/langchain-ai/langchain-google/tree/b86ee2fccd97b8afbea6850c8c23df45c8d44894/libs/vertexai) — publishes [`langchain-google-vertexai`](https://pypi.org/project/langchain-google-vertexai/) (v3.2.3). Integrations for **Google Cloud Vertex AI** — the GCP-platform track. Backed by `google-cloud-aiplatform>=1.97.0`. Same broad shape as the genai package (chat models, LLMs, embeddings) but routed through Vertex endpoints, with the auth and project/region setup that GCP requires.
- [`libs/community/`](https://github.com/langchain-ai/langchain-google/tree/b86ee2fccd97b8afbea6850c8c23df45c8d44894/libs/community) — publishes [`langchain-google-community`](https://pypi.org/project/langchain-google-community/) (v4.0.0). The catch-all for "everything else Google": Drive loaders, Gmail toolkit, BigQuery, Cloud Storage, Discovery Engine, Vertex AI Search, Speech-to-Text, etc. Pulls in `langchain-community`, `langgraph`, and the broader Google API client surface.

Plus a [`terraform/`](https://github.com/langchain-ai/langchain-google/tree/b86ee2fccd97b8afbea6850c8c23df45c8d44894/terraform) directory that holds CI/CD scaffolding for the repo itself (Cloud Build, GitHub connection, secrets) — not user-facing.

## Choosing the right package

The two model-serving packages overlap in capability but target different deployment paths. The decision is mostly an account-and-billing question:

- **`langchain-google-genai`** if you have a Gemini API key from [ai.google.dev](https://ai.google.dev/), no GCP project setup, and want the simplest path. Free tier exists. Chat models named `ChatGoogleGenerativeAI`.
- **`langchain-google-vertexai`** if you're already on GCP, need IAM/VPC controls, region pinning, or enterprise SLAs, or want access to non-Gemini Vertex models. Chat models named `ChatVertexAI`.
- **`langchain-google-community`** is additive — install it alongside one of the above when you need the broader Google product integrations (Drive, Gmail, BigQuery, etc.).

Same Gemini model can be reached through either of the first two packages; the difference is the auth path and the SDK doing the work.

## Versioning and dependency pins

Each package versions independently. Notable pins from the [`libs/genai/pyproject.toml`](https://github.com/langchain-ai/langchain-google/blob/b86ee2fccd97b8afbea6850c8c23df45c8d44894/libs/genai/pyproject.toml), [`libs/vertexai/pyproject.toml`](https://github.com/langchain-ai/langchain-google/blob/b86ee2fccd97b8afbea6850c8c23df45c8d44894/libs/vertexai/pyproject.toml), and [`libs/community/pyproject.toml`](https://github.com/langchain-ai/langchain-google/blob/b86ee2fccd97b8afbea6850c8c23df45c8d44894/libs/community/pyproject.toml):

- All three depend on `langchain-core >=1.3.2,<2.0.0`. They follow the v1 line.
- `genai` is the leanest — only `langchain-core`, `google-genai`, `pydantic`, and `filetype`.
- `vertexai` adds `google-cloud-aiplatform`, `google-cloud-storage`, `httpx`, `httpx-sse`.
- `community` is the heaviest — pulls in `langchain`, `langgraph`, `langchain-community`, the broader `google-api-python-client`, plus `google-cloud-modelarmor` for content safety scanning. Install only when you need it.

## What's NOT here

- **Google JS integrations.** Those live in [`langchain-ai/langchainjs`](https://github.com/langchain-ai/langchainjs) under `libs/providers/langchain-google-*/` (split into `genai`, `vertexai`, `vertexai-web`, `gauth`, `webauth`, `cloud-sql-pg`, `common`). See [`langchainjs-overview.md`](langchainjs-overview.md). The Python and JS Google packages are NOT in the same repo.
- **Anthropic-on-Vertex.** Claude models served through Vertex AI Model Garden are routed via the [`langchain-anthropic`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/partners/anthropic) in-tree partner package using a `vertex` auth mode, not through this repo.
- **Standalone API reference.** The auto-generated docs render at [reference.langchain.com/python/integrations/langchain_google](https://reference.langchain.com/python/integrations/langchain_google/), built outside this repo. Conceptual docs and tutorials are at [docs.langchain.com/oss/python/integrations/providers/google](https://docs.langchain.com/oss/python/integrations/providers/google).

## Common gotchas

- **Two `langchain-google-*` packages will coexist in the same env.** Installing both `langchain-google-genai` and `langchain-google-vertexai` is normal; they don't conflict. The class names differ (`ChatGoogleGenerativeAI` vs. `ChatVertexAI`), so imports stay unambiguous.
- **Standard-tests inheritance.** Each package's test suite extends the `langchain-tests` standard suites (`ChatModelUnitTests`, `ChatModelIntegrationTests`) — same contract pattern as in-tree partners. See [`langchain-partners.md`](langchain-partners.md) for how that works.
- **Per-package versioning means README badges can mislead.** The repo root README is brief (just lists the three packages); for accurate version + changelog, check each package's PyPI page or the `pyproject.toml` directly. The repo's GitHub Releases page filters by package name in the title (e.g., `genai vN.N.N`).
- **`AGENTS.md` build commands assume `uv` and `make`.** From [`AGENTS.md`](https://github.com/langchain-ai/langchain-google/blob/b86ee2fccd97b8afbea6850c8c23df45c8d44894/AGENTS.md): each package has its own `pyproject.toml` and `uv.lock`. Run `make test`, `make lint`, `make format`, `uv run --group lint mypy .` from inside each package directory.
- **`langchain-google-community` is the most volatile.** Major-version bumps happen when Google deprecates an upstream API. If something stops working after a community-package upgrade, check the changelog before assuming the LangChain wrapper is at fault.

## Documentation pointers

- [docs.langchain.com/oss/python/integrations/providers/google](https://docs.langchain.com/oss/python/integrations/providers/google) — provider-level overview.
- [reference.langchain.com/python/integrations/langchain_google](https://reference.langchain.com/python/integrations/langchain_google/) — API reference for all three packages.
- [`README.md`](https://github.com/langchain-ai/langchain-google/blob/b86ee2fccd97b8afbea6850c8c23df45c8d44894/README.md) at the repo root is brief but lists the three PyPI links.
- [`AGENTS.md`](https://github.com/langchain-ai/langchain-google/blob/b86ee2fccd97b8afbea6850c8c23df45c8d44894/AGENTS.md) for the maintainer-facing dev/build commands.
