# skill-engine is a Claude Code plugin that scaffolds and maintains contextualizers over your codebase

skill-engine turns the repositories and docs of a domain into a reusable Claude skill: it registers each source in `source-paths.json`, clones it to `~/.cache/skill-engine/` on your confirmation, and generates a *contextualizer* skill that loads its index on demand and answers from it. ([`README.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/README.md#L7-L10))

This is the start-here orientation for the whole engine: what a contextualizer is, where one installs, the lifecycle that builds and maintains it, how it answers a question at runtime, and where the deep contracts live in the sibling references.

## Contents

- [What skill-engine is](#what-skill-engine-is)
- [The contextualizer mental model](#the-contextualizer-mental-model)
- [Three install levels](#three-install-levels)
- [The workflow lifecycle](#the-workflow-lifecycle)
- [How a contextualizer answers at runtime](#how-a-contextualizer-answers-at-runtime)
- [Repo layout at a glance](#repo-layout-at-a-glance)
- [Where deeper detail lives](#where-deeper-detail-lives)

## What skill-engine is

skill-engine is operational infrastructure layered on Anthropic's published Agent Skills spec — multi-source synthesis, drift detection, reviewer gates, and a self-audit layer the bare spec never provided; the README's own framing is "if pip is the operational layer on top of Python's packaging PEPs, skill-engine is that layer for Anthropic's skill-directory pattern." ([`README.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/README.md#L49-L59))

It ships as one Claude Code plugin. The repo root is a plugin *marketplace* named `skill-engine-marketplace` that declares a single plugin, `skill-engine`, at version 0.5.0. ([`.claude-plugin/marketplace.json`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/.claude-plugin/marketplace.json#L1-L15)) The plugin manifest declares zero hooks; that hook-free shape is asserted in CI. ([`plugin.json`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/plugin/skill-engine/.claude-plugin/plugin.json#L12-L21))

You install it with `/plugin marketplace add nick-railsback/skill-engine` then `/plugin install skill-engine@skill-engine-marketplace`, which stamps the engine's commands under `/skill-engine:`; from there `engine-bootstrap` plus `discover` gets you a working contextualizer in about twenty minutes. ([`README.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/README.md#L177-L187), [`quickstart.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/plugin/skill-engine/docs/quickstart.md#L1-L24))

## The contextualizer mental model

A contextualizer is a small Claude skill at `.claude/skills/<slug>-context/`, made of four parts: a navigator `SKILL.md` (small, always loaded), a `references/` directory of markdown files loaded on demand, `research/source-paths.json` holding the registered sources, and a stamped `verify.sh` that audits the artifact. ([`CAPABILITIES.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/CAPABILITIES.md#L86-L92), [`11-walkthrough.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/plugin/skill-engine/docs/11-walkthrough.md#L188-L207))

The navigator is the routing layer: it carries a catalog that maps each reference back to the sources it draws from and describes *when* to consult a reference rather than *what* it contains, with every reference pinned to the source commit it was drawn from. ([`README.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/README.md#L20-L24))

Two shape rules matter from the start: `SKILL.md` carries a two-field frontmatter (`name` and `description` only), reference files carry NO YAML frontmatter and open with an `# H1`, and the catalog rows form a bijection with the reference files — every row points at a real file and every primary file has a row. ([`11-walkthrough.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/plugin/skill-engine/docs/11-walkthrough.md#L209-L214))

The plugin writes only inside the contextualizer's own directory (the context files plus a `verify.sh` you or CI run to audit it), clones registered git sources to `~/.cache/skill-engine/` only after a per-source opt-in prompt that defaults to *no*, and reads only the paths registered in `source-paths.json` — nothing else on disk, nothing over the network beyond those clones. ([`README.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/README.md#L189-L205))

## Three install levels

The `using-skill-engine` router searches for a contextualizer at three roots in order: the user level `~/.claude/skills/`, the local-user level `~/.claude/local/skills/`, and the project level `<repo>/.claude/skills/`; `research/.research-state.json` is the canonical setup-state marker that tells the router a contextualizer has been bootstrapped. ([`using-skill-engine/SKILL.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/plugin/skill-engine/skills/using-skill-engine/SKILL.md#L14-L27))

## The workflow lifecycle

The core loop is `engine-bootstrap` → `discover` → `review` → `apply`: bootstrap scaffolds the skeleton, discover reads the sources and stages a proposal, review drives a predict-then-compare sign-off, and apply promotes it. DISCOVER and REFRESH never touch the live tree — they stage into a sibling `<slug>-context.proposed/` directory, and only `apply` writes live (or `discard` drops the proposal). ([`quickstart.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/plugin/skill-engine/docs/quickstart.md#L46-L90))

The maintenance agent presents a six-item menu — REFRESH, SKILL, NEW, STATUS, DISCOVER, SELF-AUDIT — and the plugin surface adds two more entry points beyond those workflows: `engine-bootstrap` (one-time scaffolder) and `clean-cache` (opt-in cache deletion), all wired into a four-stage local-clone cache lifecycle (seed, REFRESH GC, STATUS listing, clean-cache). ([`03-engine.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/plugin/skill-engine/docs/03-engine.md#L42-L73))

The full slash-command catalog, one line each (deep per-command contracts live in the `workflows` and `discover-refresh` references):

- `engine-bootstrap` — scaffold a fresh contextualizer skeleton from one or more source URLs or local paths.
- `discover` — goal-given reference generation: read the sources and stage references that satisfy the four invariants.
- `refresh` — drift-triggered re-emission: re-check SHAs and stage updated references for review.
- `new-reference` — register and draft one new reference without a full discover pass.
- `review` — inspect a staged proposal and drive the predict-then-compare sign-off in `REVIEW.md`.
- `apply` — promote a signed-off proposal into the live contextualizer via atomic per-file rename.
- `discard` — drop a staged proposal without promoting it.
- `self-audit` — run eight read-only drift checks on the artifact.
- `status` — read-only freshness dashboard: fresh, stale, or critical references.
- `clean-cache` — opt-in deletion of the local clone cache (dry-run by default).
- `config-set` — set an engine-wide config value (currently the `review` diff tool).
- `using-skill-engine` — router for "do something with the engine here" intent; dispatches by contextualizer state.

([`CAPABILITIES.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/CAPABILITIES.md#L706-L726), [`plugin/skill-engine/README.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/plugin/skill-engine/README.md#L1-L15))

## How a contextualizer answers at runtime

At query time the navigator scans its catalog for the matching reference(s), opens them on demand, and answers from that corpus — citing the source file and the commit SHA behind each load-bearing claim, as the worked answer in the README shows. ([`README.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/README.md#L20-L45))

The payoff is auditable, offline grounding in one local read plus multi-source synthesis: when a question touches several sources at once, the navigator composes their per-domain contextualizers and holds the tensions between them rather than reading them in sequence — no per-query web fetch, every claim traceable to a reviewed snapshot at a fixed commit. ([`CAPABILITIES.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/CAPABILITIES.md#L1-L12))

## Repo layout at a glance

The doctrine chapters live under `plugin/skill-engine/docs/` as numbered files (e.g. `03-engine.md`), and the twelve workflow skills live under `plugin/skill-engine/skills/`, each invokable as `/skill-engine:<skill>`; a hand-rolled install instead pastes `engine-bootstrap-templates/maintenance-agent.md.template` as a system prompt. ([`03-engine.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/plugin/skill-engine/docs/03-engine.md#L14-L23))

Worked contextualizers ship under `examples/` (`langchain-context`, `modelcontextprotocol-python-sdk-context`, `inspect-ai-context`) as structural templates — replace every word, keep the shape — while the repo-root `docs/` holds usage-modes and case-studies for recognizing your own situation before adopting the engine. ([`11-walkthrough.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/plugin/skill-engine/docs/11-walkthrough.md#L188-L216), [`docs/usage-modes.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/docs/usage-modes.md#L1-L23))

The whole stack is bash + git + `jq` — no Node, no scheduler — and manual, reviewer-in-the-loop cadence is the deliberate default. ([`README.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/README.md#L206-L214))

## Where deeper detail lives

Five sibling references carry the contracts this overview only sketches: principles (the six Anthropic goal-given-delegation principles the engine design draws on), artifact-contract (the `SKILL.md`/reference shape, `source_id` derivation, and bijection), invariants (the four reference invariants and the `verify.sh` gate), discover-refresh (the DISCOVER/REFRESH mechanics, staging, and cache lifecycle), and workflows (the full slash-command catalog with per-command review gates). ([`03-engine.md`](https://github.com/nick-railsback/skill-engine/blob/8594b2a2a905b5786df17717435cab0b872e3760/plugin/skill-engine/docs/03-engine.md#L2-L12))
