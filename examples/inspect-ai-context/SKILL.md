---
name: inspect-ai-context
description: "Answers questions across the configured sources. References load on demand from references/. Use when working in any of this contextualizer's source domains."
---

# Context navigator (multi-source)

## Overview

This navigator catalogs references for **multiple sources** the engine has been pointed at. Each source's references are catalogued in their own `## Catalog: <source-slug>` section below; references live in `references/<source-slug>-<topic>.md` so the filename prefix discriminates sources at-a-glance.

The navigator's standing instructions stay small; references load only when relevant to the current question. The catalog itself is a TOC and is excluded from the standing-instructions budget, so additional sources and rows can be added without trimming prose.

When asked a question:

1. Identify which source the question is about — see "How to search this navigator" below.
2. Scan that source's **Catalog** section for the matching topic.
3. Follow the link to read the reference file.
4. If the question spans multiple sources, consult the **Cross-source map**.

## Claims policy

Cite by default, and make load-bearing claims verifiable:

1. **Inline-cite every load-bearing claim with its SHA-pinned permalink** — the `https://github.com/<owner>/<repo>/blob/<sha>/<path>#L<start>-L<end>` link the reference gives for that fact (versions, defaults, signatures, deprecations, behavior a user could get wrong by guessing). Put the permalink inline, on the claim. Use a bare filename parenthetical (e.g. `(<source-slug>-<topic>.md)`) only when the reference genuinely provides no permalink. This inline permalink is what the grounded-citation eval (SELF-AUDIT Check 8) grades.
2. Don't cite orientational prose — *"what is X?"*, *"when did X launch?"* — answer those from this navigator alone; opening a reference is itself a citation gesture.
3. End with a one-line provenance footer, emitted italic, formatted `*References consulted: foo.md, bar.md. Grounded in {{LIBRARY}}@{{VERSION}} — [reference index]({{INDEX_URL}}).*` The footer is a **summary of what you read — not a substitute** for the inline permalinks on the claims. Tokens are agent-substituted at answer time (they appear literally in the stamped `SKILL.md`); across multiple sources, `{{LIBRARY}}` resolves to the source slug(s) the answer drew from, or every registered slug when no reference was opened.
4. If no reference was opened, say so in the footer (*"Answered from general knowledge — no {{LIBRARY}} references consulted"*) — never fake it.

The voice is competent and careful — no "as an AI assistant" hedging.

## How to search this navigator

Every reference is filename-prefixed by its source slug — `<source-slug>-<topic>.md`. To find references for a given source, scan only that source's Catalog section; the prefix discrimination keeps sources visually separated even when filenames are listed together.

A `Tags` column on each catalog row marks references that span multiple sources (`cross-cutting`) or call out unusual entry points. Use tags to triangulate when a question doesn't cleanly belong to one source — a `cross-cutting` row usually links sideways via the reference's `## See also` block.

