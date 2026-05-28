# The auto-generated Python API reference

The portal's `/reference/inspect_ai.*.html` pages are the canonical lookup for exact signatures, class fields, and return types in the `inspect_ai` package. They are auto-generated from source and re-rendered on every release, so a flag/field that surfaces here but not in the `docs/*.qmd` prose is the public API speaking for itself. **Use these pages (or the per-module summaries below) to answer "what does this function take" / "what does this class hold" questions; use the `ukgovernmentbeis-inspect-ai-*` references for "how do I use it" / "what's idiomatic" questions.**

There are 13 module pages. The top-level `inspect_ai` page covers the package-level surface (`eval`, `eval_retry`, `eval_set`, `Task`, `task`, etc.); the other 12 are submodules. Per-module summaries follow — each links to the canonical reference URL and lists the headline exports so you can grep before fetching.

## inspect_ai (top-level)

Core evaluation entry points and task definitions. Headline exports: `eval`, `eval_set`, `eval_retry`, `Task`, `@task`, `task_with`. This is the page to consult for the eval-orchestration surface — the functions a user calls from a script or notebook.
([`src/inspect_ai/__init__.py`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/__init__.py#L1-L44))

Source: https://inspect.aisi.org.uk/reference/inspect_ai.html
Content-hash: 7686216d
As-of: 2026-05-19

## inspect_ai.agent

Agent scaffolds and the `Agent` protocol. Headline exports: `react`, `human_cli`, `deepagent`, `bridge` (multi-agent composition), plus the protocol type itself. Pair with `ukgovernmentbeis-inspect-ai-agents.md` for the conceptual treatment.
([`src/inspect_ai/agent/__init__.py`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/agent/__init__.py#L1-L64))

Source: https://inspect.aisi.org.uk/reference/inspect_ai.agent.html
Content-hash: 883f70ef
As-of: 2026-05-19

## inspect_ai.analysis

DataFrame-based analytics on completed eval runs. Headline exports: `evals_df`, `samples_df`, `messages_df`, `events_df`. These return pandas frames over the contents of `.eval` log files; use them when post-hoc slicing or aggregating across many runs.
([`src/inspect_ai/analysis/__init__.py`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/analysis/__init__.py#L1-L91))

Source: https://inspect.aisi.org.uk/reference/inspect_ai.analysis.html
Content-hash: 978e23a6
As-of: 2026-05-19

## inspect_ai.approval

Tool-call approval policies. Headline exports: `auto_approver`, `human_approver`, plus policy-config types (`ApprovalPolicy`, `Approval`, `ApprovalDecision`). Drives the `--approval` CLI flag and the in-process approval hook chain.
([`src/inspect_ai/approval/__init__.py`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/approval/__init__.py#L1-L19))

Source: https://inspect.aisi.org.uk/reference/inspect_ai.approval.html
Content-hash: 0648a29a
As-of: 2026-05-19

## inspect_ai.dataset

Sample IO and the `Sample` / `Dataset` shapes. Headline exports: `csv_dataset`, `json_dataset`, `hf_dataset` (Hugging Face), `Sample`, `FieldSpec`, `RecordToSample`, `Dataset`, `MemoryDataset`. Common parameters across readers: `shuffle`, `seed`, `limit`, `name`. All readers accept local paths, S3 URIs, and HTTPS URLs.
([`src/inspect_ai/dataset/__init__.py`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/dataset/__init__.py#L1-L27))

Source: https://inspect.aisi.org.uk/reference/inspect_ai.dataset.html
Content-hash: d8f87cd4
As-of: 2026-05-19

## inspect_ai.event

The structured-event timeline that `.eval` logs are made of. Headline exports: `ModelEvent`, `ToolEvent`, plus traversal helpers (`event_tree`, `event_sequence`, `event_tree_walk`) for walking the event tree. Also exports `Timeline`, `TimelineEvent`, `TimelineSpan`, and build/dump/filter helpers. This is the API the log viewer and analysis frames consume.
([`src/inspect_ai/event/__init__.py`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/event/__init__.py#L1-L88))

Source: https://inspect.aisi.org.uk/reference/inspect_ai.event.html
Content-hash: ecb06e68
As-of: 2026-05-19

## inspect_ai.hooks

Lifecycle hooks fired during evaluation execution. Headline exports: `hooks` (registration decorator), `Hooks`, plus typed hook interfaces: `RunStart`, `RunEnd`, `TaskStart`, `TaskEnd`, `SampleStart`, `SampleEnd`, `SampleAttemptStart`, `SampleAttemptEnd`, `SampleInit`, `SampleScoring`, `SampleEvent`, `BeforeModelGenerate`, `EvalSetStart`, `EvalSetEnd`, `ApiKeyOverride`. Use to plug observability, custom metrics, or external side-effects into the eval loop without forking a solver.
([`src/inspect_ai/hooks/__init__.py`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/hooks/__init__.py#L1-L43))

Source: https://inspect.aisi.org.uk/reference/inspect_ai.hooks.html
Content-hash: b987c1c2
As-of: 2026-05-19

## inspect_ai.log

Programmatic read/write of `.eval` log files. Headline exports: `read_eval_log`, `write_eval_log`, `list_eval_logs`, `read_eval_log_sample`, `read_eval_log_samples`, `EvalLog`, `EvalSample`, `EvalSpec`, `EvalResults`, `EvalConfig`, `Transcript`, `transcript`, `edit_eval_log`, `recover_eval_log`. The `inspect log` CLI is a thin wrapper over this module.
([`src/inspect_ai/log/__init__.py`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/log/__init__.py#L1-L128))

Source: https://inspect.aisi.org.uk/reference/inspect_ai.log.html
Content-hash: ad6f24d5
As-of: 2026-05-19

## inspect_ai.model

The model interface. Headline exports: `get_model()` (with optional memoization and role-based selection), `Model`, `GenerateConfig` (temperature/top_p/top_k, token limits, tool-calling prefs, provider-specific options, batch/cache settings), `ChatMessage` union (`ChatMessageSystem` / `ChatMessageUser` / `ChatMessageAssistant` / `ChatMessageTool`), `Content` types (`ContentText`, `ContentReasoning`, `ContentImage`, `ContentAudio`, `ContentVideo`, `ContentDocument`, `ContentToolUse`), `execute_tools()`, `compaction()` + `CompactionStrategy` (native/edit/summary/trim), `CachePolicy`, `Logprobs`, `trim_messages()`. Provider-conversion helpers translate between Inspect and OpenAI/Anthropic/Google native formats.
([`src/inspect_ai/model/__init__.py`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/model/__init__.py#L1-L178))

Source: https://inspect.aisi.org.uk/reference/inspect_ai.model.html
Content-hash: 9aa0aeda
As-of: 2026-05-19

## inspect_ai.scorer

Scoring functions, metrics, and epoch reducers. Headline scorers: `match`, `includes`, `pattern`, `answer`, `choice`, `math`, `f1`, `exact`, `model_graded_qa`, `model_graded_fact`, `perplexity`, `target_perplexity`, `multi_scorer`. Metrics: `accuracy`, `mean`, `std`, `stderr` (with clustered-SE support), `bootstrap_stderr`, `perplexity_per_token`, `perplexity_per_seq`. Plus epoch reducers (`pass_k`, `pass_at`, `at_least`, `max_score`, `mean_score`, `median_score`, `mode_score`).
([`src/inspect_ai/scorer/__init__.py`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/scorer/__init__.py#L1-L102))

Source: https://inspect.aisi.org.uk/reference/inspect_ai.scorer.html
Content-hash: 5985df8b
As-of: 2026-05-19

## inspect_ai.solver

Prompting and solver-composition primitives. Headline exports: `generate`, `chain_of_thought`, `multiple_choice`, the `Solver` protocol, `chain()` composer, `TaskState`, `use_tools`, `system_message`, `prompt_template`, `self_critique`, `fork`, `basic_agent`.
([`src/inspect_ai/solver/__init__.py`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/solver/__init__.py#L1-L47))

Source: https://inspect.aisi.org.uk/reference/inspect_ai.solver.html
Content-hash: dcb7e05e
As-of: 2026-05-19

## inspect_ai.tool

Built-in tools and the `@tool` decorator. Headline exports: `bash`, `python`, `web_search`, `bash_session`, `computer`, `text_editor`, `think`, `web_browser`, `grep`, `list_files`, `read_file`, `memory`, sandbox-integrated tools, MCP-bridge helpers (`mcp_tools`, `mcp_connection`, `mcp_server_stdio`, `mcp_server_http`, `mcp_server_sandbox`), `ToolError`. Sandbox interactions in standard tools route through the configured sandbox runtime (see `ukgovernmentbeis-inspect-ai-sandboxing.md`).
([`src/inspect_ai/tool/__init__.py`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/tool/__init__.py#L1-L128))

Source: https://inspect.aisi.org.uk/reference/inspect_ai.tool.html
Content-hash: dd84fa30
As-of: 2026-05-19

## inspect_ai.util

Miscellaneous utilities: `Store` (per-sample state), limit primitives (`message_limit`, `token_limit`, `time_limit`, `cost_limit`, `working_limit`, `LimitExceededError`), sandbox callables (`SandboxEnvironment`, `sandbox`, `sandboxenv`), concurrency helpers (`concurrency`, `AdaptiveConcurrency`), `Subtask`/`subtask`, `checkpointer`, `EarlyStopping`, `resource`, `subprocess`, `span`, `collect`, `background`, `throttle`.
([`src/inspect_ai/util/__init__.py`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/__init__.py#L1-L179))

Source: https://inspect.aisi.org.uk/reference/inspect_ai.util.html
Content-hash: 8236d551
As-of: 2026-05-19

## See also

- `inspect-aisi-org-uk-docs-portal.md` — overall portal orientation.
- `inspect-aisi-org-uk-cli-reference.md` — the CLI side of the reference (subcommand catalog).
- `ukgovernmentbeis-inspect-ai-overview.md`, `…-tasks.md`, `…-datasets.md`, `…-solvers.md`, `…-scorers.md`, `…-models-and-providers.md`, `…-tools.md`, `…-agents.md`, `…-sandboxing.md`, `…-logs-and-analysis.md`, `…-extensions.md` — the per-topic conceptual references in this contextualizer's git-managed catalog. Use these for "how" questions; use this file's links for exact signatures.

## Crawl provenance

All 13 pages were snapshotted on 2026-05-19. Local cache: `~/.cache/skill-engine/web-doc/inspect-aisi-org-uk-2026-05-19/reference__inspect_ai.*.md`. See `_crawl-manifest.json` in that directory for the full URL→file→content_hash map.
