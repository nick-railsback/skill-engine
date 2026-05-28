# langchain-core: models, messages, tools, prompts, parsers

The "model layer" in langchain-core is the set of abstractions a typical RAG-or-agent pipeline sits on: a prompt, a chat model, possibly a tool surface, and an output parser. They all live under [`libs/core/langchain_core/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core), they all implement the `Runnable` protocol (so `prompt | model | parser` just works — see `langchain-core-runnables.md`), and they're what every partner package implements concretely.

## Chat models

`BaseChatModel` ([`libs/core/langchain_core/language_models/chat_models.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/language_models/chat_models.py)) is the primary LLM interface. It is a Runnable from `LanguageModelInput` (a string, a list of messages, or a `PromptValue`) to `AIMessage`. The class defines:

- `_generate(messages, stop, run_manager) -> ChatResult` — sync subclass hook. Each partner overrides this.
- `_agenerate(...)` — async subclass hook.
- `_stream(...) / _astream(...)` — yield `ChatGenerationChunk` for streaming.
- `bind_tools(tools, **kwargs) -> Runnable` — returns a new chat model with tools attached. Partners must implement this to participate in tool-calling.
- `with_structured_output(schema, method=..., include_raw=False) -> Runnable` — returns a Runnable that emits structured output validated against `schema` (a Pydantic class, a `TypedDict`, or a JSON schema). `method` selects the mechanism — `"json_schema"`, `"function_calling"`, `"json_mode"` — depending on what the provider supports.

`BaseLLM` ([`libs/core/langchain_core/language_models/llms.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/language_models/llms.py)) is the legacy string-in / string-out interface. Still supported, but chat models are the modern path; new code should use `BaseChatModel` for everything (it handles single-string prompts fine via the input coercion).

The factory `init_chat_model("provider:model-name", ...)` (re-exported from `langchain.chat_models` in v1) loads the right partner package by string. `init_chat_model("openai:gpt-5.4")` returns a `ChatOpenAI`; `init_chat_model("anthropic:claude-3-5-sonnet")` returns a `ChatAnthropic`. Each partner publishes its concrete class under `langchain_<provider>.chat_models.Chat<Provider>` — see `langchain-partners.md`.

## Messages

The message hierarchy lives under [`libs/core/langchain_core/messages/`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/messages):

- [`base.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/messages/base.py) — `BaseMessage` (parent), `BaseMessageChunk` (streaming sibling that supports `+` concatenation).
- [`human.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/messages/human.py) — `HumanMessage`.
- [`ai.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/messages/ai.py) — `AIMessage`, `AIMessageChunk`. Carries `content`, `tool_calls`, `usage_metadata`, `response_metadata`.
- [`system.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/messages/system.py) — `SystemMessage`.
- [`tool.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/messages/tool.py) — `ToolMessage` (the result returned to the model after a tool call), `ToolCall` (the model's request to call a tool), `InvalidToolCall`.
- [`content.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/messages/content.py) — typed content blocks for multi-modal messages: `TextContentBlock`, image blocks, annotation types.

Message `content` can be a plain `str` or a `list[dict | ContentBlock]` for multi-modal payloads. Provider partners normalize their wire format into these blocks; downstream code reads `message.content` uniformly.

Tool calls live on `AIMessage.tool_calls` (a list of `ToolCall` dicts with `name`, `args`, `id`). When the model decides to call a tool, the chat model returns an `AIMessage` whose `content` is often empty and whose `tool_calls` is populated. Downstream code (or the v1 agent) dispatches each call and returns a `ToolMessage(content=..., tool_call_id=...)` for the next turn.

## Tools

`BaseTool` ([`libs/core/langchain_core/tools/base.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/tools/base.py)) is a Runnable wrapping a callable plus its schema. The canonical way to make one is the `@tool` decorator from [`libs/core/langchain_core/tools/__init__.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/tools/__init__.py):

```python
from langchain_core.tools import tool

@tool
def add(a: int, b: int) -> int:
    """Add two integers."""
    return a + b
```

The decorator inspects the type hints and docstring to build a JSON schema for tool-calling. For tools that need access to the run context, take `RunnableConfig` as a parameter; for tools that need to handle errors specifically, set `handle_tool_error` / `handle_validation_error` on the underlying `BaseTool`.

`bind_tools(tools)` on a chat model (which delegates to the partner-specific implementation) attaches the tool list as a binding. The model then returns `AIMessage.tool_calls` when it decides to invoke. There is no single dispatch loop in `langchain-core`; that lives in v1's `create_agent` (see `langchain-v1-agents.md`) or in user code.

## Prompts

`BasePromptTemplate` ([`libs/core/langchain_core/prompts/base.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/prompts/base.py)) is a Runnable from `dict[str, Any]` to a `PromptValue`. Two main subclasses:

- [`PromptTemplate`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/prompts/prompt.py) — string-based. `PromptTemplate.from_template("Hello {name}")` then `.invoke({"name": "world"})`.
- [`ChatPromptTemplate`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/prompts/chat.py) — message-based. `ChatPromptTemplate.from_messages([("system", "..."), ("human", "{q}")])` builds a list of messages with `{}`-template substitution.

`MessagesPlaceholder` is the slot you put inside a chat prompt template to inject conversation history at runtime: `MessagesPlaceholder("history")` is filled by `chain.invoke({"history": [...messages], "q": "..."})`.

## Output parsers

`BaseOutputParser` ([`libs/core/langchain_core/output_parsers/base.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/output_parsers/base.py)) is a Runnable from `str | BaseMessage` to whatever structured type the parser produces. The submodules cover the common cases:

- [`json.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/output_parsers/json.py) — `JsonOutputParser`. Streaming-friendly partial JSON.
- [`pydantic.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/output_parsers/pydantic.py) — `PydanticOutputParser`. Validates against a Pydantic model.
- [`string.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/output_parsers/string.py) — `StrOutputParser`. Just unwraps `AIMessage.content` to a str (the most-used parser).
- [`xml.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/output_parsers/xml.py) — XML parsing.
- [`openai_tools.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/core/langchain_core/output_parsers/openai_tools.py) — extracts tool-call arguments from `AIMessage.tool_calls`.

For structured output the modern path is `chat_model.with_structured_output(MyPydanticModel)` rather than `model | parser` — the wrapper handles provider-specific JSON-mode or tool-call coercion under the hood.

## Gotchas

- `bind_tools` is not on `BaseChatModel` itself as an abstract method; each partner implements it (or doesn't). If you `bind_tools` against a partner that doesn't support tool calling, you'll get an error at bind time.
- `with_structured_output` defaults to whichever method the partner declares as preferred; pass `method=...` to force JSON mode vs function calling.
- `AIMessage.content` may be empty string when `tool_calls` is populated — always check both.
- The streaming counterpart of `AIMessage` is `AIMessageChunk`, which supports `+` so you can accumulate streamed chunks into a single message.