See [`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md) for the filename-prefix-discrimination contract.

## How to follow source links

References pin source URLs to specific commit SHAs (for git-managed sources), crawl dates (for external-doc and web-doc sources), or content hashes (for web-doc). Follow links as written — the SHA, crawl date, or content hash is the version the reference was authored against. If a reference needs "current state" instead of "authored state," its prose says so explicitly. Stable version tags (`vN.M`, `vN.M.P`) are accepted equivalently to commit SHAs.

## Cross-source map

*(populated as cross-cutting references accumulate)*

## Instructions to Claude

When loading a reference file, the path syntax depends on the platform:

* **Claude Code**: `Read $CLAUDE_SKILL_DIR/references/<source-slug>-<topic>.md`
* **Claude Desktop**: `Read references/<source-slug>-<topic>.md`

Loading rules:

* Load one reference at a time unless the Cross-source map says to load both.
* Pick the catalog section by source first; topic second.
* If the primary reference doesn't fully answer the question, follow any source URL pointers it provides for deeper detail.
* Do not eagerly load companion files; only follow companion links when the primary reference says to.
* If the user's question is clearly out of scope for any registered source, don't invoke this skill at all.

## Catalog

## Catalog: ukgovernmentbeis-inspect-ai

| Reference | Description | Tags |
|---|---|---|
| [ukgovernmentbeis-inspect-ai-overview](references/ukgovernmentbeis-inspect-ai-overview.md) | Covers what Inspect is (an open-source Python framework for LLM evals by the UK AI Security Institute), how to install it, the canonical hello-world Task example, and the full sub-package surface area — read this first when orienting to the repo or helping users get started. |  |
| [ukgovernmentbeis-inspect-ai-tasks](references/ukgovernmentbeis-inspect-ai-tasks.md) | Covers the Task class and @task decorator as Inspect's fundamental evaluation unit — bundling dataset, solver, scorer, and all optional configuration (epochs, sandbox, approval, limits, checkpointing, early stopping). Read this when constructing or parameterizing tasks, applying task_with() overrides, understanding the four-layer configuration precedence, exposing solver parameters, or packaging tasks for distribution. |  |
| [ukgovernmentbeis-inspect-ai-datasets](references/ukgovernmentbeis-inspect-ai-datasets.md) | Covers the full dataset contract in Inspect: the Sample Pydantic model and every field it carries (input, target, choices, id, metadata, sandbox, files, setup, checkpoint), the four built-in loaders (CSV, JSON/JSONL, Hugging Face, example), FieldSpec/record_to_sample field mapping, MemoryDataset for custom readers, filtering/shuffling/slicing knobs, and sandbox file-seeding patterns. |  |
| [ukgovernmentbeis-inspect-ai-solvers](references/ukgovernmentbeis-inspect-ai-solvers.md) | Covers the Solver protocol and Generate callable that every Inspect evaluation is built on, the complete set of built-in solver components (generate, system_message, prompt_template, chain_of_thought, self_critique, multiple_choice, use_tools), the chain() compositor and @solver decorator for composite plans, and the TaskState data structure that every solver mutates. Includes concrete patterns for custom solvers, intermediate scoring, and the decision boundary between plain solvers and the Agent interface. |  |
| [ukgovernmentbeis-inspect-ai-scorers](references/ukgovernmentbeis-inspect-ai-scorers.md) | Comprehensive reference for Inspect AI's built-in and model-graded scorers, the Score/Value/Metric type hierarchy, epoch reducers (including pass_at and pass_k), custom @scorer and @metric decorators, multi-value and multi-scorer patterns, and the inspect score CLI workflow. Covers exact/heuristic matchers, statistical metrics (accuracy, stderr, grouped), and sandbox-aware scoring. |  |
| [ukgovernmentbeis-inspect-ai-models-and-providers](references/ukgovernmentbeis-inspect-ai-models-and-providers.md) | Uniform model API (`get_model`, `Model`, `ModelAPI`) that normalizes 20+ inference backends behind one interface, plus the full `GenerateConfig` knob surface, the provider catalog with per-provider quirks and model args, adaptive-connections concurrency, batch mode, and reasoning-model effort/history/summary controls. |  |
| [ukgovernmentbeis-inspect-ai-tools](references/ukgovernmentbeis-inspect-ai-tools.md) | Covers every layer of Inspect's tool system: the `@tool` decorator and factory pattern, standard built-in tools (bash, python, web_search, text_editor, computer, web_browser, agentic helpers, and intervention tools ask_user/notify_user), MCP server integration via stdio/HTTP/sandbox transports, custom tool authoring (signatures, `ToolError`, `ToolResult`, `ToolDef`, `tool_with()`), parallel execution opt-in, stateful tools with `store_as()`, tool-choice control, and the default vs. explicit error-handling contract. |  |
| [ukgovernmentbeis-inspect-ai-agents](references/ukgovernmentbeis-inspect-ai-agents.md) | Covers the Inspect `Agent` protocol and all built-in agents: ReAct loop, Deep Agent (subagent delegation, memory, planning), multi-agent composition via handoffs and `as_tool`, the Agent Bridge for external frameworks, the Human Agent for baselining, and Agent Intervention (ACP) for real-time bidirectional human-agent control including operator interrupt/redirect and agent-initiated questions and notifications. Includes implementation details, configuration options, limits, and gotchas drawn directly from source and docs. |  |
| [ukgovernmentbeis-inspect-ai-sandboxing](references/ukgovernmentbeis-inspect-ai-sandboxing.md) | Covers sandbox runtimes (local, docker, k8s, and pip-installable extensions), compose patterns for multi-service CTF-style evals, the sandbox() callable and its full method surface, file seeding, resource limits, and the tool-approval policy system (human/auto approvers, custom approvers via @approver, ToolCallViewer) that gates tool execution before it reaches any sandbox. |  |
| [ukgovernmentbeis-inspect-ai-logs-and-analysis](references/ukgovernmentbeis-inspect-ai-logs-and-analysis.md) | Covers the `.eval` log format, the `EvalLog` Python object, all log-reading/writing/editing APIs, the `inspect view` log viewer (including live view, bundling, and publishing), the `inspect_ai.analysis` dataframe API (`evals_df`, `samples_df`, `messages_df`, `events_df`, column groups, `prepare()` operations), and the Inspect Scout transcript scanner. Authoritative source for working with evaluation artifacts after a run completes. |  |
| [ukgovernmentbeis-inspect-ai-eval-sets](references/ukgovernmentbeis-inspect-ai-eval-sets.md) | Covers `eval_set` / `inspect eval-set` for running multi-task, multi-model benchmark sweeps with automatic retry/resume mechanics, Inspect Scout scanner integration, per-sample and scoped limits (time, token, cost, message, working), early stopping, and error-handling discipline including crash recovery and cancelled-run scoring. |  |
| [ukgovernmentbeis-inspect-ai-cli-and-config](references/ukgovernmentbeis-inspect-ai-cli-and-config.md) | Complete reference for the `inspect` CLI: every subcommand registered in `_cli/main.py`, the full configuration-precedence chain (built-in default → Task arg → env var → .env file → --run-config → CLI flag → eval() kwarg), INSPECT_* environment variables, .env file loading semantics, and the -T/-M/-S task/model/solver argument shortcuts. |  | <!-- nosemgrep: skill-content-eval -->
| [ukgovernmentbeis-inspect-ai-extensions](references/ukgovernmentbeis-inspect-ai-extensions.md) | The five Inspect extension points — model APIs, sandboxes, approvers, storage, and hooks — all wired through setuptools entry points so third-party packages register on equal terms with built-in providers. Covers decorator signatures, lifecycle rules, required class methods, and operational controls (INSPECT_REQUIRED_HOOKS, enabled(), API key override). |  |

## Catalog: inspect-aisi-org-uk

| Reference | Description | Tags |
|---|---|---|
| [inspect-aisi-org-uk-docs-portal](references/inspect-aisi-org-uk-docs-portal.md) | Orientation to the rendered docs portal at inspect.aisi.org.uk — what is unique to the portal (auto-generated Python API reference, CLI reference, and evals catalog) versus the backing repo, and the top-level navigation across User Guide, Reference, Extensions, and Evals sections. | `cross-cutting` |
| [inspect-aisi-org-uk-api-reference](references/inspect-aisi-org-uk-api-reference.md) | Per-module summary of the 13 inspect_ai.* Python API pages at inspect.aisi.org.uk/reference/ — exact signatures, headline exports, and return types, with SHA-pinned source links; read this file to answer 'what does this function take' / 'what does this class hold' questions before fetching a full reference page. |  |
| [inspect-aisi-org-uk-cli-reference](references/inspect-aisi-org-uk-cli-reference.md) | Per-subcommand summary of the 11 inspect <cmd> CLI pages — flag groups, defaults, sub-subcommands, with links to the canonical reference URLs and the backing _cli source files. Each subcommand maps to a Click command defined in src/inspect_ai/_cli/ at pinned SHA 033745ddbc. |  |

## Markdown style for generated references

Reference files use **soft wrapping**: one paragraph per line, no hard line breaks at fixed column widths. Editors and rendered Markdown reflow at viewport width. Do not insert manual line breaks within a paragraph to keep lines under ~80 columns — that produces mid-sentence breaks in rendered output and makes diffs noisier. Code blocks, tables, bullet lists, and headings follow their own rules; this directive applies to prose paragraphs only.

## Progressive disclosure

References prioritize curated insight over re-specifying upstream sources:

* **Gotchas, cross-system patterns, and "why" context** are kept in the reference (curation value).
* **Exact schemas, API signatures, and parameter lists** are summarized in the reference and linked to their authoritative source via source URLs.

When a reference includes a source URL pointer, follow it only when the reference's own summary didn't cover the question. The contextualizer is optimized for the common case; the upstream source is the long tail.

## Optional SKILL.json sibling

This navigator MAY ship an optional `SKILL.json` sibling alongside this `SKILL.md` for machine-readable consumers (opt-in additive — contextualizers without it pass verification unchanged). When present, per-source `## Catalog: <source-slug>` rows above, SKILL.json `catalog[]` entries, and `references/<source-slug>-*.md` files must stay in three-way correspondence. Entries carrying `"draft": true` in SKILL.json are excluded from the trijection and surface as a one-line summary at verify time. The `skill-json-trijection` named check fires only when SKILL.json is present; absence is a silent-skip pass.

Full schema: see [`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md) §"SKILL.json".
