---
name: langchain-partners
description: Partner integration packages (langchain-anthropic, langchain-openai, etc.) and the contract test suite. Read this for how a provider integration is structured, how to install one, how chat models implement bind_tools / structured output, and how langchain-tests validates partner compliance.
---

# LangChain partner packages

A *partner package* is a thin adapter that wraps one provider's SDK into LangChain's abstractions: chat models, embeddings, tools. Each lives at [`libs/partners/<provider>/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/partners) and is published as its own PyPI package on its own release cadence. Fifteen partners are in-tree at this SHA: anthropic, chroma, deepseek, exa, fireworks, groq, huggingface, mistralai, nomic, ollama, openai, openrouter, perplexity, qdrant, xai. Two notable ones — Google and AWS — moved out to standalone repos (`langchain-ai/langchain-google`, `langchain-ai/langchain-aws`) for independent versioning; the [`libs/partners/README.md`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/partners/README.md) documents that split.

## Install and import

PyPI naming: `langchain-<provider>`. Python module naming: `langchain_<provider>` (underscore).

```bash
pip install langchain-anthropic
```

```python
from langchain_anthropic import ChatAnthropic
chat = ChatAnthropic(model="claude-3-5-sonnet-latest")
```

The `init_chat_model("anthropic:claude-3-5-sonnet")` factory in v1 does this dance for you: it imports the right partner package on demand and instantiates the class. Each partner package is a small dependency footprint — installing `langchain-anthropic` does NOT pull in `langchain-openai`, only the Anthropic SDK plus `langchain-core`.

## Package layout

Looking at [`libs/partners/anthropic/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/partners/anthropic) as the canonical example:

- [`pyproject.toml`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/partners/anthropic/pyproject.toml) — declares `langchain-anthropic`, pins `langchain-core` and the provider SDK (`anthropic`), version metadata.
- [`uv.lock`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/partners/anthropic/uv.lock) — per-partner lock for reproducible CI.
- `langchain_anthropic/__init__.py` — re-exports the public surface: `ChatAnthropic`, `AnthropicLLM`, helpers like `convert_to_anthropic_tool`.
- `langchain_anthropic/chat_models.py` — the main `ChatAnthropic` class, subclassing `BaseChatModel`.
- `langchain_anthropic/llms.py` — legacy `AnthropicLLM` (the string-in / string-out `BaseLLM` form). Mostly there for back-compat.
- `langchain_anthropic/output_parsers.py` — provider-specific output utilities.
- `langchain_anthropic/data/profile_augmentations.toml` — model capability overrides for `langchain-model-profiles`.
- `tests/unit_tests/` — non-network tests including the **standard contract tests**.
- `tests/integration_tests/` — network-dependent tests against the real provider.
- `scripts/` — helper scripts (version pin checks, import-time validation).

Every partner follows this skeleton. The list of files can vary (some partners ship embeddings, some don't; some ship `retrievers.py`, most don't), but the shape is consistent.

## The chat model contract

A partner chat model subclasses [`langchain_core.language_models.chat_models.BaseChatModel`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/language_models/chat_models.py) (see `langchain-core-models.md` for the abstract surface) and implements:

- `_generate(messages, stop, run_manager, **kwargs) -> ChatResult` — single sync call to the provider, normalized to a `ChatResult`.
- `_agenerate(...)` — async equivalent.
- `_stream / _astream` — yield `ChatGenerationChunk` objects when streaming.
- `bind_tools(tools, **kwargs)` — return a Runnable with tool definitions attached in the provider's wire format. Each partner does its own translation from `BaseTool` to the provider's JSON shape.
- `with_structured_output(schema, method=...)` — return a Runnable that emits structured output. Each partner advertises which methods it supports (JSON schema, function calling, JSON mode) and picks a default.

The provider-specific work is in three places: translating LangChain messages to the provider's wire format, translating responses back to `AIMessage` (including `tool_calls` and `usage_metadata`), and mapping LangChain config (stop tokens, temperature, max tokens, etc.) to the provider's parameter names.

## Standard contract tests (langchain-tests)

