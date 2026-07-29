# Handling a source that is itself a monorepo

skill-engine's freshness model treats one repository as one unit of tracking, and the monorepo adapter is the lightweight layer that lets the engine treat one giant repository as N freshness units instead of one. It exists because that unit-of-tracking assumption breaks down when a single source bundles many decoupled sub-units — a billing pipeline, an auth service, a reports dashboard — that ship on different cadences and matter to different consumers. ([`07-monorepo-adapter.md`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/docs/07-monorepo-adapter.md#L3-L5))

Left unaddressed, one-repo-equals-one-unit fails four ways in a vast monorepo: every Phase 1 SHA check returns "changed" because any commit anywhere moves HEAD (defeating the short-circuit); a single crawl cannot hold a multi-gigabyte clone in context; a revenue-critical subtree and a docs-only subtree collapse to one shared cadence; and the maintainer ends up hand-telling the engine which subtrees matter session by session. ([`07-monorepo-adapter.md`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/docs/07-monorepo-adapter.md#L7-L16))

## Contents

- Detection is deferred to DISCOVER
- Workspace-member detection and per-member expectations
- The monorepo-coverage verify heuristic (WARN, not FAIL)
- The adapter contract: monorepo-config.json and slices
- Three patterns not adopted as the contract
- Path-scoped SHA and sparse-checkout
- State-schema delta
- Per-slice CLAUDE.md
- Where the adapter does not apply
- What the adapter does not change

## Detection is deferred to DISCOVER

Bootstrap never asks whether a source is a monorepo. It infers topology from the source count alone — one source is single-source, several are multi-source — and explicitly defers the question of whether a single source is itself a monorepo with multiple workspace members to DISCOVER. Intake asks exactly one content question and zero engine-taxonomy questions, so monorepo membership is a discovery-time concern, not a bootstrap prompt. ([`engine-bootstrap/SKILL.md`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/skills/engine-bootstrap/SKILL.md#L162-L166), [`engine-bootstrap/SKILL.md`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/skills/engine-bootstrap/SKILL.md#L98-L102))

## Workspace-member detection and per-member expectations

The stamped `verify.sh` carries the engine's one monorepo-aware check, Check 6 (`monorepo-coverage`). For each registered source whose `path` resolves to a directory on disk, it globs the conventional workspace roots — `packages/`, `apps/`, `libs/`, `crates/` — and treats each top-level directory under them as a workspace member. ([`verify.sh`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/engine-bootstrap-templates/verify.sh#L979-L1003)) The per-member expectation is deliberately loose: each top-level workspace member SHOULD have at least one reference file citing it, OR an explicit skip-reason recorded in the post-run summary. The heuristic surfaces "the model missed whole packages" cases without rejecting the corpus, because the model still decides what is essential under the goal-given DISCOVER posture. ([`verify.sh`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/engine-bootstrap-templates/verify.sh#L982-L990))

## The monorepo-coverage verify heuristic (WARN, not FAIL)

A member counts as covered when some file under the contextualizer's `references/` cites it by a `(packages|apps|libs|crates)/<member>` path pattern; an uncited member registers one `[WARN]` line naming the member and its source. Crucially the failure mode is warn, not fail: uncited members do not fail `verify.sh`, they raise warnings the reviewer dispositions, so the reviewer remains the backstop trust mechanism. A clean run reports no uncited members; otherwise it still passes while registering the warning count. ([`verify.sh`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/engine-bootstrap-templates/verify.sh#L1005-L1024)) This matches how the adapter chapter frames its own guarantees — the engine's only monorepo-aware verify check is this coverage heuristic, which warns on uncited workspace members rather than machine-validating the config schema. ([`07-monorepo-adapter.md`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/docs/07-monorepo-adapter.md#L197-L201))

## The adapter contract: monorepo-config.json and slices

Beyond the verify-time backstop, the adapter's freshness machinery is declarative. A maintainer-curated `monorepo-config.json` (in the contextualizer's `research/`) is the only slice-recognition input the engine consumes; it declares each monorepo's URL and type plus a list of slices, each with a stable `id` and a set of git path patterns. A CODEOWNERS-driven bootstrap script seeds a starter config to stdout for the maintainer to review, and optional per-slice `CLAUDE.md` files shape crawl context — three composing layers, one contract. ([`07-monorepo-adapter.md`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/docs/07-monorepo-adapter.md#L18-L33), [`07-monorepo-adapter.md`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/docs/07-monorepo-adapter.md#L34-L65)) The config's own validation rules (unique URLs, unique slice ids, non-empty paths, `id` matching `^[a-z][a-z0-9_-]{0,30}$`) are upheld by the maintainer and reviewer, not enforced by the shipped `verify.sh` — the coverage heuristic above is a different concern, not a schema validator. ([`07-monorepo-adapter.md`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/docs/07-monorepo-adapter.md#L67-L76))

## Three patterns not adopted as the contract

The adapter deliberately rejects three tempting shortcuts as the slice-recognition contract. CODEOWNERS-as-contract is rejected because that file encodes who reviews, not what is conceptually distinct, so its boundaries drift from the maintainer's mental model. Workspace-tool extraction (parsing Bazel/Pants `BUILD` files, or Nx JSON) is rejected because it pulls a third-party dependency and per-tool variance into the engine. And CLAUDE.md-alone is rejected because it solves context-shaping but not freshness — Phase 1 still SHA-dirties everything and Phase 2 still clones the whole tree. ([`07-monorepo-adapter.md`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/docs/07-monorepo-adapter.md#L28-L33))

## Path-scoped SHA and sparse-checkout

Slices become first-class freshness units alongside `internal-repo` and `external-repo`. Phase 1's SHA short-circuit is restored per slice via a path-scoped SHA — the SHA of the most recent commit touching any file matching the slice's paths (a `gh` commits-by-path query) — compared against the slice's stored `last_commit_sha`; a match skips Phase 2, a mismatch promotes the slice. ([`07-monorepo-adapter.md`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/docs/07-monorepo-adapter.md#L100-L112)) A promoted slice replaces the whole-repo shallow clone with a `git sparse-checkout` scoped to the slice's paths, so the crawl loads only that slice's working tree (roughly 50 MB of billing code, not the 5 GB monorepo); each slice's findings then merge into one REFRESH proposal. ([`07-monorepo-adapter.md`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/docs/07-monorepo-adapter.md#L114-L133))

## State-schema delta

Slice resources extend the state schema additively with three fields — `slice_of` (the parent monorepo URL, used for Phase 0.5 archive-check dedup), `slice_paths` (the slice's path patterns, resolved against the sparse checkout), and `slice_id` (the stable identifier used in STATUS rendering, engine logs, and reference-catalog grouping). Pre-existing non-slice entries are unmodified, and a contextualizer with no monorepos emits no `*-slice` entries, so the schema is unchanged from the pre-adapter shape. ([`07-monorepo-adapter.md`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/docs/07-monorepo-adapter.md#L135-L161))

## Per-slice CLAUDE.md

For each declared slice the maintainer may author a `CLAUDE.md` at the slice's primary path (e.g., `packages/billing/CLAUDE.md`); Claude Code loads nested CLAUDE.md files natively, so a worker subagent crawling that slice inherits its purpose, importance, and gotchas at zero engine cost. It is opt-in — the engine reads no CLAUDE.md itself, Claude Code does — and a reasonable one runs 30-100 lines; beyond that, prefer a dedicated reference file. ([`07-monorepo-adapter.md`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/docs/07-monorepo-adapter.md#L163-L175))

## Where the adapter does not apply

The adapter overshoots for single-repo contextualizers, small collections of separate repos (well served by the plain `source-paths.json` + DISCOVER pipeline), and pre-1.0 contextualizers that should first master REFRESH, navigator skills, NEW, and STATUS on a small repo collection. The operative heuristic: if the engine's crawl routinely runs out of context budget while processing one `internal-repo` resource, you have a monorepo by the engine's definition — configure a slice and re-run. ([`07-monorepo-adapter.md`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/docs/07-monorepo-adapter.md#L177-L185))

## What the adapter does not change

The adapter adds a slice abstraction and changes nothing else about the engine's stance. Manual cadence is preserved — REFRESH still runs only when the maintainer triggers it, the adapter just makes it smarter about what to crawl. It ships no new tooling (bash, JSON, `jq`, and git's built-in `sparse-checkout` suffice), pulls no third-party dependency, adds no CI step, and does no auto-discovery — slices are declared explicitly in `monorepo-config.json`, and the CODEOWNERS bootstrap is a seed, not a runtime mechanism. ([`07-monorepo-adapter.md`](https://github.com/nick-railsback/skill-engine/blob/711e3144e1ad81b50414667b9b5e3c0363989955/plugin/skill-engine/docs/07-monorepo-adapter.md#L187-L195))

For the DISCOVER and REFRESH crawl mechanics the adapter extends, see the discover-refresh reference; for the reference invariants and the doctrine `verify.sh` enforces, see the invariants reference.
