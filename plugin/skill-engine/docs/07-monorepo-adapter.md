# 07 — Monorepo adapter

This chapter covers the **monorepo adapter**: a lightweight layer the engine uses to treat one giant repository as N freshness units instead of one. It exists because the engine's freshness model — designed for many small repos — breaks down when one logical repo bundles many decoupled sub-units (the billing pipeline, the auth service, the reports dashboard) that ship on different cadences and matter to different consumers.

The adapter's contract is a single declarative configuration file (`monorepo-config.json`). The on-ramp is a CODEOWNERS-driven bootstrap script. The context-shaping channel is per-slice `CLAUDE.md` files that Claude Code reads natively. None of these are new engine machinery; they are recipe-grade additions that compose with the existing pipeline.

## 7.1 The pain — why one-repo-equals-one-unit breaks at scale

The engine's freshness model — described in [`03-engine.md`](03-engine.md) — treats one repository as one unit of tracking. In a vast monorepo (Google/Meta-style or Bazel/Pants/Nx workspace), the unit-of-tracking assumption breaks four ways:

- **Phase 1 false positives.** Any commit anywhere in the monorepo changes the HEAD SHA, so every Phase 1 check returns "changed" — the entire tree gets promoted to Phase 2 every cycle, defeating the SHA-comparison short-circuit that the engine relies on as its highest-leverage optimization.
- **Crawl context overflow.** A single crawl session assigned to a multi-gigabyte monorepo can't hold the full clone in attention. The engine's optimizations assume *many small repos*, not *one giant repo with a single SHA*.
- **Importance heterogeneity within a repo.** A monorepo's billing subtree may be revenue-critical while its examples subtree is documentation-only. The state schema's per-resource cadence and any importance-scoring proposals built on top of it assume one repo equals one cadence/importance unit. They don't compose with intra-repo heterogeneity.
- **Maintainer-as-priors-oracle.** In production the maintainer ends up explicitly hand-telling the engine which subtrees matter, how to weight them, and how to slice the crawl. That is a UX failure — the priors should be *declarative configuration*, not session-by-session prompt engineering.

The adapter addresses all four by introducing **slices** as a first-class freshness unit alongside `internal-repo` and `external-repo`.

## 7.2 The hybrid — three layers, one contract

The adapter's design is a **hybrid** of three composing layers:

1. **The engine's contract — `monorepo-config.json`.** A maintainer-curated JSON file in the contextualizer's `research/` directory declaring the slices. This is the *only* slice-recognition input the engine consumes. Predictable, version-controlled, audit-trail-via-git-diff.
2. **The on-ramp — CODEOWNERS bootstrap.** A drop-in template script `bootstrap-monorepo-config.sh.template` (find at `plugin/skill-engine/engine-bootstrap-templates/bootstrap-monorepo-config.sh.template` in your installed plugin, or at <https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/engine-bootstrap-templates/bootstrap-monorepo-config.sh.template>) reads a repo's `.github/CODEOWNERS` and emits a starter `monorepo-config.json` to stdout. The maintainer reviews and edits before committing. Day-one effort drops from "author the schema from scratch" to "review and refine the seed."
3. **The context-shaping channel — per-slice `CLAUDE.md`.** A documentation guideline (not an engine feature). The maintainer authors `<slice-path>/CLAUDE.md` files at the slice's primary path; Claude Code's native nested-context mechanism delivers them to the engine's crawl session automatically.

**Why this shape.** The contract layer gives the engine one well-defined input it can predicate against. The bootstrap layer softens the day-one cost without locking the engine to CODEOWNERS semantics — the file is a seed, not the contract. The context-shaping layer handles the "tell the agent which subtrees matter" pain at zero engine cost.

Three patterns explicitly **not adopted** as the engine's contract:

- **CODEOWNERS as the contract.** The file encodes *who reviews*, not *what is conceptually distinct*. CODEOWNERS-as-contract pins slice boundaries to a file authored for a different purpose; over time the boundaries drift away from the maintainer's mental model.
- **Workspace-tool extraction (Bazel / Pants / Nx).** Parsing `BUILD` files (Bazel, Pants) requires the workspace tool itself — a third-party dep the engine deliberately avoids. Nx files (JSON) are tractable with `jq`, but the per-tool variance pushes the maintenance cost from the maintainer to the engine. Future work, possibly Nx-only.
- **CLAUDE.md alone, no engine change.** Solves the context-shaping problem; does NOT solve the freshness problem. Phase 1 still SHA-dirties everything; Phase 2 still clones the whole tree.

