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

## How to search this navigator

Every reference is filename-prefixed by its source slug — `<source-slug>-<topic>.md`. To find references for a given source, scan only that source's Catalog section; the prefix discrimination keeps sources visually separated even when filenames are listed together.

A `Tags` column on each catalog row marks references that span multiple sources (`cross-cutting`) or call out unusual entry points. Use tags to triangulate when a question doesn't cleanly belong to one source — a `cross-cutting` row usually links sideways via the reference's `## See also` block.

See [`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md) for the filename-prefix-discrimination contract.

## How to follow source links

References pin source URLs to specific commit SHAs (for git-managed sources), crawl dates (for external-doc and web-doc sources), or content hashes (for web-doc). Follow links as written — the SHA, crawl date, or content hash is the version the reference was authored against. If a reference needs "current state" instead of "authored state," its prose says so explicitly. Stable version tags (`vN.M`, `vN.M.P`) are accepted equivalently to commit SHAs.

## Markdown style for generated references

Reference files use **soft wrapping**: one paragraph per line, no hard line breaks at fixed column widths. Editors and rendered Markdown reflow at viewport width. Do not insert manual line breaks within a paragraph to keep lines under ~80 columns — that produces mid-sentence breaks in rendered output and makes diffs noisier. Code blocks, tables, bullet lists, and headings follow their own rules; this directive applies to prose paragraphs only.

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

## Progressive disclosure

References prioritize curated insight over re-specifying upstream sources:

* **Gotchas, cross-system patterns, and "why" context** are kept in the reference (curation value).
* **Exact schemas, API signatures, and parameter lists** are summarized in the reference and linked to their authoritative source via source URLs.

When a reference includes a source URL pointer, follow it only when the reference's own summary didn't cover the question. The contextualizer is optimized for the common case; the upstream source is the long tail.

## Optional SKILL.json sibling

This navigator MAY ship an optional `SKILL.json` sibling alongside this `SKILL.md` for machine-readable consumers (opt-in additive — contextualizers without it pass verification unchanged). When present, per-source `## Catalog: <source-slug>` rows below, SKILL.json `catalog[]` entries, and `references/<source-slug>-*.md` files must stay in three-way correspondence. Entries carrying `"draft": true` in SKILL.json are excluded from the trijection and surface as a one-line summary at verify time. The `skill-json-trijection` named check fires only when SKILL.json is present; absence is a silent-skip pass.

Full schema: see [`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md) §"SKILL.json".

## Catalog

## Catalog: ukgovernmentbeis-inspect-ai

| Reference | Description | Tags |
|---|---|---|
| [ukgovernmentbeis-inspect-ai-overview](references/ukgovernmentbeis-inspect-ai-overview.md) | What Inspect is, install, hello-world eval, sub-package surface area. | |
| [ukgovernmentbeis-inspect-ai-tasks](references/ukgovernmentbeis-inspect-ai-tasks.md) | `Task` + `@task`, options, parameterized tasks, `task_with`, packaging. | |
| [ukgovernmentbeis-inspect-ai-datasets](references/ukgovernmentbeis-inspect-ai-datasets.md) | `Sample` shape, built-in loaders, custom readers, sandbox file seeding. | |
| [ukgovernmentbeis-inspect-ai-solvers](references/ukgovernmentbeis-inspect-ai-solvers.md) | Solver protocol, built-in components, `chain`, composite `@solver`, `TaskState`. | |
| [ukgovernmentbeis-inspect-ai-scorers](references/ukgovernmentbeis-inspect-ai-scorers.md) | Built-in scorers, model-graded scorers, metrics, epoch reducers, `pass_k`, custom `@scorer`. | |
| [ukgovernmentbeis-inspect-ai-models-and-providers](references/ukgovernmentbeis-inspect-ai-models-and-providers.md) | Uniform model API, `GenerateConfig`, provider catalog, per-provider quirks. | |
| [ukgovernmentbeis-inspect-ai-tools](references/ukgovernmentbeis-inspect-ai-tools.md) | `@tool`, standard tools, MCP tools, custom tools, `ToolError`. | |
| [ukgovernmentbeis-inspect-ai-agents](references/ukgovernmentbeis-inspect-ai-agents.md) | `Agent` protocol, ReAct, Deep Agent, multi-agent, bridge, human agent. | |
| [ukgovernmentbeis-inspect-ai-sandboxing](references/ukgovernmentbeis-inspect-ai-sandboxing.md) | Sandbox runtimes, compose patterns, `sandbox()` callable, tool approval. | |
| [ukgovernmentbeis-inspect-ai-logs-and-analysis](references/ukgovernmentbeis-inspect-ai-logs-and-analysis.md) | `.eval` log format, viewer, dataframe API, Inspect Scout. | |
| [ukgovernmentbeis-inspect-ai-eval-sets](references/ukgovernmentbeis-inspect-ai-eval-sets.md) | `eval_set`, retry/resume mechanics, scanners, limits, cancelled runs. | |
| [ukgovernmentbeis-inspect-ai-cli-and-config](references/ukgovernmentbeis-inspect-ai-cli-and-config.md) | `inspect` subcommands, config precedence, `.env`, env vars, `-T`/`-M` args. | |
| [ukgovernmentbeis-inspect-ai-extensions](references/ukgovernmentbeis-inspect-ai-extensions.md) | Five extension points (model APIs, sandboxes, approvers, storage, hooks). | |

## Catalog: inspect-aisi-org-uk

| Reference | Description | Tags |
|---|---|---|
| [inspect-aisi-org-uk-docs-portal](references/inspect-aisi-org-uk-docs-portal.md) | Rendered docs portal — orientation, what's unique to the portal vs the repo, top-level navigation. | `cross-cutting` |
| [inspect-aisi-org-uk-api-reference](references/inspect-aisi-org-uk-api-reference.md) | Per-module summary of the 13 `inspect_ai.*` Python API pages — exact signatures, exports, with links to the canonical reference URLs. | |
| [inspect-aisi-org-uk-cli-reference](references/inspect-aisi-org-uk-cli-reference.md) | Per-subcommand summary of the 11 `inspect <cmd>` CLI pages — flag groups, defaults, sub-subcommands. | |
