# The model API

Inspect normalizes 20+ inference backends behind one `Model` interface. The user-facing entry points are:

- `--model openai/gpt-4o-mini` (CLI) or `eval(..., model=...)` (Python).
- `INSPECT_EVAL_MODEL` env var as a project-level default.
- `get_model("anthropic/claude-sonnet-4-0")` inside solver/scorer code for grading or multi-model setups. Calls are memoized by default — pass `memoize=False` to bypass, or use `async with get_model(...) as model:` to fully close clients at place of use (sync `with` works only for providers that don't require an async close).
- `Task(model=...)` to pin a model in the task definition (rare; CLI usually wins).

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/models.qmd#L14-L51

The `<provider>/<model>` convention is uniform across all providers. Use `--model none` (or `model=None`) to indicate the task uses no model directly — useful when the evaluation logic calls `get_model()` itself for role-specific access.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/models.qmd#L36-L51

## Model roles

Model roles let you bind named aliases (e.g. `grader`, `red_team`, `blue_team`) to specific models, then swap them at eval time. The built-in model-graded scorers look up the `grader` role by default. Roles are resolved at `eval()` time, so always call `get_model(role="...")` _inside_ your scorer/solver body rather than at module-import or init time — otherwise the role isn't yet visible. Set defaults via `get_model(role="grader", default="openai/gpt-4o")` to use roles as external configurability even without explicit overrides. Specify roles on `Task(model_roles=...)`, via `task_with()`, on `eval(model_roles=...)`, or on the CLI with one or more `--model-role grader=openai/gpt-4o` flags (inline JSON/YAML supported for per-role generation config).

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/models.qmd#L140-L295

## GenerateConfig — generation knobs

Pass `GenerateConfig` on `Task`, `eval`, or solver-level `generate()`:

- Token sampling: `temperature`, `top_p`, `top_k`, `max_tokens`, `stop_seqs`, `frequency_penalty`, `presence_penalty`, `logprobs`, `top_logprobs`, `seed`.
- Connection plumbing: `timeout`, `max_retries`, `max_connections`, `parallel_tool_calls`, `system_message`.
- Reasoning routing: `reasoning_effort`, `reasoning_summary`, `reasoning_tokens` (deprecated — prefer `reasoning_effort`), `reasoning_history`. See the reasoning section below.
- Validation: as of 0.3.223, **unknown GenerateConfig fields are rejected with an error** (previously silently dropped). Watch for typos when upgrading.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/model/_generate_config.py#L192-L305

CLI flags map by kebab-case (`--temperature 0.9`, `--max-connections 20`). For model-specific knobs outside `GenerateConfig`, use `-M key=value` (e.g. `-M location=us-east5`).

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/models.qmd#L52-L81

## Provider catalog

| Tier | Providers (provider prefix) |
|---|---|
| Lab APIs | `openai`, `anthropic`, `google`, `grok`, `mistral`, `deepseek`, `perplexity` |
| Cloud APIs | `bedrock`, `sagemaker`, `azureai` |
| Open hosted | `groq`, `together`, `fireworks`, `cf`, `hf-inference-providers`, `sambanova` |
| Open local | `hf`, `vllm`, `vllm-completions`, `ollama`, `llama-cpp-python`, `sglang`, `transformer_lens`, `nnterp` |
| Aggregator | `openrouter`, plus generic `openai-api` for any OpenAI-compatible endpoint |

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/models.qmd#L6-L12

The full per-provider option matrix is in `providers.qmd` — it documents required env vars, custom model args (passed as `-M key=value` on the CLI), and provider-specific gotchas.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L1-L10

## Provider-specific things that bite

- **OpenAI** — `responses_api=true` switches to the Responses API (default for GPT-5, o-series, `computer_use_preview`); `responses_store=True` (default) controls server-side storage. `responses_phase=true` synthesizes missing assistant message `phase` labels when replaying histories. `prompt_cache_key` keys the OpenAI server-side prompt cache. `background=True` enables async polling (default for `gpt-5-pro` / `deep-research`). `service_tier=flex` enables Flex pricing for o3/o4-mini (Inspect bumps `client_timeout` to 900s automatically). Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L12-L145

- **Anthropic** — Native prompt caching is automatic for `cache_control`-marked content; cache_control is skipped on thinking blocks. The `betas` model arg enables beta features (e.g. `betas=context-1m-2025-08-07` for 1M-context Sonnet 4.5/Opus 4.6). `streaming=auto` (default) turns on when thinking is enabled or `max_tokens >= 8192`. Available via `bedrock`, `vertex`, and `azure` qualifiers. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L147-L225

- **Google** — Uses `google-genai`; default SDK transport timeout is 1 hour. Safety settings default to `none` across all categories (overridable per-category). `streaming=true` is recommended for Gemini 3+ to capture reasoning summaries. Available via `vertex` qualifier (Vertex Express via `VERTEX_API_KEY`). Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L227-L377

- **OpenRouter** — Routes to many backends. For `openrouter/anthropic/*` models, prompt caching is enabled by default (`cache_control` markers injected just before the request — they won't appear in `.eval` log snapshots; verify via usage cache reads/writes). Disable with `--cache-prompt=false`. OpenRouter may route consecutive same-model requests across Anthropic-direct/Bedrock/Vertex backends with separate caches — pin via `-M provider='{"order":["anthropic"],"allow_fallbacks":false}'`. Custom args: `models`, `provider`, `transforms`, `reasoning_enabled`. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L1293-L1328

- **Bedrock** — All Bedrock models require explicit access grants. Drops unsupported sampling params for Claude 4.7+. `top_k` routed correctly for Nova. Anthropic-on-Bedrock can alternatively go through the `anthropic/bedrock/...` route. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L415-L433

- **SageMaker** — Endpoint name follows `sagemaker/`. Chat and completion modes both supported (`completion_mode=true` for CPT/base models — image content ignored). `prompt_logprobs` enables `perplexity()` and `target_perplexity()` scorers with vLLM-backed endpoints (auto-tokenization unavailable; supply `num_target_tokens` in sample metadata). `inference_component_name` routes to multi-model endpoints. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L434-L550

- **Hugging Face (`hf`)** — Local inference. Batches up to `max_connections` (default 32) generate calls. `trust_remote_code` defaults to `False` and is **not** forwarded from generic `model_args` — pass explicitly per model. `chat_template` overrides tokenizer template; `use_chat_template=false` bypasses entirely. `hidden_states=true` surfaces activations in `ModelOutput.metadata`. `hf/local -M model_path=...` for local weights. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L711-L827

- **vLLM** — Auto-batched; tune via `max_connections` (default 32). `-M` args become vLLM CLI flags (`tensor_parallel_size` → `--tensor-parallel-size`; dotted args like `speculative-config.num_speculative_tokens=1` are forwarded as-is). LoRA via `vllm/<model>:<adapter>` syntax — `max_lora_rank` auto-detected from `adapter_config.json`. Multiple models sharing a base reuse a single server. Use `vllm-completions/...` for raw text prompts. For reasoning models, pass the parser via `-M reasoning_parser=...`. `prompt_logprobs` enables perplexity scorers (streaming must be off). Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L829-L1050

- **SGLang** — Mirrors the vLLM provider's shape; auto-batched, `-M` forwarded to the SGLang CLI, retries after 5s by default. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L1052-L1135

- **vLLM / SGLang — multiple servers** — `VLLM_BASE_URL` / `SGLANG_BASE_URL` set a single global endpoint, but each server hosts one model. For solver-vs-judge setups, use [model roles](#model-roles) with per-role `base_url`. Inspect collapses two `vllm/<same-model>` instances at different URLs to the first URL — caveat only applies when reusing the same base model name. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L852-L958

- **TransformerLens** — Requires constructing the `HookedTransformer` first and passing it via `tl_model` model arg along with `tl_generate_args`. Tool calling not supported. CLI model loading not supported. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L1137-L1180

- **OpenAI-compatible (`openai-api`)** — Use when the provider exposes an OpenAI-shaped endpoint that isn't in the catalog. Naming: `openai-api/<provider>/<model>`. Reads `<PROVIDER>_API_KEY` and `<PROVIDER>_BASE_URL` (hyphens → underscores). `strict_tools` defaults to `true`. Supports `responses_api`, `responses_phase`, `emulate_tools`, `stream`. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L1218-L1291

- **Tool emulation** — For models without native tool calling, `-M emulate_tools=true` (XML schema + XML tool-call tags) is available for `azureai`, `together`, `fireworks`, `sambanova`, `ollama`, `openai-api`, `openrouter`. Default-on for Llama on `azureai`. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L586-L596

- **Grok** — Reads `XAI_API_KEY` (preferred) or `GROK_API_KEY`. `disable_retry=true` skips GRPC retries (useful for accurate `working_time`). Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L379-L413

- **Perplexity** — Surfaces `UrlCitation`s on the assistant message; extra usage in `ModelOutput.metadata`. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd#L692-L709

## Reasoning models

Reasoning-related plumbing was substantially reorganized upstream. The key surface:

- **`reasoning_effort`** is the unified knob. Inspect accepts a **superset**: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max` — and maps to each provider's native scale. `none` omits reasoning where supported.
- **`reasoning_tokens`** is now **deprecated** in favour of `reasoning_effort` (both Anthropic `budget_tokens` and Google `thinking_budget` have moved to effort-based controls upstream). Still accepted as an explicit budget for legacy Claude (3.7–4.5) and Gemini 2.5, where Inspect bridges effort → token budget internally (`minimal`=2048, `low`=4096, `medium`=10000, `high`=16000, `xhigh`/`max`=32000).
- **`reasoning_summary`** — OpenAI only. `none` / `concise` / `detailed` / `auto`. Some accounts require organization verification.
- **`reasoning_history`** — How much prior reasoning to replay in conversation. `none` / `all` / `last` / `auto` (default `auto`). Use `last` to keep reasoning from dominating context.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/reasoning.qmd#L1-L25

Per-provider effort mappings (highlights — see `docs/reasoning.qmd` for full tables):

- **OpenAI**: `minimal`/`low`/`medium`/`high`/`xhigh` pass through identically; `max` → `xhigh`.
- **Anthropic Claude 4.6+ (Opus 4.6/4.7, Sonnet 4.6)**: uses the native `effort` parameter ([adaptive thinking](https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking)). `xhigh` only on Claude 4.7+ (else clamped to `high`); `max` passes through.
- **Anthropic Claude 3.7 / 4.0 / 4.1 / 4.5**: no native `effort` — Inspect bridges effort to an [extended thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking) token budget using the table above.
- **Google Gemini 3 (Flash/Pro/Pro 3.1)**: native `MINIMAL`/`LOW`/`MEDIUM`/`HIGH` (Pro omits `MINIMAL` — `minimal` maps to `LOW`). `high`/`xhigh`/`max` all → `HIGH`.
- **Google Gemini 2.5**: no effort scale; effort bridged to `thinking_budget` per the table.
- **Grok**: Grok 3 Mini and Grok 4.X reasoning variants accept `low`/`medium`/`high` (extended values clamped). Original `grok-4` reasons but does not accept the parameter — Inspect omits it.
- **OpenRouter**: passes effort through; OpenRouter itself maps to `budget_tokens` via `clamp(max_tokens × ratio, 1024, 128000)` (`minimal` 0.1, `low` 0.2, `medium` 0.5, `high` 0.8, `max`/`xhigh` 0.95).
- **Groq / Ollama / SageMaker**: upstream accepts only `low`/`medium`/`high`; extended values clamped.
- **Bedrock**: varies by hosted family. Claude-on-Bedrock accepts only `reasoning_tokens` (no effort). Nova uses `reasoningConfig.maxReasoningEffort`. GPT-OSS passes effort through.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/reasoning.qmd#L26-L140

When Inspect omits `reasoning_effort`, the provider applies its own default. Defaults are documented in `docs/_reasoning-defaults.md` (e.g. OpenAI GPT-5 family defaults `medium`; GPT-5.2-Pro/5.4-Pro/5.5-Pro default `high`; Anthropic Claude Opus 4.6/4.7 and Sonnet 4.6 default `adaptive`; Gemini 3 Pro defaults `high`).

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/_reasoning-defaults.md#L1-L33

### Reasoning content

Reasoning traces are normalized into `ContentReasoning` blocks alongside `ContentText`/`ContentImage`/etc., and displayed in their own region in Inspect View and the terminal conversation view. Inspect captures reasoning from: a `reasoning` or `reasoning_content` field on the assistant message, `<think></think>`-wrapped content, or explicit APIs (Anthropic extended thinking blocks). When provided, `reasoning_tokens` usage is recorded in `ModelUsage`.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/reasoning.qmd#L141-L160

### vLLM / SGLang reasoning

Model-specific — configure the parser via `-M reasoning_parser=...`. Thinking mode is controlled separately from `--reasoning-effort` via chat-template kwargs (e.g. Qwen3 `-M default_chat_template_kwargs='{"enable_thinking": true}'`, or per-request via `-M extra_body='{"chat_template_kwargs": {...}}'`). Open-weights reasoning models often don't expose adjustable effort — `--reasoning-effort` is a no-op even when a parser is still required to separate reasoning from final answer. `<think></think>`-emitting models are captured automatically without any vLLM/SGLang config.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/reasoning.qmd#L161-L188

## Adaptive connections

`--adaptive-connections` is enabled by default at 100 per model connection. The framework dynamically adjusts request fan-out to avoid 429s, starting at 20 in-flight and scaling up to the maximum while the provider keeps up. For local inference engines, you may want to drop this lower. The default static `max_connections` is 10 — raise it to match your provider's rate limits when not using adaptive mode.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/models-concurrency.qmd#L1-L65

The `AdaptiveConcurrency` object in Python lets you fully customize bounds: `min`, `start`, `max`, `cooldown_seconds`, `decrease_factor`, `scale_up_percent`. When both `--max-connections` and `--adaptive-connections` are set, the explicit `max_connections` value takes precedence and adaptive is disabled.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/model/_generate_config.py#L204-L208

## Batch mode

Inspect supports the batch processing APIs for OpenAI, Anthropic, Google, xAI, and Together AI. Batch mode has lower token costs (typically 50% of normal) and higher rate limits, but processing can take minutes to hours. Enable with `--batch` (CLI) or `batch=True` to `eval()`. Individual samples are collected and dispatched as batches automatically. Agentic tasks with many sequential generations are a poor fit — each generation step must complete before the next can be dispatched, creating long wait chains.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/models-batch.qmd#L1-L101

## Model info caching

Inspect caches the model-info database lookup result so failed lookups don't repeat the fuzzy-name search on every sample. If you've configured a custom model name and Inspect can't classify it, the lookup runs once per session rather than per sample.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/model/_model.py#L2279-L2285

## Custom providers

When the catalog doesn't cover your provider, write a `ModelAPI` subclass + `@modelapi(name="custom")` factory in a Python package — see `ukgovernmentbeis-inspect-ai-extensions.md`. Setuptools entry-point discovery means no special Inspect registration is needed.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/model/_model.py#L185-L214

## See also

- `ukgovernmentbeis-inspect-ai-extensions.md` — adding new model providers.
- `ukgovernmentbeis-inspect-ai-cli-and-config.md` — `INSPECT_EVAL_MODEL`, `-M` model args, `.env` patterns.
- `ukgovernmentbeis-inspect-ai-tasks.md` — `Task(config=...)` vs. `eval(config=...)` precedence.

## Source

- `docs/models.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/models.qmd
- `docs/providers.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd
- `docs/reasoning.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/reasoning.qmd
- `docs/_reasoning-defaults.md` (per-model effort defaults) — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/_reasoning-defaults.md
- `docs/_model-providers.md` (catalog table) — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/_model-providers.md
- `docs/models-batch.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/models-batch.qmd
- `docs/models-concurrency.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/models-concurrency.qmd
- `src/inspect_ai/model/_providers/` — provider implementations: https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/model/_providers
- `src/inspect_ai/model/_generate_config.py` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/model/_generate_config.py
- `src/inspect_ai/model/_model.py` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/model/_model.py
- Repo HEAD: `033745ddbc05431c38b015a4b8f2236e956ee9ea`