## 7.3 The schema — `monorepo-config.json`

The schema is documented in full at `monorepo-config.json.template` (find at `plugin/skill-engine/engine-bootstrap-templates/monorepo-config.json.template` in your installed plugin, or at <https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/engine-bootstrap-templates/monorepo-config.json.template>). Required structure:

```json
{
  "version": "1.0",
  "monorepos": [
    {
      "url": "https://<your-git-host>/<your-org>/big-monorepo",
      "type": "internal-repo",
      "slices": [
        {"id": "billing", "paths": ["packages/billing/**", "shared/billing-types/**"]},
        {"id": "auth",    "paths": ["packages/auth/**", "services/auth-api/**"]},
        {"id": "reports", "paths": ["apps/reports-dashboard/**"]}
      ]
    }
  ]
}
```

**Field semantics.**

| Field | Required | Purpose |
|---|---|---|
| `version` | yes | Schema version. `1.0` initially. |
| `monorepos[].url` | yes | The parent monorepo's URL — same shape as the existing `resources[].url`. |
| `monorepos[].type` | yes | `internal-repo` or `external-repo`. The slice resources inherit this. |
| `monorepos[].slices[].id` | yes | Short stable identifier. Used in engine logs and STATUS rendering. Unique within the parent. |
| `monorepos[].slices[].paths` | yes | Array of git path patterns. Glob syntax follows `git sparse-checkout` rules. |

Optional documentation fields (`owner_team`, `notes`, `weight`) are recognized by the schema and ignored by the engine in v1; they exist for the maintainer's own audit trail and for future importance-scoring work.

**Validation rules** (the schema `monorepo-config.json` must satisfy — these are **not** currently enforced by the shipped `verify.sh`. The only monorepo-aware check it ships is the `monorepo-coverage` *heuristic* (Check 6), which warns when a workspace member is uncited — a different concern, not a schema validator. Treat the rules below as the config contract the maintainer and reviewer uphold; template source: `plugin/skill-engine/engine-bootstrap-templates/verify.sh`):

- Top-level `monorepos[]` is an array.
- Each `monorepos[].url` is unique within the file.
- Each slice's `id` is unique within its monorepo's `slices[]`.
- Each slice has at least one path; paths are non-empty strings.
- Slice `id` matches `^[a-z][a-z0-9_-]{0,30}$` — same constraint as reference filenames.

Two locations are valid: `<project-root>/monorepo-config.json` (engine-self-contextualizer case) and `<project-root>/research/monorepo-config.json` (the canonical contextualizer location). The verify check inspects both. Absent file is the default — most contextualizers are not monorepos.

## 7.4 The bootstrap — CODEOWNERS to starter config

The bootstrap script lives at `bootstrap-monorepo-config.sh.template`. It is **POSIX bash**, takes a repo-path argument, reads CODEOWNERS, and emits a seeded `monorepo-config.json` to stdout.

```bash
bash bootstrap-monorepo-config.sh.template /path/to/checked-out/monorepo > research/monorepo-config.json
```

Three CODEOWNERS shapes the script handles:

1. **Absent CODEOWNERS** (no `.github/CODEOWNERS` file present): emits a stub `monorepo-config.json` with one example slice entry and an inline comment explaining the maintainer must edit before use.
2. **Present-but-empty CODEOWNERS**: same as case 1 — emits a stub.
3. **Present-and-populated CODEOWNERS**: emits one slice entry per CODEOWNERS section, with `id` derived from the section/team name (kebab-cased, lowercased) and `paths` populated from the section's path patterns.

**What the bootstrap is NOT.** It is a *seed*, not a final configuration. The maintainer is expected to:

1. Review the emitted slices.
2. Merge paths that belong together (CODEOWNERS often splits one logical unit across many lines).
3. Drop slices that aren't worth tracking as separate units.
4. Add `weight`, `notes`, or `owner_team` fields where useful.