[`libs/standard-tests/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/standard-tests) publishes `langchain-tests`. It provides reusable test mixins partners inherit to validate their integration against the contract:

- [`ChatModelUnitTests`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/standard-tests/langchain_tests/unit_tests/chat_models.py) — no-network tests: serialization, basic typing, tool-binding shape, schema generation.
- [`ChatModelIntegrationTests`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/standard-tests/langchain_tests/integration_tests) — network tests: real invocation, streaming, tool calling end-to-end, structured output, image/multimodal input where supported.
- Embedding test mixins for `Embeddings` partners.
- VectorStore test mixins for vectorstore partners (Chroma, Qdrant in-tree).

Usage pattern in a partner's `tests/unit_tests/test_chat_models_standard.py`:

```python
from langchain_tests.unit_tests import ChatModelUnitTests
from langchain_anthropic import ChatAnthropic

class TestChatAnthropic(ChatModelUnitTests):
    @property
    def chat_model_class(self):
        return ChatAnthropic
    @property
    def chat_model_params(self):
        return {"model": "claude-3-5-sonnet-latest"}
```

The mixin runs a suite of contract checks. If a partner doesn't support a feature (say, streaming with tools), the mixin exposes flags to skip that case explicitly — silent skips would let regressions land unnoticed.

## Model profiles

[`libs/model-profiles/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/model-profiles) publishes `langchain-model-profiles`. It maintains structured metadata about each model (context window size, supports tool calling, supports vision, supports structured output, etc.) sourced from the upstream `models.dev` project. Partners can override or augment via their `data/profile_augmentations.toml`. `init_chat_model` consults profiles to validate feature combinations at construction time.

## Out-of-tree partners

Two major partner organizations ship out of this monorepo:

- **`langchain-ai/langchain-google`** — Vertex AI, Gemini, Google Generative AI. Same partner-package layout; same contract tests; published as `langchain-google-vertexai`, `langchain-google-genai`, etc.
- **`langchain-ai/langchain-aws`** — Bedrock and AWS LLM services. Published as `langchain-aws`.

Both have their own references in this contextualizer — see [`langchain-google-overview.md`](langchain-google-overview.md) and [`langchain-aws-overview.md`](langchain-aws-overview.md). The decision to live out-of-tree was driven by independent versioning and dependency management; the contract and layout are unchanged from in-tree partners.

There is also `langchain-community` — a single sprawling PyPI package that carries the *long tail* of community-contributed integrations (older or less-active providers that don't justify their own package). It lives in a separate repo from this one. If a partner is neither in-tree nor in `langchain-<provider>` form, check `langchain-community.<category>`.

## Writing a new partner

The high-level recipe is in the repo-root [`AGENTS.md`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/AGENTS.md):

1. Use an existing partner directory as a template (anthropic and openai are the most-canonical examples).
2. Implement `chat_models.py` against `BaseChatModel`. Add `embeddings.py` and `llms.py` if the provider supports those.
3. Add `tests/unit_tests/test_*_standard.py` inheriting from the appropriate `langchain_tests` mixin.
4. Add `tests/integration_tests/` with API-key-gated tests.
5. Maintain `pyproject.toml` deps tight: depend on `langchain-core` and the provider SDK only.

New providers that don't want to live in-tree (most common path now) start from the same template in a fresh repo and publish as `langchain-<provider>` independently.

## Gotchas

- Partner version pins matter. `langchain-anthropic` may declare `langchain-core>=0.3.x`; mixing partners that pin to incompatible core ranges produces resolver headaches. The `langchain-tests` suite catches "did you actually conform to the contract" but not "did you pin reasonably."
- Tool-call argument schemas differ in subtle ways between providers (strict mode in OpenAI, tool_choice in Anthropic, parallel tool calls in some, sequential in others). The contract tests cover most variation, but provider-specific edge cases require reading the partner's `chat_models.py` directly.
- `bind_tools` is implemented per-partner; if the call raises `NotImplementedError`, the provider isn't a tool-calling target and you need a different model.
- Usage metadata (`AIMessage.usage_metadata` with `input_tokens`, `output_tokens`, `total_tokens`) is normalized in each partner — but some providers expose more granular fields (cache tokens, reasoning tokens) that surface in `response_metadata` rather than `usage_metadata`.
