# 01-Principles: Why this pattern works

This chapter grounds this guide in published Anthropic guidance and two specific GitHub issues that drove load-bearing design choices.
Read it once. After this, the rest of this guide will read like the inevitable consequence of these foundations rather than a list of arbitrary conventions.

The pattern is a single navigator skill (`<area-domain>-context`) plus on-demand reference files plus a manually-triggered engine.
Why this shape and not, say, twenty per-topic skills, or a single mega-skill, or a fully-automated cron job? Because each piece falls out of an Anthropic-documented best practice, and a few load-bearing choices fall out of bugs in the ecosystem you have to design around.

## The six principles this pattern implements

### 1. Goal-given task delegation

**Principle.** The engine hands the model a task ("discover the essence; write references; satisfy invariants") and validates output via deterministic checks. The model decides how to spend its context — what to read, what to skip, what to propose — within the bounds the task sets. The engine does not prescribe a fixed pipeline of stages, scoring rubrics, or worker dispatch.

**Anthropic sources:**
- [Building effective agents](https://www.anthropic.com/research/building-effective-agents) - the design space from prompt chaining to autonomous loop
- [Building agents with the Claude Agent SDK](https://www.anthropic.com/engineering/building-agents-with-the-claude-agent-sdk) - shape of a long-running agentic system
- [Claude Code subagent docs](https://docs.anthropic.com/en/docs/claude-code/sub-agents) - subagents as a tool the model can elect

**How this pattern uses it.** Each engine workflow (REFRESH, DISCOVER, SELF-AUDIT, etc.) frames the invocation as a goal: what the engine wants to be true after the run, and how `verify.sh` will check it. The model reads the registered sources, judges what to write, and surfaces a proposed diff plus a one-line rationale per file for human review. Validation happens against the proposed output via named `verify.sh` checks, not against a prescribed step-by-step pipeline.

**Heuristic for choosing when to delegate to a subagent.** "Will I need this tool output again, or just the conclusion?" If only the conclusion, the model can elect to use a subagent under its own discretion. The engine does not prescribe parallel dispatch — the workflow's task framing leaves that choice to the model.

**In your engine.** Frame each workflow as a task + invariants the engine can verify. Resist the urge to pre-script the steps the model takes between task and output. The engine's leverage is in the contract, not the recipe. (See chapter 09 for the DISCOVER pipeline as the canonical worked example.)

### 2. Token efficiency for long-running agents

**Principle.** Two main levers reduce token spend for agents that run for minutes or hours:
- **Prompt caching** - stable scaffolding (system instructions, tool definitions, project context) placed at the start of the prompt is cached for 5 minutes by default (extendable on paid tiers); subsequent requests pay ~10% token cost on cached portions and regularly land above 90% hit rates in stable-prompt workflows.
- **Filesystem reads vs. API retrieval** - when crawling source repos, clone once and use filesystem tools (`Read`, `Glob`, `Grep`) rather than calling a single-file retrieval API per file. Drastically cuts both latency and tokens.

**Anthropic sources:**
- [Claude Code cost management](https://docs.anthropic.com/en/docs/claude-code/costs)
- [Equipping agents for the real world with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) - design philosophy & lifecycle
- [Prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) - mechanics, TTL, cost reduction

**How this pattern uses it.** The engine's workflow prompts are structured **stable-first**: workflow identity, schema, tools, and protocols (cacheable) come before the volatile session-specific arguments. When crawling a GitHub Enterprise repo, the engine clones the repo to a temp directory once with depth 1 single-branch and then reads from the local checkout - typically dozens of file reads against a single clone instead of dozens of remote round-trips.

**In your engine.** Order your workflow prompts so volatile bits (today's session ID, the specific reference being updated) appear **after** the stable scaffolding. And clone-then-read for any source repo with more than a couple files of interest.

### 3. State management and checkpointing

**Principle.** Long-running agents must persist state at well-defined boundaries and replay from the last checkpoint on resume. Anthropic's April 2025 guidance on Managed Agents names dropped context between agent steps as the single most common source of flaky agent behavior.

**Anthropic sources:**
- [Managed Agents](https://www.anthropic.com/engineering/managed-agents) - checkpointing as infrastructure primitive
- [Agent Loop mechanics](https://platform.claude.com/docs/en/agent-sdk/agent-loop)

**How this pattern uses it.** State lives in committed JSON files under `research/`: `source-paths.json` (per-source schema), `.discover-cache.json` (within-session enrichment cache, see chapter 09), `.engine-stats.json` (session-level metrics), `.rejection-log.json` (proposed-but-rejected entries). The `.research-state.json` sentinel records the engine's schema version. Per-session detail files in `research/sessions/<session-id>/` capture proposals, test results, and per-file rationales. State files are updated incrementally during a session, not just as a single batch-write at the end — so a mid-session crash doesn't lose progress.

**In your engine.** Commit the state files. Make every write idempotent (re-running the same workflow produces the same result on the same inputs). Update state at meaningful boundaries (after each source is processed), not just at session end. See [03-engine.md](03-engine.md) for the full state schema.

### 4. Error handling: circuit breakers and categorization

**Principle.** Two prescriptions handle the failure modes of long-running agents:
- **Circuit breakers** halt the batch when N consecutive operations fail at the same phase. Three SHA-comparison failures in a row is a systemic issue (auth expired, rate limited, network partitioned) - not a flaky individual repo. Don't waste tokens on doomed retries; fail fast and surface to the human.
- **Error categorization** routes errors to the right response. Transient errors (HTTP 429, network timeout, DNS, expired auth token mid-run) retry with exponential backoff up to 3x. Permanent errors (archived repo, HTTP 404, schema mismatch, repo renamed) skip and report; retrying won't help.

**Anthropic sources:**
- [Building effective agents](https://www.anthropic.com/research/building-effective-agents) - graceful degradation patterns
- [Managed Agents](https://www.anthropic.com/engineering/managed-agents) - circuit breaker as infrastructure

**How this pattern uses it.** The engine's circuit-breaker rule is literal: after three consecutive same-phase failures, halt the batch and surface the current state to the human for triage. Errors are categorized at the resource-handler boundary; the error type drives the retry decision rather than a blanket "retry everything 3x" or "fail on first error."

**In your engine.** Pick a low circuit-breaker threshold (3 is a reasonable default). Build an error-type matrix as part of the workflow prompt — explicit lists of "what's transient, what's permanent" prevent the model from inventing its own retry policy. See [03-engine.md](03-engine.md) for the matrix.

### 5. Human approval gates

**Principle.** Even for autonomous-feeling agents, content-affecting changes should pass through a human review checkpoint before they land. Anthropic's permission model offers "allowed tools" (auto-approve), "disallowed tools" (hard block), and "permission mode" (interactive vs. headless) as the building blocks.

**Anthropic sources:**
- [Claude Code subagent docs](https://docs.anthropic.com/en/docs/claude-code/sub-agents) - permission modes and tool approval

**How this pattern uses it.** The engine never auto-applies changes. After crawling and proposing edits, it surfaces the diff (modified reference content, navigator catalog updates, fixture refreshes) to the human, who approves or rejects. This is deliberate - the contents of a contextualizer are the AI assistant's source-of-truth for an entire domain. Wrong content silently propagating to every consumer is a worse failure than a human spending five minutes reviewing a diff.

**In your engine.** Resist the urge to auto-merge "obviously safe" agent proposals. There is no such thing as obviously safe in a system that an AI assistant uses as ground truth. The five-minute human review is cheap insurance against a bad crawl pattern silently corrupting your knowledge base.

### 6. Pre-approval output validation

**Principle.** Before the human sees a proposed diff, the agent runs automated checks and includes their results in the diff summary. The human reviews validated work, not raw output. Failed checks block the diff from being surfaced and prompt the agent to fix-and-retry.

**Anthropic sources:**
- [Equipping agents for the real world with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) - output validation patterns

**How this pattern uses it.** Before surfacing changes, the engine runs four automated checks:
1. **Frontmatter check:** every modified reference still starts with content, not `---`
2. **Catalog bijection check:** navigator catalog rows still correspond 1:1 with primary reference files
3. **Checksum fixture refresh:** `test/fixtures/source-body-checksums.txt` is regenerated for every modified reference
4. **Test suite execution:** `test/test-cli.sh` (the source project's full test suite) passes end-to-end

If any check fails, the diff isn't surfaced; the engine fixes the issue first. This makes "engine proposed bad output" a fail-closed condition rather than a fail-to-the-human.

**In your engine.** Set up these four invariants from day one. They're cheap to assert and they protect you from an entire class of subtle agent regressions (a renamed reference that lost its catalog row, a stray frontmatter that broke loading, etc.). See [05-invariants.md](05-invariants.md) for the test implementations.

## Architecture and operational model

The six principles describe *what holds true* across this pattern. The next three sub-sections describe *the architecture and the operational knobs* you turn when standing one up: the two tiers the work is split into, the topologies that work for source roots, and the model-and-effort decisions that govern cost and quality.

### Two-tier architecture

```
+--------------+              +-------------------+
|    Engine    |  <-------->  |   Contextualizer  |
+--------------+              +-------------------+
navigator,                    per-domain
DISCOVER pipeline,            references,
release doctrine,             source paths,
templates                     catalog rows
```

The pattern is a canonical two-tier architecture. The **engine** is the maintenance system: the navigator umbrella skill, the DISCOVER discovery pipeline, the release doctrine that governs how changes land, and the templates that wire the rest together. The engine is domain-agnostic — it ships once, the same shape, regardless of what's being documented. The **contextualizer** is the per-domain customization that feeds the engine: the actual reference content for one or more domains, the source paths to crawl, the catalog rows that route the navigator. A contextualizer fits inside the engine; the engine has no opinion about what a contextualizer covers, only about how its content is shaped and maintained.

> **Vocabulary cross-walk.** "Navigator skill / primary references / companion files" (this guide's terminology) maps to "Level 1 metadata / Level 2 SKILL.md body / Level 3+ bundled references" in Anthropic's table-of-contents framing. Both vocabularies; one doctrine.

### Source-root topology

Three source-root topologies are first-class:

1. **Single-repo + single-domain** — one source repository, one domain (e.g., a single product team's API surface).
2. **Single-repo + multi-domain** — one source repository spanning multiple package boundaries, with one navigator routing across them (e.g., a monorepo with frontend + backend + ML packages).
3. **Multi-repo + multi-domain** — sibling repositories under one umbrella, with one navigator routing across them (e.g., a multi-package ecosystem published as separate clones).

Per-source-SHA propagation — the cache key the DISCOVER pipeline uses to decide what's stale — keys on **root identity**, not on whether the root is a directory inside one repo, a workspace package, or a sibling repository on disk (see [08-discover-pipeline.md](08-discover-pipeline.md) for the cache contract). Sibling packages and sibling repositories share the same DISCOVER code path with different I/O.

The source-root-topology axis is **independent** of the audience-fit / scope axis: a contextualizer can be single-domain in a monorepo, multi-domain in a monorepo, or multi-domain across many repositories. The engine prescribes neither dimension. Audience-fit (will the same reader load all of this?) is the load-bearing question; topology is plumbing. See [04-delivery.md](04-delivery.md) for scope-decision guidance.

### Model and effort selection

Engine work spans many shapes — long-horizon orchestration, narrow-scope enrichment, deterministic bookkeeping. Match the model and the thinking effort to the shape:

| Engine step | Recommended model | Effort | Rationale | Wrinkle |
|---|---|---|---|---|
| Engine REFRESH / DISCOVER workflow | Opus 4.7 | `effort: high` | Long-horizon multi-step coordination; cost of a wrong step compounds. | Adaptive thinking is the only mode on 4.7; the model decides when to think. |
| Architecture decisions / multi-file refactor planning | Opus 4.7 | `effort: xhigh` or `max` | Wide search space; planning errors fan out across files. | Same adaptive-only constraint as above. |
| DISCOVER (goal-given delegation) | Opus 4.7 | `effort: high` | The engine hands the model a task and validates output via the four reference invariants and `verify.sh`. Long-horizon corpus reasoning, partition decisions, and post-run summary all live in one pass. | Adaptive thinking is the only mode on 4.7; the model decides when to think. |
| Routine reference-doc generation from a sharp plan | Haiku 4.5 | manual `budget_tokens` | Mechanical writing against a clear spec; speed and cost dominate. | Haiku does NOT support adaptive thinking; configure `budget_tokens` explicitly. |
| Final QA / risk-sensitive review | Match the engine model | parity | The reviewer should be at least as capable as the author. | — |
| Status updates / file moves / deterministic bash | Haiku 4.5 | no thinking | No reasoning needed; latency and cost dominate. | — |

**Wrinkles to plan around.** Adaptive thinking is the only mode on Opus 4.7 — the model decides when to spend thinking tokens, and manual `budget_tokens` returns 400. Thinking tokens are **billed even when not surfaced** in the response, so a high effort setting is a cost decision as well as a quality decision. Haiku 4.5 does not support adaptive thinking at all; if you want it to think, configure `budget_tokens` explicitly per call.

There is one platform footgun worth knowing: the `model` parameter on Claude Code agent-tool calls is sometimes silently ignored, falling back to the parent model.[^model-override] When this matters, the env-var overrides — `ANTHROPIC_DEFAULT_HAIKU_MODEL` and `ANTHROPIC_DEFAULT_SONNET_MODEL` — are the most reliable mechanism, since they take effect at process boot and bypass the fragile per-call pass-through.

[^model-override]: [Issue #47488](https://github.com/anthropics/claude-code/issues/47488) — `model` parameter sometimes silently ignored on agent-tool calls.

## Two GitHub issues that drove specific design choices

These aren't "principles" - they're load-bearing bugs in the Claude Code platform that the pattern explicitly works around. Knowing about them prevents you from making choices that will silently break later.

### Issue #22345 - disable-model-invocation ignored for plugin-distributed skills

**The bug.** When a skill is distributed as part of a Claude Code plugin (rather than installed directly into `.claude/skills/`), the `disable-model-invocation: true` frontmatter flag is parsed but has no effect. All plugin skills are forced into the model context regardless of the flag setting. Open as of this writing. [Link](https://github.com/anthropics/claude-code/issues/22345)

**What it would have meant for this pattern.** The "obvious" navigator design uses `disable-model-invocation: true` to keep the navigator out of the system prompt entirely (0 tokens) and have it loaded only when the user explicitly invokes it. With the bug, that doesn't work for plugin-installed skills.

**The decision this drove.** The navigator skill avoids `disable-model-invocation` entirely. It uses **only** the two standard frontmatter fields - `name` and `description` - and accepts ~100 tokens of system-prompt overhead so the skill auto-discovers reliably across all distribution channels (plugin, CLI, Desktop). 100 tokens is a rounding error; broken auto-discovery is a hard failure.

**In your engine.** Don't use `disable-model-invocation`. Don't add other non-standard frontmatter fields. Stick to `name` and `description`, and craft the description to be just specific enough to fire on your domain queries without false positives. (See [02-artifact-contract.md](02-artifact-contract.md) for description-quality discussion.)

**If/when this resolves.** If [Issue #22345](https://github.com/anthropics/claude-code/issues/22345) closes upstream and `disable-model-invocation: true` becomes load-bearing for plugin-distributed skills, the navigator could adopt the flag and shed the ~100 tokens of system-prompt overhead - at the cost of moving from auto-discovered to user-invoked-only. The trade-off would shift, and the engine's stance on `disable-model-invocation` would tighten in that direction; today, reliable auto-discovery across distribution channels outranks the token saving. Revisit cadence: review every release boundary.

### Issue #46594 - Plugin update silent failures

**The bug.** The plugin update mechanism in Claude Code (`/plugin marketplace update`) has known silent-failure modes. Users have no in-product signal when an update is available, and updates can fail without surfacing an error. [Link](https://github.com/anthropics/claude-code/issues/46594)

**What it would have meant for this pattern.** A plugin-only distribution strategy would mean some users get stuck on stale versions of the contextualizer indefinitely, with no way to know.

**The decision this drove.** The pattern keeps a CLI installer as a first-class delivery surface alongside the plugin marketplace. The CLI is reliable, scriptable, and gives the user explicit `-update` and `-version` commands. The plugin marketplace is added convenience for users already in Claude Code, not the only path. Combined with version metadata embedded in the installed navigator skill itself, users can tell whether they're current.

**In your engine.** Ship a CLI even if you also publish to the plugin marketplace. The CLI is your insurance against plugin-marketplace flakiness. See [04-delivery.md](04-delivery.md) for CLI structure.

### Frontmatter discipline (the load-bearing constraint)

The navigator skill's frontmatter has exactly two fields:

```yaml
---
name: <area-domain>-context
description: Answers questions about the <area-domain> ecosystem. Use when working with <topic-list>.
---
```

That's it. No `version`, no `tags`, no `tools`, no `disable-model-invocation`, no custom fields.

**Strict adherence to this is critical.** `name` and `description` are the open standard's two required fields, per the [Agent Skills open standard (agentskills.io)](https://agentskills.io/spec). Custom fields are silently dropped by some consuming platforms and respected by others, producing platform-divergent behavior that you'll spend hours debugging. `disable-model-invocation` is a trap (see Issue #22345 above).

The `description` is load-bearing for skill discovery. A vague description means the agent never fires the skill. A too-broad description means the agent fires it on irrelevant queries. Description quality is product-quality.

### Reference files have NO frontmatter at all

The reference files (the on-demand content the navigator points at) are plain Markdown with **no** frontmatter. This is enforced by an automated test (see [05-invariants.md](05-invariants.md)). A stray `---` at the top of a reference file breaks the navigator's loading model - discipline this from the start.

## Why this constellation works together

Each principle and design choice individually is mundane. Together they form a self-reinforcing pattern:

* **Frontmatter discipline + the two issue workarounds** keep the pattern's distribution working across every platform users might be on.
* **Goal-given task delegation** keeps the maintenance cost of a 30-reference contextualizer linear, not exponential, because the engine's contract framing lets the model spend its context on what matters rather than on a fixed pipeline.
* **Token efficiency** (caching + local reads) makes weekly maintenance cycles cost cents instead of dollars, which keeps the manual cadence sustainable.
* **State management** lets you resume from a crash mid-crawl without re-doing work, which is what makes a manual cadence acceptable in the first place.
* **Error handling and circuit breakers** prevent a flaky upstream from burning the whole maintenance budget on retries.
* **Human approval gates** keep the contextualizer's content trustworthy as ground truth.
* **Pre-approval validation** catches the mistakes the human reviewer wouldn't notice.

Pull any one out and the pattern degrades sharply. This guide's job is to keep them together.

[Next: 02-artifact-contract.md - Navigator + reference shape, frontmatter discipline, progressive disclosure](02-artifact-contract.md)