The script writes to stdout (not to a file) so the maintainer redirects deliberately and reviews the output before committing. Manual cadence preserved.

## 7.5 Phase 1 — path-scoped SHA (slice-aware freshness)

The engine's existing Phase 1 SHA-comparison short-circuit assumes one repo, one HEAD SHA. For slices, the equivalent is the **path-scoped SHA**: the SHA of the most recent commit that touched any file matching the slice's path patterns.

GitHub's commit-by-path API returns this directly:

```bash
gh api "repos/<your-org>/<repo>/commits?path=<slice-path>&per_page=1" --jq '.[0].sha'
```

The engine compares the path-scoped SHA against the slice's stored `last_commit_sha`. Match → skip Phase 2 for this slice. Mismatch → promote to Phase 2 with the slice's `paths` list. A monorepo with N slices produces up to N path-scoped queries per session.

**Parent-monorepo dedup.** The Phase 0.5 archive-status check (does the parent repo still exist, is it readable) runs once per session and is cached for every slice that points at the same parent. Path-scoped SHAs are NOT cached across slices — each slice has its own.

## 7.6 Phase 2 — sparse-checkout (slice-scoped clone)

For slices promoted to Phase 2, the engine replaces the unconditional shallow clone with a **sparse-checkout** scoped to the slice's paths. The outline:

```bash
mkdir -p /tmp/<area-domain>-research-<session-id>/<repo-name>
cd /tmp/<area-domain>-research-<session-id>/<repo-name>
# Add `--branch <branch-value>` to the line below when the parent
# sources[] entry carries a `branch` field; omit otherwise.
git clone --filter=blob:none --no-checkout --depth=1 --single-branch <repo-uri> .
git sparse-checkout init --no-cone
git sparse-checkout set <slice-path-1> <slice-path-2> ...
git checkout
```

When the parent `sources[]` entry carries a `branch` field, add `--branch <branch-value>` to the `git clone` command as the inline comment above indicates. Absent the field ⇒ clone the upstream default branch. Slices inherit the parent's branch field today; a per-slice override is deferred.

The engine processes slices independently (or in clusters of slices that share a parent, where the model judges context budgets permit). Each slice's crawl reads only its sparse working tree.

The result: the crawl of the billing slice loads ~50 MB of billing-relevant code, not the 5 GB monorepo. Context fits; findings are tightly scoped; per-slice findings merge into one REFRESH proposal at the end.

## 7.7 State-schema delta — three additive fields

Slice resources extend the existing state schema with three additive fields. Pre-existing `internal-repo` / `external-repo` entries remain unmodified; the engine treats `slice_of` as authoritative when present.

```json
"resources": [
  {
    "url": "https://<your-git-host>/<your-org>/big-monorepo",
    "type": "internal-repo-slice",
    "slice_of": "https://<your-git-host>/<your-org>/big-monorepo",
    "slice_paths": ["packages/billing/**", "shared/billing-types/**"],
    "slice_id": "billing",
    "last_crawled": "2026-04-20T09:08:17Z",
    "last_commit_sha": "0123456a"
  }
]
```

| Field | Purpose |
|---|---|
| `slice_of` | The parent monorepo's URL. Same shape as `monorepo-config.json` `monorepos[].url`. The engine uses this for Phase 0.5 dedup. |
| `slice_paths` | The slice's path patterns, copied from the engine-config schema's `monorepos[].slices[].paths` for storage independence. The runtime resolves these against the sparse-checkout. |
| `slice_id` | The slice's stable identifier, copied from the engine-config schema's `monorepos[].slices[].id`. Used in STATUS rendering, engine logs, and reference catalog grouping. |

**Naming clarification.** The state-schema fields (`slice_of`, `slice_paths`, `slice_id`) are NOT identical to the engine-config fields. The engine-config schema has `monorepos[].slices[].id` and `monorepos[].slices[].paths` (top-level `version` and per-monorepo `url`/`type`). The state-schema's `slice_id`/`slice_paths` are the runtime copies of those engine-config values; `slice_of` has no engine-config counterpart — it is purely a state-schema field referencing the parent monorepo URL at artifact time.

Backward compat: a contextualizer that has zero monorepos in `monorepo-config.json` (or no file at all) emits no `*-slice` entries; the state schema is unchanged from the pre-adapter shape.

