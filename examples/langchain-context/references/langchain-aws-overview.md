---
name: langchain-aws-overview
description: Companion repo langchain-ai/langchain-aws — out-of-tree partner monorepo for AWS integrations. Hosts langchain-aws (Bedrock + Kendra + Neptune + S3 Vectors etc.), langgraph-checkpoint-aws, and langchain-agentcore-codeinterpreter.
---

# langchain-aws (companion repo)

[langchain-ai/langchain-aws](https://github.com/langchain-ai/langchain-aws/tree/b175d5ab0c51412ecf4e4a18404bb03bd64764ab) is a partner-integration monorepo that lives **outside** the main `langchain-ai/langchain` tree. The in-tree [`libs/partners/README.md`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/partners/README.md) calls this out: AWS integrations were moved out for independent versioning. The repo is also the planned replacement for the legacy AWS components in `langchain-community` — the README states "this repository will replace all AWS integrations currently present in the `langchain-community` package. Users are encouraged to migrate to this repository as soon as possible." See [`langchain-partners.md`](langchain-partners.md) for the in-tree partner pattern this repo follows.

## Repo layout

Three Python packages under `libs/`:

- [`libs/aws/`](https://github.com/langchain-ai/langchain-aws/tree/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/libs/aws) — publishes [`langchain-aws`](https://pypi.org/project/langchain-aws/) (v1.5.0). The big one. Covers chat models, LLMs, embeddings, vectorstores, retrievers, graphs, agents, tools, runnables, document compressors, and middleware — all targeted at AWS services. Public top-level surface re-exported from [`langchain_aws/__init__.py`](https://github.com/langchain-ai/langchain-aws/blob/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/libs/aws/langchain_aws/__init__.py): `ChatBedrock`, `ChatBedrockConverse`, `BedrockLLM`, `SagemakerEndpoint`, `AmazonKendraRetriever`, `AmazonKnowledgeBasesRetriever`, `AmazonS3VectorsRetriever`. Lazy-imported (TYPE_CHECKING block): `ChatAnthropicBedrock`, `ChatBedrockNovaSonic`, `BedrockEmbeddings`, `BedrockRerank`, Neptune graph QA chains, in-memory and Valkey and S3-Vectors vector stores.
- [`libs/langgraph-checkpoint-aws/`](https://github.com/langchain-ai/langchain-aws/tree/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/libs/langgraph-checkpoint-aws) — publishes [`langgraph-checkpoint-aws`](https://pypi.org/project/langgraph-checkpoint-aws/) (v1.0.7). LangGraph checkpoint backends backed by AWS services: **Bedrock AgentCore Memory**, **Bedrock Session Management Service**, **DynamoDB**, **ElastiCache Valkey**. Drop-in for the `langgraph-checkpoint-postgres` / `-sqlite` ones from the LangGraph repo (see [`langgraph-overview.md`](langgraph-overview.md)) when you want persistence on AWS-managed infra.
- [`libs/agentcore-codeinterpreter/`](https://github.com/langchain-ai/langchain-aws/tree/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/libs/agentcore-codeinterpreter) — publishes [`langchain-agentcore-codeinterpreter`](https://pypi.org/project/langchain-agentcore-codeinterpreter/) (v0.0.3). A Deep Agents sandbox backend that delegates the `execute` shell tool to **Bedrock AgentCore Code Interpreter** — secure code execution in isolated MicroVM environments. Depends on `deepagents>=0.1.0` and `bedrock-agentcore>=1.1.4`. See [`deepagents-overview.md`](deepagents-overview.md) for how Deep Agents sandbox backends compose.

Plus an [`llms.txt`](https://github.com/langchain-ai/langchain-aws/blob/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/llms.txt) and [`llms-full.txt`](https://github.com/langchain-ai/langchain-aws/blob/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/llms-full.txt) — the [llms.txt convention](https://llmstxt.org/) of curating a per-service link index for LLM-assisted lookup. Useful as a "what AWS integrations exist here" map.

## What this repo covers, by AWS service

**Models / inference** (`langchain-aws`):

- **Amazon Bedrock** — chat models (`ChatBedrock` for the original Invoke API, `ChatBedrockConverse` for the unified Converse API and the recommended choice for new code), `BedrockLLM` for completion-only models, `BedrockEmbeddings`, `BedrockRerank` document compressor.
- **Amazon Bedrock Nova Sonic** — `ChatBedrockNovaSonic` for the speech model.
- **SageMaker Endpoints** — `SagemakerEndpoint` LLM class for custom-deployed models.

**Retrieval / RAG** (`langchain-aws`, retriever classes re-exported from [`langchain_aws/__init__.py`](https://github.com/langchain-ai/langchain-aws/blob/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/libs/aws/langchain_aws/__init__.py)):

- **Amazon Kendra** — `AmazonKendraRetriever`.
- **Amazon Bedrock Knowledge Bases** — `AmazonKnowledgeBasesRetriever`.
- **Amazon S3 Vectors** — `AmazonS3VectorsRetriever` and `AmazonS3Vectors` vector store.
- **Amazon MemoryDB** / **Amazon ElastiCache Valkey** — `InMemoryVectorStore`, `ValkeyVectorStore`, `InMemorySemanticCache`.

**Graph databases** (`langchain-aws`, lazy-imported from [`langchain_aws/__init__.py`](https://github.com/langchain-ai/langchain-aws/blob/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/libs/aws/langchain_aws/__init__.py)):

- **Amazon Neptune** — `NeptuneGraph`, `NeptuneAnalyticsGraph`, plus the `create_neptune_opencypher_qa_chain` and `create_neptune_sparql_qa_chain` helpers.

**Agents and tools** (`langchain-aws`, in [`libs/aws/`](https://github.com/langchain-ai/langchain-aws/tree/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/libs/aws)):

- **Amazon Bedrock Agents** — Runnables to integrate Bedrock-hosted agents into LangChain / LangGraph flows.
- **Amazon Bedrock AgentCore Browser** — `create_browser_toolkit(region=...)` returns a toolkit for managed browser automation (navigation, content extraction, form fill, screenshots).
- **Amazon Bedrock AgentCore Code Interpreter** — `create_code_interpreter_toolkit(region=...)` for sandboxed code execution as a tool. (Distinct from the Deep Agents sandbox backend in the third package — same underlying service, different integration shape.)

**Persistence / state** (`langgraph-checkpoint-aws`, in [`libs/langgraph-checkpoint-aws/`](https://github.com/langchain-ai/langchain-aws/tree/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/libs/langgraph-checkpoint-aws)):

- **AgentCore Memory** — checkpoint saver and a long-term memory store.
- **Bedrock Session Management** — checkpoint saver.
- **DynamoDB** — checkpoint saver.
- **ElastiCache Valkey** — checkpoint saver and memory store.

**Sandboxes** (`langchain-agentcore-codeinterpreter`, in [`libs/agentcore-codeinterpreter/`](https://github.com/langchain-ai/langchain-aws/tree/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/libs/agentcore-codeinterpreter)):

- **AgentCore Code Interpreter** as a Deep Agents `execute` backend. The `AgentCoreSandbox` wrapper takes a `bedrock_agentcore.tools.code_interpreter_client.CodeInterpreter` instance and exposes the protocol Deep Agents expects.

## Choosing the right package

- **`langchain-aws`** is the entry point for any LangChain code that needs to talk to AWS services. Most users only install this one.
- **`langgraph-checkpoint-aws`** is additive — install it on top of `langgraph` when you want AWS-managed persistence for your agent state. Pin compatible: `langgraph-checkpoint >=3.0.0,<5.0.0`, `langgraph >=1.0.0`.
- **`langchain-agentcore-codeinterpreter`** is additive on top of `deepagents` (>=0.1.0). Install when you specifically want a Bedrock AgentCore sandbox.

## Versioning and dependency pins

Notable pins from the [`libs/aws/pyproject.toml`](https://github.com/langchain-ai/langchain-aws/blob/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/libs/aws/pyproject.toml):

- `langchain-core >=1.3.2` — follows the v1 line.
- `boto3 >=1.42.42`, `pydantic >=2.10.6,<3`, `numpy >=1.0.0,<3` — minimal runtime deps. AWS SDK pinning is conservative.
- The other two packages have their own pins; `langgraph-checkpoint-aws` uses `pdm-backend` while the other two use `hatchling`.

## What's NOT here

- **Anthropic-on-Bedrock.** The `ChatAnthropicBedrock` class lives in this repo, but for general Anthropic Claude usage the [`langchain-anthropic`](https://github.com/langchain-ai/langchain/tree/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/partners/anthropic) in-tree partner package is usually the right starting point. Use the AWS-flavored class only when you specifically need Bedrock-hosted Claude with AWS auth.
- **AWS JS integrations.** Those live in [`langchain-ai/langchainjs`](https://github.com/langchain-ai/langchainjs) under `libs/providers/langchain-aws/`. See [`langchainjs-overview.md`](langchainjs-overview.md). The Python and JS AWS packages are NOT in the same repo.
- **OpenAI-on-Bedrock or generic Bedrock-via-LiteLLM.** Use the official Bedrock classes in `langchain-aws`; cross-vendor wrappers route through their own packages.
- **Standalone API reference.** Auto-generated docs render at [reference.langchain.com/python/integrations/langchain_aws](https://reference.langchain.com/python/integrations/langchain_aws/). Conceptual docs at [docs.langchain.com/oss/python/integrations/providers/aws](https://docs.langchain.com/oss/python/integrations/providers/aws).

## Common gotchas

- **`ChatBedrock` vs. `ChatBedrockConverse`.** Two parallel classes for Bedrock chat. `ChatBedrock` predates the Converse API and uses the per-model Invoke API; `ChatBedrockConverse` uses the unified Converse API and is the recommended class for new code. Default to Converse unless you need a feature only the Invoke path exposes.
- **AgentCore appears in two packages.** Bedrock AgentCore code execution is exposed both as a LangChain tool (`langchain-aws.tools.create_code_interpreter_toolkit`) and as a Deep Agents sandbox backend (`langchain-agentcore-codeinterpreter.AgentCoreSandbox`). Use the toolkit when you're composing tools for a `create_agent`; use the sandbox when you're configuring `create_deep_agent`. Same underlying service, different integration surface.
- **Migration from `langchain-community`.** AWS integrations in `langchain-community` are deprecated in favor of this repo. There is no automated codemod; the import paths change from `langchain_community.chat_models import BedrockChat` (or similar) to `langchain_aws import ChatBedrock`. Class names also drifted in some cases.
- **`LANGCHAIN_AWS_DEBUG=true`** in the environment turns on verbose logging via the [`langchain_aws/__init__.py:setup_logging()`](https://github.com/langchain-ai/langchain-aws/blob/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/libs/aws/langchain_aws/__init__.py) hook. Useful for diagnosing Bedrock auth or region misconfiguration.
- **`llms.txt` is the fastest map of the integration surface.** The repo's [`llms.txt`](https://github.com/langchain-ai/langchain-aws/blob/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/llms.txt) lists every guide and example with one-line summaries — faster than reading the README to find a specific integration.

## Documentation pointers

- [docs.langchain.com/oss/python/integrations/providers/aws](https://docs.langchain.com/oss/python/integrations/providers/aws) — provider-level overview.
- [reference.langchain.com/python/integrations/langchain_aws](https://reference.langchain.com/python/integrations/langchain_aws/) — API reference.
- [`README.md`](https://github.com/langchain-ai/langchain-aws/blob/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/README.md) and [`llms.txt`](https://github.com/langchain-ai/langchain-aws/blob/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/llms.txt) are the best in-repo orientation files.
- The [`samples/`](https://github.com/langchain-ai/langchain-aws/tree/b175d5ab0c51412ecf4e4a18404bb03bd64764ab/samples) directory at the repo root has runnable examples.
