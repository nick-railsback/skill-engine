---
name: engine-bootstrap
description: Use when no contextualizer exists yet for a set of source URLs or local paths and one needs to be scaffolded from scratch.
---

# Engine bootstrap

Scaffold a new contextualizer in the current directory. Take a list of source
URLs or local paths from the user, auto-detect the metadata the engine needs,
stamp the matching template set into place, and exit with a 3-line message
naming the next workflow to run.

The user supplies sources. The engine fills in everything else.

## Installation layout

A contextualizer is stamped as a self-contained Claude Code project skill at:

```
.claude/skills/<slug>-context/
├── SKILL.md
├── verify.sh
├── research/
│   ├── source-paths.json
│   └── .research-state.json
└── references/   (created by /skill-engine:discover later)
```

`.claude/skills/<slug>-context/` is the **contextualizer root**. Every
engine workflow (`discover`, `refresh`, `status`, `self-audit`,
`new-reference`, `using-skill-engine`) resolves `research/...`,
`references/...`, and `verify.sh` relative to this root. The user invokes
slash commands from the project working directory (the parent of
`.claude/`); the workflows locate the root themselves.

## Activation guard

This skill assumes no contextualizer is installed under
`.claude/skills/*-context/` yet.

1. From the project working directory, look for an existing contextualizer:

   ```bash
   find .claude/skills -mindepth 1 -maxdepth 1 -type d -name '*-context' 2>/dev/null
   ```

   If any match is a non-empty directory, surface a one-line warning
   naming the path, list the files that would be overwritten, and pause
   for explicit confirmation before continuing. The condition is
   files-present, NOT a parseable `research/.research-state.json`: a
   corrupted state marker must not bypass this guard, because the
   directory may still hold a curated `SKILL.md` and a populated
   `research/source-paths.json` that stamping would overwrite. The
   `using-skill-engine` router sends both new and corrupt-marker
   directories here; either way, existing files pause for confirmation.

2. Otherwise, proceed.

## Step 1 — Intake

Accept one or more sources: positional arguments (straight to Step 2)
or, with none supplied, an interactive loop reading pasted URLs/paths
until the literal word `finish`. Intake asks exactly one content
question and zero engine-taxonomy questions — never `kind`,
`source_id`, scope, or topology directly. Recognition table,
disambiguator, and edge case are in
[`references/intake-and-detection.md`](references/intake-and-detection.md).

## Step 2 — Auto-detection

For each accepted source, compute `id`, `kind`, and topology (single-
vs multi-source) without prompting — monorepo detection is deferred to
DISCOVER. Exact slug-derivation rules per input shape are in
[`references/intake-and-detection.md`](references/intake-and-detection.md).

## Step 2.4 — Confirm branch (git-managed sources only)

Ask once per `git-managed` source which branch to monitor; non-git
sources skip this entirely. Omitting the field on a default answer
(rather than recording an explicit `main`) keeps the entry correct if
the default branch is later renamed. Prompt copy and response handling
are in [`references/intake-and-detection.md`](references/intake-and-detection.md).

## Step 2.5 — Confirm the contextualizer name (always prompted)

After Step 2 derives a slug, ask the user once for the contextualizer
name — the engine appends `-context`. A default is offered when the
sources share a useful kebab-case prefix. Default-derivation rules and
input validation are in [`references/intake-and-detection.md`](references/intake-and-detection.md).

## Step 3 — Stamping

Bootstrap writes directly to the live tree — unlike DISCOVER and
REFRESH, which stage to `<slug>-context.proposed/`, there is no
pre-existing tree to diff against. Copy `verify.sh`, the
topology-appropriate navigator template, the source-paths/
research-state templates, and the eval harness into
`.claude/skills/<slug>-context/`, creating parent directories as
needed. A rejected write gets the sandbox-block diagnostic, never a
silent skip. Per-kind entry shapes, navigator-template stamping, and
`verify.sh`'s contextualizer-flavored behavior are in
[`references/stamping-and-templates.md`](references/stamping-and-templates.md).

## Offer to seed local cache (git-managed and web-doc sources)

After stamping, offer per-source consent-gated caching: a `git clone`
per `git-managed` source, a robots-respecting crawl per `web-doc`
source. Decline leaves the source registered with an empty cache;
DISCOVER re-prompts on a later cache miss — the only network operation
bootstrap performs. Exact prompts, the atomic-clone bash, the crawl
procedure, and the manifest schema are in
[`references/cache-seeding.md`](references/cache-seeding.md).

## Step 4 — Exit

After stamping completes, render exactly five lines to the user (substitute
the actual source count, the first id, and the user-confirmed slug; for
2+ sources, use a phrasing that summarizes the set):

```
Bootstrap complete. <N> source<s?> registered: <id-1[, id-2[, ...]]>.
Contextualizer stamped at .claude/skills/<slug>-context/.
Starter eval corpus stamped at evals/ — edit it, then run evals/run-eval.sh.
Run /skill-engine:discover next — it'll scan each source and propose how to slice it.
Run /skill-engine:status anytime to see what's registered.
```

For 4+ sources, render `<id-1>, <id-2>, ... (N total)` rather than the full
list.

**State-aware next-step recommendation.** `discover` is recommended
because bootstrap's exit state (sources registered, no references
yet) is exactly its precondition: DISCOVER is goal-given and accepts
a fresh contextualizer as its first task, no separate "warm-up" step
required.

**Do NOT** in the exit message:

- Recommend a workflow whose precondition wasn't produced by bootstrap.
- Tell the user to edit `.claude/skills/<slug>-context/research/source-paths.json`
  by hand — auto-detection already populated it; manual edits are a
  fallback, not a default.
- Surface engine taxonomy (kind, topology, scope) the user wasn't asked
  about.

## Doctrine surface

The full scaffolder contract — what each stamped file means, how it evolves,
how a contextualizer transitions across major plugin revisions — is
documented in [`10-version-evolution.md`](../../docs/10-version-evolution.md). The artifact contract every
stamped file must satisfy is in [`02-artifact-contract.md`](../../docs/02-artifact-contract.md). The DISCOVER
posture (goal-given delegation) is documented in
[`08-discover-pipeline.md`](../../docs/08-discover-pipeline.md).

## What this skill does NOT do

- It does not crawl, fetch, or probe upstream for content. The only
  network operation bootstrap performs is the explicit user-consented
  `git clone` in Step 3.5, and it writes solely to
  `~/.cache/skill-engine/git-managed/<source_id>-<sha>/`. Lifecycle probes and
  content crawls belong to DISCOVER and REFRESH (see
  [`08-discover-pipeline.md`](../../docs/08-discover-pipeline.md)).
- It does not propose additional sources or expand source coverage —
  those belong to DISCOVER.
- It does not validate the existence or reachability of supplied sources at
  intake. If the user pastes a broken URL or a path that doesn't exist,
  bootstrap stamps the entry anyway and the lifecycle probe on the first
  DISCOVER run surfaces the issue. (The Step 3.5 clone offer may also
  reveal the URL is broken — but its failure mode is a one-line
  "couldn't clone" notice; it does not gate intake.) Failing fast at
  intake would force a multi-source intake to abort halfway; failing on
  DISCOVER lets the user paste the whole list and address broken entries
  in batch.
- It does not produce `kind: "external-doc"` entries. external-doc
  sources are pre-curated local markdown addressed by a contextualizer-
  internal `path` (see [`02-artifact-contract.md`](../../docs/02-artifact-contract.md#kind-external-doc)); they arrive in `source-paths.json`
  via DISCOVER or hand-edit, not via URL intake.