## 7.8 Per-slice `CLAUDE.md` — context-shaping at consume time

For each slice declared in `monorepo-config.json`, the maintainer SHOULD consider authoring a `CLAUDE.md` file at the slice's primary path (e.g., `packages/billing/CLAUDE.md` for the billing slice). Claude Code reads nested CLAUDE.md files additively: files from the working directory and above load at launch; subdirectories load as work descends into them.

Worker subagents dispatched against a slice's paths inherit the slice's CLAUDE.md context automatically. This is the cheapest way to:

- Tell the agent the slice's *purpose* ("this is the billing pipeline; flow goes invoice→ledger→payouts").
- Flag *importance* ("this slice is the system's revenue path; weight findings here heavily").
- List *gotchas* ("the events emitted here have schemas that don't match other parts of the monorepo; trust the local types").

**Authoring a per-slice CLAUDE.md is opt-in.** The engine doesn't read CLAUDE.md directly — Claude Code does. The engine doesn't require any CLAUDE.md. Per-slice context just makes crawl findings more accurate when the slice has non-obvious conventions.

A reasonable per-slice CLAUDE.md is 30–100 lines. Beyond that, consider a dedicated reference file in the contextualizer instead — references are first-class engine artifacts; CLAUDE.md is contextualizer-author tooling.

## 7.9 Where this adapter does NOT apply

Three cases where the adapter overshoots:

1. **Single-repo contextualizers.** Most contextualizers track many small repos — the engine's original shape. For these, the adapter is irrelevant; the existing pipeline works as documented.
2. **Small repo collections.** A handful of repos that aren't a monorepo. These are well-served by the existing `source-paths.json` + DISCOVER pipeline; no adapter is needed. The Virtual Monorepo Pattern (a `.repos` bash script + a single root `CLAUDE.md`, popularized in 2026 community write-ups) is the contextualizer-author-side answer for many-separate-repos.
3. **Pre-1.0 contextualizers.** A contextualizer in its first three months should master REFRESH, navigator skills, NEW, and STATUS on a small repo collection before adopting monorepo machinery. The doctrine echoes the chapter labeling for DISCOVER itself: *adopt when the simpler engine is mature*.

If you are unsure whether your repo qualifies as a monorepo for engine purposes, the heuristic is: **if the engine's crawl routinely runs out of context budget while processing one of your `internal-repo` resources, you have a monorepo by the engine's definition.** Configure a slice and re-run.

## 7.10 What the adapter does NOT change

The adapter adds a slice abstraction; it does not redesign anything else.

- **Manual cadence is preserved.** REFRESH still runs when the maintainer triggers it. The adapter just makes REFRESH smarter about what to crawl.
- **No new tooling.** Bash + JSON + `jq` are sufficient for the schema, the bootstrap, and the verify check. `git sparse-checkout` is built into git.
- **No third-party deps.** Nothing the adapter ships requires a package manager, a workspace tool, or a third-party library.
- **No CI step.** The verify check runs manually via `bash verify.sh` (the consumer's contextualizer-side script), same as every other check.
- **No auto-discovery.** Slices are declared explicitly in `monorepo-config.json`. The bootstrap is a seed, not a runtime mechanism.

## 7.11 Forward pointers

The adapter is **read** by the `maintenance-agent.md.template` (find at `plugin/skill-engine/engine-bootstrap-templates/maintenance-agent.md.template` in your installed plugin, or at <https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/engine-bootstrap-templates/maintenance-agent.md.template>). The adapter's config schema is **not** machine-validated by the consumer-stamped `verify.sh`; the engine's only monorepo-aware check is the `monorepo-coverage` heuristic (Check 6), which warns on uncited workspace members. Schema conformance for `monorepo-config.json` is upheld by the maintainer and reviewer. The adapter is **bootstrapped** by `bootstrap-monorepo-config.sh.template`. The adapter is **shaped** by per-slice `CLAUDE.md` files the maintainer authors in their monorepo.

For the freshness model the adapter extends, see chapter `08-discover-pipeline.md`. For the discovery configuration that the adapter sits alongside, see chapter `09-discover-config.md`. For end-to-end usage, see the walkthrough chapter `11-walkthrough.md`.
