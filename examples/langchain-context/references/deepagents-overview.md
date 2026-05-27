---
name: deepagents-overview
description: Companion repo langchain-ai/deepagents — a higher-level "batteries-included" agent harness layered on langchain v1 with planning, filesystem, shell, and sub-agent tools. Inspired by Claude Code; returns a compiled LangGraph.
---

# Deep Agents (companion repo)

Deep Agents is an **opinionated agent harness** layered on top of `langchain` v1: instead of wiring up `create_agent` with the right tools, prompts, and middleware yourself, `create_deep_agent()` returns an agent that already has planning (`write_todos`), filesystem (`read_file`, `write_file`, `edit_file`, `ls`, `glob`, `grep`), shell (`execute`), and sub-agent (`task`) tools, plus prompts that teach the model to use them and middleware that auto-summarizes long conversations and spills large outputs to files. The README is explicit about provenance: "This project was primarily inspired by Claude Code, and initially was largely an attempt to see what made Claude Code general purpose, and make it even more so."

The repo lives at [langchain-ai/deepagents](https://github.com/langchain-ai/deepagents/tree/82c31947f9dc938ffc71e1cea96d162a39aec3a1). The root README of `langchain-ai/langchain` calls it out in a TIP block: "higher-level package built on LangChain for agents that have built-in capabilities for common usage patterns" — which is the right framing. If `create_agent` is "the agent kernel," Deep Agents is "the agent distro."

## Repo layout

A monorepo of independently versioned PyPI packages under `libs/`:

- [`libs/deepagents/`](https://github.com/langchain-ai/deepagents/tree/82c31947f9dc938ffc71e1cea96d162a39aec3a1/libs/deepagents) — publishes `deepagents` (v0.6.3). The SDK. Public surface re-exported from [`deepagents/__init__.py`](https://github.com/langchain-ai/deepagents/blob/82c31947f9dc938ffc71e1cea96d162a39aec3a1/libs/deepagents/deepagents/__init__.py).
- [`libs/cli/`](https://github.com/langchain-ai/deepagents/tree/82c31947f9dc938ffc71e1cea96d162a39aec3a1/libs/cli) — publishes `deepagents-cli` (v0.1.2). **As of 0.1.0 this package contains only deployment subcommands** (`init`, `dev`, `deploy`) for bundling and shipping agents to LangGraph Platform. The interactive coding REPL that used to live here moved to `deepagents-code` (see below). Install with `uv tool install deepagents-cli`.
- [`libs/code/`](https://github.com/langchain-ai/deepagents/tree/82c31947f9dc938ffc71e1cea96d162a39aec3a1/libs/code) — publishes `deepagents-code` (v0.1.4). The interactive terminal coding agent — a TUI similar in shape to Claude Code or Cursor, powered by any tool-calling LLM. Install via `curl -LsSf https://langch.in/dcode | bash`, run as `dcode`. Adds streaming TUI, conversation resume, web search, remote sandboxes (LangSmith / AgentCore / Daytona / Modal / Runloop), persistent memory, custom skills, headless mode, and HITL tool gating on top of the SDK.
- [`libs/acp/`](https://github.com/langchain-ai/deepagents/tree/82c31947f9dc938ffc71e1cea96d162a39aec3a1/libs/acp) — Agent Context Protocol support.
- [`libs/evals/`](https://github.com/langchain-ai/deepagents/tree/82c31947f9dc938ffc71e1cea96d162a39aec3a1/libs/evals) — evaluation suite and Harbor integration.
- [`libs/partners/`](https://github.com/langchain-ai/deepagents/tree/82c31947f9dc938ffc71e1cea96d162a39aec3a1/libs/partners) — sandbox/runtime integrations: `daytona`, `modal`, `quickjs`, `runloop`. These wrap external sandboxes that the `execute` tool delegates to so untrusted shell commands don't run against the host.

## Public Python surface

The SDK is small. The headline export from [`deepagents/__init__.py`](https://github.com/langchain-ai/deepagents/blob/82c31947f9dc938ffc71e1cea96d162a39aec3a1/libs/deepagents/deepagents/__init__.py):

- `create_deep_agent(model=None, tools=None, system_prompt=None, ...)` — the entry point. Returns a compiled LangGraph `StateGraph`. With no arguments it instantiates a sensible default (model from `init_chat_model`, the built-in tool set, the default prompt). Add tools, swap the model, or override the prompt to customize.

Plus the middleware components that `create_deep_agent` composes internally — exposed so you can use them in your own `create_agent` graph:

- **`FilesystemMiddleware`** + **`FilesystemPermission`** — adds the file tools and gates writes by configurable permissions.
- **`MemoryMiddleware`** — long-term memory persisted via the LangGraph store.
- **`SubAgentMiddleware`** + **`SubAgent`** + **`CompiledSubAgent`** — the `task` tool that delegates to a sub-agent with an isolated context window. Sync.
- **`AsyncSubAgentMiddleware`** + **`AsyncSubAgent`** + **`AsyncSubagentRunStream`** — async counterpart.
- **`SubagentTransformer`** + **`SubagentRunStream`** — lower-level streaming hooks for sub-agent output.
- **Profile registries**: `HarnessProfile`, `HarnessProfileConfig`, `register_harness_profile`, `GeneralPurposeSubagentProfile`, `ProviderProfile`, `register_provider_profile` — let third parties register named harness/provider configurations the CLI and SDK can pick by name.

## Backends and the sandbox model

Tools that touch the world — filesystem, shell — are pluggable backends in [`deepagents/backends/`](https://github.com/langchain-ai/deepagents/tree/82c31947f9dc938ffc71e1cea96d162a39aec3a1/libs/deepagents/deepagents/backends). The `protocol.py` module defines the interface; concrete implementations include `local_shell.py` (runs on the host), `sandbox.py` (delegates to a remote sandbox), `composite.py` (combines multiple), `langsmith.py` (records events to LangSmith for inspection), `state.py` and `store.py` (graph-state-backed virtual filesystem). The four `libs/partners/` packages — Daytona, Modal, QuickJS, Runloop — each provide a sandbox backend.

This is the practical answer to "but won't a model with shell access destroy my machine" — the default backend can be a virtual in-state filesystem with no real shell, or a remote sandbox. The README's security note is blunt: "Deep Agents follows a 'trust the LLM' model. The agent can do anything its tools allow. Enforce boundaries at the tool/sandbox level, not by expecting the model to self-police." See also [`libs/deepagents/THREAT_MODEL.md`](https://github.com/langchain-ai/deepagents/blob/82c31947f9dc938ffc71e1cea96d162a39aec3a1/libs/deepagents/THREAT_MODEL.md).

## How Deep Agents relates to the rest of the ecosystem

The dependency chain is `deepagents → langchain (v1) → langgraph → langchain-core`. Specifically the [pyproject](https://github.com/langchain-ai/deepagents/blob/82c31947f9dc938ffc71e1cea96d162a39aec3a1/libs/deepagents/pyproject.toml) pins `langchain >=1.3.0,<2.0.0`, `langchain-core >=1.4.0,<2.0.0`, `langsmith >=0.8.3`, plus `langchain-anthropic` and `langchain-google-genai` as default model providers.

Mental model:

- **`langchain.create_agent`** is the kernel — model + tools + middleware → graph.
- **`deepagents.create_deep_agent`** is `create_agent` with a curated tool set and middleware stack pre-applied, plus the prompts to drive them.

If a user already has a `create_agent` setup and wants Deep Agents' filesystem or sub-agent capabilities, they can import the middleware classes (`FilesystemMiddleware`, `SubAgentMiddleware`) and add them to their own middleware list rather than swapping over to `create_deep_agent`. The packages compose.

The compiled output is a LangGraph graph (the README calls this out: "LangGraph Native — `create_deep_agent` returns a compiled LangGraph graph"), so streaming, persistence (checkpointers), and Studio inspection all work the same way they do for any other LangGraph agent. See [`langgraph-overview.md`](langgraph-overview.md) for the LangGraph side.

MCP tool integration is supported via [`langchain-mcp-adapters`](https://github.com/langchain-ai/langchain-mcp-adapters) — pass MCP tools through the standard `tools=` argument.

## Common gotchas

- **`deepagents` (Python) vs. `deepagentsjs` (JS).** The README notes "Looking for the JS/TS library? Check out [deepagents.js](https://github.com/langchain-ai/deepagentsjs)." Same author, separate package, separate repo.
- **`create_deep_agent()` with no model argument requires `init_chat_model` to resolve.** Pass `model=init_chat_model("openai:gpt-4o")` (or any provider:model string) for explicit selection. The implicit default depends on what API keys are in the environment; explicit is safer.
- **Pinned model providers.** `langchain-anthropic` and `langchain-google-genai` are *required* dependencies in [`pyproject.toml`](https://github.com/langchain-ai/deepagents/blob/82c31947f9dc938ffc71e1cea96d162a39aec3a1/libs/deepagents/pyproject.toml), even if the user only uses OpenAI. They're loaded eagerly because the default profiles target them. This is unusual for a LangChain package — most expect `langchain-<provider>` to be installed only when needed.
- **Default tools include shell `execute`.** This is a meaningful security surface. Configure a sandbox backend before using Deep Agents on untrusted input or in a multi-tenant context. The CLI ships with sandbox defaults; the SDK does not.
- **Profile system is the customization API.** "Profiles" (harness profiles for tool/middleware selection, provider profiles for model defaults) are how Deep Agents lets third parties extend the harness without forking. Use `register_harness_profile` / `register_provider_profile` rather than building wrappers around `create_deep_agent`.

## Documentation pointers

- [docs.langchain.com/oss/python/deepagents/overview](https://docs.langchain.com/oss/python/deepagents/overview) — concept guides.
- [reference.langchain.com/python/deepagents](https://reference.langchain.com/python/deepagents/) — API reference.
- [docs.langchain.com/oss/python/deepagents/cli/overview](https://docs.langchain.com/oss/python/deepagents/cli/overview) — CLI guide.
- The [`examples/`](https://github.com/langchain-ai/deepagents/tree/82c31947f9dc938ffc71e1cea96d162a39aec3a1/examples) directory has runnable agents and patterns.
