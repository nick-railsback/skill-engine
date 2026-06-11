# 03-Engine

This chapter is the engine itself. The engine is a system prompt the maintainer activates in a fresh Claude Code session; it crawls upstream sources, detects drift between references and their sources, proposes content updates to the artifact, and runs pre-approval validation. It always stops short of writing changes without a human review.

This chapter covers the engine's anatomy, workflows, freshness algorithms, error handling, and pre-approval validation contract.

If you have fewer than 5 references, you can probably maintain them manually.
Past that, you need an engine not because the work is too hard, but because the cognitive load of "remembering which references need attention this week" is what bit-rots the contextualizer.
The engine's primary job is to be the thing that notices drift, not the thing that fixes it.

The engine design draws directly on the six Anthropic principles from [01-principles.md](01-principles.md).
Re-reading that chapter is the best preparation for this one.

## Where the engine lives

The engine is a system prompt the maintainer activates in a fresh Claude Code session.
There is no daemon, no cron job, no service to deploy.
A human starts the engine by invoking the plugin (or, for a hand-rolled install, by reading the maintenance-agent template and asking the model to act on it).

Two install shapes:

* **Plugin install (recommended).** Install `plugin/skill-engine/` via the Claude Code plugin marketplace; the twelve skills (`using-skill-engine`, `engine-bootstrap`, `discover`, `refresh`, `new-reference`, `review`, `apply`, `discard`, `status`, `self-audit`, `clean-cache`, `config-set`) are invokable as `/skill-engine:<skill>`.
* **Hand-rolled.** Commit a copy of `plugin/skill-engine/engine-bootstrap-templates/maintenance-agent.md.template` to your contextualizer's repo (e.g., as `agents/maintenance-agent.md`); the maintainer pastes the file's prose into a fresh Claude Code session as the system prompt.

## Activation

Activation is a single sentence in a fresh Claude Code session:

```
/skill-engine:using-skill-engine
```

(Or, for the hand-rolled install: read the maintenance-agent template and activate it.)

The model reads the prompt, internalizes the engine's role, and presents a menu. From there, the human picks a workflow.

The activation pattern is intentionally low-tech - no special CLI, no SDK boilerplate.
The engine's "infrastructure" is the model's ability to follow a system prompt. Anything fancier is something else to maintain.

**Engine doctor (extended activation).** Three baseline checks (auth, state file, test suite) plus three drift checks: temp-dir survivors from prior crashed sessions, state-schema version match, and orphan session logs newer than the state file. Surfaces findings and asks before proceeding rather than auto-cleaning — the in-progress detritus might represent legitimate work. The maintenance-agent template ([`maintenance-agent.md.template`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/engine-bootstrap-templates/maintenance-agent.md.template)) carries the bash-line equivalents.

## The menu (six workflows)

The agent presents six workflows on activation:

| Name | What it does | Typical cadence |
|---|---|---|
| **REFRESH** | Full freshness sweep across all tracked resources; updates whichever references have drifted | Weekly |
| **SKILL** | Targeted update of a single reference (faster than REFRESH for focused work) | Ad-hoc, when working on one topic |
| **NEW** | Register new resources and create a new primary reference from scratch | When your domain grows a new topic |
| **STATUS** | Dashboard of freshness state - which references are fresh, stale, or critical | Quick check, no edits |
| **DISCOVER** | Goal-given delegation: the engine hands the model a task (discover the essence; write references; satisfy the four invariants) and validates output via `verify.sh` — no Stage 1/2/3 worker dispatch, no fixed keystroke menu | Quarterly or when the catalog-vs-asks gap widens (mature contextualizers, ~1+ year in production); fresh contextualizers welcome on first run |
| **SELF-AUDIT** | Eight drift checks: stale-date, broken-URL, long-untouched, catalog-vs-content, cross-reference-vs-content, review-state staleness, paragraph→permalink density, grounded-citation rate. Read-only by default; surfaces findings then offers a per-run opt-in propose-approve gate for the deterministic ones (stale-date, catalog drift, review-state staleness). The other five remain advisory; the grounded-citation eval is itself opt-in (paid API calls) | Every 2-4 weeks; pair with DISCOVER on the same day for a quarterly rhythm |

Plus an **EXIT** option that dismisses the agent.

DISCOVER's full surface — the goal-given posture, the post-run summary contract, the optional local-clone cache, and the persisted state shape — lives in dedicated chapters: [08-discover-pipeline.md](08-discover-pipeline.md) (the one-pager) and [09-discover-config.md](09-discover-config.md) (`source-paths.json` schema). DISCOVER is worth adopting once your contextualizer is mature (~1+ year in production) and the gap between "what's in the catalog and what people are asking about" has started to widen — though the first run on a fresh contextualizer is welcome too.

### Plugin entry points and the cache lifecycle

The six workflows above are the **agent-side** menu the maintenance agent presents at activation. The **plugin-side** surface — when the engine is consumed as `plugin/skill-engine/` rather than as a hand-rolled `agents/maintenance-agent.md` — exposes two additional entry points beyond the six workflow skills:

* **`/skill-engine:engine-bootstrap`** — the scaffolder workflow that stamps a new contextualizer skeleton into `.claude/skills/<slug>-context/`. Used once at the start of a contextualizer's life, then never invoked again.
* **`/skill-engine:clean-cache`** — the opt-in destructive deletion path for the optional local clone cache at `~/.cache/skill-engine/`. Dry-runs by default; deletes only after the user replies with the literal word `yes`.

The persistent local-clone cache runs through a four-stage **cache lifecycle**:

* **Seed** — `engine-bootstrap` Step 3.5 prompts the user y/N (default N) once per `kind: git-managed` source at scaffold time; DISCOVER pre-flight step 6 re-prompts on cache miss. On `y`, the skill clones via an atomic-rename idiom (`<source_id>-<sha>.tmp.$$/` → `mv` to the canonical name on success). The engine does not clone without consent.
* **REFRESH GC** — garbage-collects sibling `git-managed/<source_id>-*/` directories on SHA advance (cache stays current as upstream moves).
* **STATUS** — surfaces the cache as a read-only listing (cache stays visible to the author).
* **`clean-cache`** — the all-at-once opt-in deletion path (cache yields disk on demand).

Nothing in DISCOVER, REFRESH, or any other workflow invokes `clean-cache` automatically — the deletion gesture is reserved for the user. The full cleanup contract lives in [`09-discover-config.md`](09-discover-config.md) §"Cleanup contract"; the seed half lives in [`09-discover-config.md`](09-discover-config.md) §"Optional local clone cache".

## Cache layout (per-kind subdirectories)

```
~/.cache/skill-engine/
├── git-managed/<source_id>-<sha>/
└── web-doc/<source_id>-<crawl_id>/
    ├── _crawl-manifest.json
    └── <slugified-url-path>.md
```

Cache root is `${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}`. The
`SKILL_ENGINE_CACHE_ROOT` override exists for tests and for users with
non-default XDG cache configuration.

### `crawl_id` derivation

```
crawl_id = sha256(sorted-page-urls || concatenated-page-content-hashes)[:8]
```

Stable across re-crawls when content is unchanged (no churn). New
directory on every content shift.

### Migration from old flat layout

Earlier engine versions stored cache directly at
`~/.cache/skill-engine/<source_id>-<sha>/`. <!-- doctrine:legacy-cache-layout --> REFRESH's pre-flight detects
this layout and offers a one-shot bulk `mv` of all flat entries into
`~/.cache/skill-engine/git-managed/`, prompted once per session. Decline →
those entries are re-cloned on the next REFRESH that walks them. See
[refresh/SKILL.md § pre-flight step 1.5](../skills/refresh/SKILL.md) for
the canonical procedure.

## Anatomy: how the engine works

Under the goal-given delegation principle (see [01-principles.md](01-principles.md#1-goal-given-task-delegation)), the engine hands the model a task and validates the output. The model decides how to spend its context — what to read, what to skip, what to propose — within the bounds the task sets. When the model elects to crawl in parallel via subagents (a common choice for multi-source workflows), the following patterns apply.

**Concurrency cap.** Limit in-flight subagents (10 is a reasonable default). Higher concurrency is rarely faster - clone-and-crawl is bottlenecked on git operations, not model latency.

**Dispatch is streaming, not batched-waves.** With a concurrency cap of 10, the model dispatches a new subagent as soon as any in-flight one finishes - capped only by the semaphore. The alternative — *batched-waves dispatch* — would wait for **all** subagents in wave N to complete before starting wave N+1; the streaming pattern dispatches as soon as one slot opens. Streaming minimizes idle time when latency varies, which is the common case for crawls: some references take seconds, others take a minute or more.

**Tool isolation.** Subagents the model dispatches should only have the tools they need: `Read`, `Glob`, `Grep` against their assigned local clone. They should *not* have write or shell access. Restrictive permissions mean a misbehaving subagent is bounded.

**Why delegate at all.** The model's main-thread token budget would explode if it had to read every file across every repo itself. Pushing the file reads into subagents - whose conclusions, but not whose tool-call churn, return to the main thread - keeps the main thread focused on synthesis and decision-making. This is the principle from Anthropic's [Building effective agents](https://www.anthropic.com/research/building-effective-agents). The engine sets the contract; the model decides when delegation is the right move.

## Freshness checks

Not every tracked resource needs to be re-crawled every cycle. The engine staircases through three checks of increasing cost, dropping out at the first check that confirms freshness:

### Phase 0.5: Archive detection
For every tracked source, check whether it's been archived (or otherwise flagged dead) by the upstream platform.

* **Check:** Source-platform API call (e.g., `gh api repos/<your-org>/<repo>` looking at the `archived` boolean) or HTTP HEAD on a web resource.
* **Why it's first:** Cheapest check (one HTTP call); short-circuits the whole pipeline for dead resources before any cloning or SHA work.
* **Action if archived:** Remove the resource from active tracking; flag in the proposed diff that this resource is dead and the reference content sourced from it should be reviewed for staleness.

### Phase 1: SHA comparison
For every still-active repository, compare the upstream SHA at the tracked ref against the `last_commit_sha` stored in your state file.

* **Check:** Lightweight API call (e.g., `gh api repos/<your-org>/<repo>/commits/<ref>`) returning just the commit SHA. The `<ref>` resolves from the source-paths.json entry: when the entry carries a `branch` field, that branch is the ref; otherwise the ref is `HEAD` (the upstream repo's default branch). A named branch that no longer exists upstream is a permanent error — surface the diagnostic, transition `lifecycle.state` to `unknown`, and skip the source for this run rather than silently falling back to HEAD.
* **Action on match:** Skip this resource entirely - no clone, no read, no worker spawn. The reference cannot have drifted because the source hasn't changed.
* **Action on mismatch:** Promote to Phase 2 (clone + crawl).
* **Why it works:** A surprisingly large fraction of resources are unchanged between cycles. SHA comparison is the highest-leverage optimization in the pipeline.

**Per-source SHA capture (cache write-path).** When a Phase 1 mismatch promotes a source to Phase 2, the engine captures the source-root commit SHA via `git -C <source-clone-path> rev-parse HEAD` for each tracked source root. The captured SHA is logically the same value as `last_commit_sha` in the state schema below; it is also persisted in the per-source enrichment cache (`research/.discover-cache.json`) as additive `source_sha` and `source_root` fields on each `<source_file_hash>` record. Reference emitters read `source_sha` back from the cache to render SHA-pinned permalinks (see [02-artifact-contract.md#sha-pinned-permalinks-the-canonical-form](02-artifact-contract.md#sha-pinned-permalinks-the-canonical-form)) at write time, without re-querying the source platform. If `source_sha` is missing for a cited file (e.g., the file was cached before SHA propagation was enabled), the emitter falls back to omitting the link and surfaces a verification finding rather than emitting a branch-pinned URL.

**Slice resources (path-scoped SHA).** When the contextualizer declares slice resources via `monorepo-config.json`, Phase 1 substitutes the parent monorepo's HEAD SHA with a *path-scoped* SHA — the SHA of the most recent commit that touched any file matching the slice's path patterns. This restores the SHA-comparison short-circuit for slices in a vast monorepo where the parent HEAD changes constantly. See [`07-monorepo-adapter.md`](07-monorepo-adapter.md) §7.5 for the recipe.

*(For non-git resources (web pages, document platforms), substitute a date-based staleness gate - e.g., if last-crawled was within 10 days. Less precise than SHA, but the same short-circuit principle.)*

### Phase 2: Local clone + crawl
For resources that survived Phase 0.5 and Phase 1:

1. Clone the repo to a temp directory with `--depth 1 --single-branch` (saves bandwidth; you don't need history)
2. Read the relevant files locally (the model may elect to delegate the read to a subagent for context isolation)
3. Extract the structured information needed for the references the resource backs
4. Return findings into the main thread for proposal-building

**Resource deduplication.** If two of your references are backed by the same upstream repo, clone once and let both references' findings come from the same pass. The engine merges per-reference findings after the fact.

**Slice resources (sparse-checkout).** For slice resources promoted to Phase 2, the engine replaces the unconditional shallow clone with a `git sparse-checkout` scoped to the slice's `paths`. The crawl reads only the slice's working tree, keeping context bounded even when the parent monorepo is multi-gigabyte. See [`07-monorepo-adapter.md`](07-monorepo-adapter.md) §7.6 for the recipe.

**`files_of_interest`-scoped sparse cloning.** When a resource's state record carries a non-empty `files_of_interest` list (see [State schema](#state-schema)), the engine substitutes a sparse-clone for the unconditional shallow clone. The pattern uses pure git, no third-party tools:

```bash
git clone --depth=1 --single-branch --filter=blob:none --no-checkout <repo-uri> /tmp/<session>/<repo>
git -C /tmp/<session>/<repo> sparse-checkout init --no-cone
git -C /tmp/<session>/<repo> sparse-checkout set <files_of_interest entries...>
git -C /tmp/<session>/<repo> checkout
```

`--no-cone` mode accepts gitignore-style patterns (`src/auth/**`, `docs/sso.md`) directly — the same mode the slice-resources path uses (`07-monorepo-adapter.md` §7.6), so the engine converges on a single sparse-checkout recipe with two activation paths (slice-config vs. per-resource state). When `files_of_interest` is empty (the field is optional), the engine falls back to the unconditional shallow clone described above — sparse-clone setup overhead dwarfs the saving on small repos, and the maintainer is the right person to opt in by populating the field.

**Post-clone validation.** After `sparse-checkout set` returns, the engine iterates each `files_of_interest` entry and confirms it resolves to at least one path inside the working tree; a missing entry is a hard failure. The error names the offending entry AND surfaces near-matching siblings via `find <repo>/<closest-existing-ancestor> -maxdepth 2` so the maintainer sees probable typo corrections inline (e.g., a typo'd `src/aught/**` resolves no files, and the validator's error reads: `files_of_interest entry 'src/aught/**' resolved no files in checkout; nearest siblings under 'src/': src/auth/, src/audit/, src/lib/`). Without this validation a typo silently produces an empty Phase 2 crawl payload — the crawl returns no findings, and the maintainer would have no signal that the entry was wrong.

## Resource-type routing

Not every resource is the same kind. The agent routes by type:

| Type | What it is | Crawl strategy | Staleness gate |
|---|---|---|---|
| `internal-repo` | Repo on your org's internal git host | Local clone + `Read`/`Glob`/`Grep` | SHA comparison |
| `external-repo` | Public repo (github.com, GitLab, etc.) | Local clone + `Read`/`Glob`/`Grep` | SHA comparison |
| `internal-repo-slice` | Path-scoped sub-unit of an `internal-repo` declared in `monorepo-config.json` | Sparse-checkout against the slice's `paths` | Path-scoped SHA |
| `external-repo-slice` | Path-scoped sub-unit of an `external-repo` declared in `monorepo-config.json` | Sparse-checkout against the slice's `paths` | Path-scoped SHA |
| `external-web` | HTTP(S) resource other than git | Web fetch | Date-based (configurable, e.g., 30 days) |
| `internal-doc-platform` | SharePoint, Confluence, Notion, etc. | Web fetch (with auth) | Date-based, often longer (e.g., 90 days for slow-moving doc platforms) |

Each type has its own handler in the agent prompt with appropriate retry/error behavior. New resource types can be added by extending this matrix. The agent prompt lists what fields each type needs in the state file.

## State schema

`research/.research-state.json` is a binary installed-sentinel:

```json
{"schema_version": 1}
```

Its sole role is letting the `using-skill-engine` router detect that
engine-bootstrap has run. The router checks **presence + JSON
parseability only** — no field inside is inspected. The sentinel
never needs to grow.

Operational state lives in four sibling files, each with its own
canonical reference:

* **`research/source-paths.json`** — per-source schema (`id`, `kind`,
  `status`, `archived`, `lifecycle`, `discovered_via`, and any additive
  fields). Canonical schema in [`02-artifact-contract.md`](02-artifact-contract.md) §"Per-source schema"; operational view in [`09-discover-config.md`](09-discover-config.md). Committed to git as the contextualizer's configuration history.
* **`research/.discover-cache.json`** — per-source-SHA enrichment
  cache, gitignored runtime state. Lookup keyed by `(source_id, sha)`.
  See [`09-discover-config.md`](09-discover-config.md) §"`research/.discover-cache.json`".
* **`research/.engine-stats.json`** — per-session telemetry; see
  [Engine effectiveness telemetry](#engine-effectiveness-telemetry) below.
* **`research/.rejection-log.json`** — denormalized rejection history;
  see [Rejection memory at activation](#rejection-memory-at-activation) below.

Earlier engine versions described a richer `.research-state.json`
schema with per-skill cadence, per-resource records, a sessions index,
and an `importance` validation contract. That schema was superseded
once persisted state migrated to the files above; the sentinel
survives as the router's installed-marker. The `importance` field
referenced in REFRESH dispatch and STATUS rendering below is an
additive per-source attribute carried on `source-paths.json` entries
when the contextualizer-author chooses to declare it; absent entries
default to neutral.

**Updates are incremental, not batched.** When a workflow finishes a
piece of crawling, lifecycle probing, or proposal validation, the
responsible workflow writes the updated state to the appropriate file
immediately. A mid-session crash does not lose progress; resuming on
the same session picks up from where the file was last flushed.

**Slice resources extend the schema additively.** When `monorepo-config.json` declares slices, the engine emits source-paths entries with three additional fields: `slice_of` (the parent monorepo URL), `slice_paths` (the slice's path patterns), and `slice_id` (the slice's stable identifier). Pre-existing non-slice entries are unmodified. See [`07-monorepo-adapter.md`](07-monorepo-adapter.md) §7.7 for the full delta.

## Pre-approval validation (the load-bearing contract)

Before surfacing any proposed change to the human reviewer, the agent runs automated checks. If any fails, the agent fixes the issue and re-runs it - never surface broken work for review.

**The checks:**

1.  **Frontmatter check:** every modified reference still starts with content (e.g., a `# Title` line), not a `---` frontmatter delimiter. Failure means the agent erroneously added frontmatter; the agent strips it and rewrites.
2.  **Catalog bijection check:** the navigator catalog rows still correspond 1:1 with `references/<area-domain>-*.md` files (see [02-artifact-contract.md](02-artifact-contract.md) for the bijection definition). Failure means the agent added a reference without adding a catalog row, or removed a file without removing its row. The agent fixes the navigator, then re-checks.
3.  **Validator execution:** your contextualizer's `./verify.sh` passes end-to-end. Failure means something about the change broke an invariant; the agent surfaces the failing check output to the human and asks for triage rather than guessing.
4.  **Checksum fixture refresh (pre-fixture-harness aspirational):** the per-reference SHA-256 fixture (`test/fixtures/source-body-checksums.txt`, see [05-invariants.md](05-invariants.md)) is the fixture-harness byte-equality contract — not yet implemented in the pre-fixture-harness state.

**Sandbox isolation.** Each validation pass runs against `/tmp/skill-engine-validate-<session-id>/` — an isolated copy of the modified surface plus the validator, not the working tree. Before the checks above run, the agent copies the full `references/` directory (so the catalog bijection check sees the complete file set), the navigator catalog, and the validator (`./verify.sh`) into the sandbox directory. The checks execute against the sandbox copy. The agent's mid-iteration fixes — repairing frontmatter, regenerating fixtures, adding missing content — operate on the sandbox copy. The working tree is byte-identical before and after validation iterates, regardless of how many fix-retry rounds the validation phase takes. On normal exit (success or failure), the sandbox is removed via `rm -rf /tmp/skill-engine-validate-<session-id>/`. `<session-id>` reuses the engine's existing format (`YYYY-MM-DDTHH-MM-SSZ-<short-suffix>`; ISO 8601 UTC with colons → hyphens, plus a 4-char random suffix) so the sandbox is correlated with the session-reflection file and the per-session state log. The implementation is `cp -R` to `/tmp/` (not `git worktree add`) per the project's bash-only constraint stack.

**Forbidden mid-iteration fixes.** Inside the sandbox, the agent's fix-retry loop may not delete a reference file, delete a navigator catalog row, delete a test, `git restore` the change being validated, or perform any in-place edit to a working-tree path (the sandbox is the only writable surface during validation iteration). Permitted mid-iteration fixes: add missing content, regenerate the per-reference SHA-256 fixture, repair frontmatter on a modified reference. If the only path to passing validation requires a forbidden fix, the agent halts and surfaces the validation failure to the human reviewer rather than masking the failure by deletion or revert. This rule is about the fix-retry loop specifically; post-halt session-level rollback (the documented `git restore` path the agent surfaces when validation halts) remains permitted because it is a documented terminal path, not a mid-iteration bypass.

**Activation-time orphan sweep.** Sandboxes left over from SIGKILL, OOM, system reboot, or any other non-graceful exit do not block normal operation; they are removed at the next agent activation by an engine-doctor check that matches `/tmp/skill-engine-validate-*` and an mtime older than 24 hours, then emits a one-line `[orphan-sweep] removed <path> (>24h orphan from non-graceful exit)` audit note per removed orphan. The 24-hour threshold is intentional: a same-day sandbox may belong to a still-active session and must not be removed. See the agent template's activation engine-doctor list for the exact `find` invocation.

**Why this matters:**
An engine that surfaces broken proposals to its human reviewer wastes the most expensive resource in the loop - the reviewer's time. Pre-approval validation moves the cost of catching trivial mistakes (forgotten catalog row, stale fixture) onto the engine, where iteration is cheap. This is the principle from Anthropic's [Equipping agents for the real world with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills): validate before the review checkpoint.

## Circuit breaker

**Rule:** After three consecutive failures at the same phase, halt the batch and surface current state to the human for triage.

Three SHA-comparison failures in a row is not three flaky repos - it's an expired auth token, a network partition, or rate limiting hitting the same endpoint. Don't waste the rest of the batch's tokens on doomed retries.

The check is *consecutive same-phase* failures. A handful of permanent-error skips spread across the batch are fine; three in a row at the same point is the trigger.

When the breaker fires, the engine:
1. Writes per-session detail to `research/sessions/<session-id>.json` (don't lose progress)
2. Surfaces the three failures to the human with diagnostics
3. Stops the batch (does not auto-resume)

The human triages, fixes the underlying issue (e.g., re-auths, waits out the rate limit), and starts a fresh engine session. Resuming from the source-paths.json last-good state.

The same threshold of three applies to a second, distinct failure mode: **validation fix-retry**. When pre-approval validation fails and the agent enters its fix-retry loop (per the sandbox-isolation contract above), the agent may attempt up to three fixes for any one proposal within the current session. On the third failed fix, the agent halts the loop for that proposal, surfaces a structured "validation halted" finding (shape detailed in the sub-section below), and continues with other queued proposals in the same session. Three consecutive failures at the same point — whether SHA-comparison phase or validation fix-retry — signals a structural issue, not a flaky transient.

### Validation fix-retry cap

**Counter key: `attempt_id`.** Each proposal carries an `attempt_id` — a UUID-v4 minted at the moment the proposal is first surfaced for validation in the current session. The ID is content-independent: editing the proposal's title, body, or paths mid-loop does NOT mint a new ID and does NOT reset the counter. A separate `proposal_id` (the SHA-256 hex digest of the proposal's canonical body, with NUL-separated inputs `title + '\0' + body + '\0' + LC_ALL=C-sorted-paths-joined-by-LF`) survives as the display/audit identifier surfaced in the structured halt finding, but is NOT used to key the counter.

**Why `attempt_id` not `proposal_id`.** A content-derived counter key (using `proposal_id` as the key) is bypass-resistant only against accidental drift; it lets a stubborn agent regenerate the counter by editing the proposal title/body/paths between fix attempts — each cosmetic edit produces a fresh hash, fresh counter, infinite retries with cosmetic differences. UUID-based `attempt_id` is bypass-resistant by construction: the ID is minted once per session-per-proposal and stays in force regardless of mid-loop edits.

**Scoping: session-bound, multi-proposal isolated.** The counter is `attempt_id`-keyed and lives only within the current agent session. At every session start, any proposal still surfaced for validation gets a fresh `attempt_id` minted; the counter starts at zero. Within a single session, the counter is keyed on the live `attempt_id` and DOES NOT reset when the maintainer edits the proposal between fix attempts. Concretely: if the maintainer hits two failed fixes today, takes a break, and resumes tomorrow on the same proposal, tomorrow's session mints a fresh `attempt_id` and the counter is 0 (not 2). Multiple proposals in the same session each carry independent `attempt_id` values; failures on one proposal do not count toward another's cap.

**Halt on the third failed fix.** When the counter for an `attempt_id` reaches three within the current session, the agent stops the fix-retry loop for THAT proposal, surfaces the structured finding (described below), and returns control to the queue. Other queued proposals continue to validate independently.

**Structured finding shape.** The halt emits a JSON object the human reviewer pipes through `jq` for triage:

```json
{
  "attempt_id": "<UUID-v4 counter key>",
  "proposal_id": "<SHA-256 hex display/audit identifier>",
  "attempts": [
    { "diff": "<unified diff of fix attempt 1>", "validator_reason": "<validator's rejection reason>" },
    { "diff": "<unified diff of fix attempt 2>", "validator_reason": "<validator's rejection reason>" },
    { "diff": "<unified diff of fix attempt 3>", "validator_reason": "<validator's rejection reason>" }
  ]
}
```

The `attempts` array is ordered chronologically by emission: `attempts[0]` is the first failed fix, `attempts[2]` is the third. `validator_reason` is a free-form string from the validator's rejection output; downstream consumers MUST NOT presume machine-comparability across reasons.

Triage shorthand: three reasons sharing a root cause ⇒ structurally infeasible proposal; three reasons spanning unrelated checks ⇒ template-ambiguity defect; three reasons referencing the upstream content ⇒ bad source-repo state.

**Canonical form for `proposal_id`.** The SHA-256 is computed by an in-process pipe directly from JSON extraction to the hasher. With the proposal JSON in file `$f`, the literal canonical pipe is:

```bash
jq -j '.title' < "$f" | { printf '\0'; jq -j '.body' < "$f"; printf '\0'; jq -j '((.paths // []) | sort | join("\n"))' < "$f"; } | shasum -a 256
```

On Linux distros that ship `sha256sum` but not `shasum`, substitute `sha256sum` for `shasum -a 256` — the digest output is byte-identical for byte-identical input. **Never** compute the canonical form via bash command substitution `$(jq -r '.title')` — command substitution strips trailing newlines from the captured value, silently colliding logically-distinct titles (e.g., `"Fix typo"` and `"Fix typo\n"`) under the same hash. The canonical algorithm preserves all input bytes (including trailing whitespace); the engine does NOT Unicode-normalize at this layer — callers MUST produce byte-stable input, or accept that NFC vs NFD representations of the same character will mint distinct `proposal_id` values.

## Error categorization

Not every error is the same. Route them:

| Category | Examples | Action |
|---|---|---|
| **Transient** | HTTP 429 (rate limit), network timeout, DNS resolution failure, Auth token expired mid-run | Retry with exponential backoff, max 3 attempts |
| **Permanent** | Repo archived, HTTP 404, repo renamed, schema mismatch in expected file format, file unreadable | Skip the resource and report it; continue the batch with the next resource |

The categorization lives in the agent prompt as an explicit matrix. Don't let the agent invent its own retry policy at runtime - it will either retry too much (transient becomes a token bonfire) or too little (permanent failures look like flakes).

## Workflow patterns (how each menu item runs)

### REFRESH (the common case)
1. Load state file
2. For every tracked skill, for every resource: run Phase 0.5 (archive check) and Phase 1 (SHA comparison)
3. For resources that survived to Phase 2: process in parallel (the model elects subagent dispatch when context isolation is warranted; capped at the concurrency limit), ordered by descending `importance` (state schema; absent ⇒ default `3`), with ties broken by lexicographic resource URL for deterministic ordering
4. Aggregate findings; identify references whose backing content has changed
5. Propose updates to those references (curated rewrites, not bulk replacement)
6. Run pre-approval validation (the four checks)
7. Surface proposed diff to human for approval
8. On approval: write changes, update per-source state in `source-paths.json`, regenerate any README freshness counters (checksum fixture refresh is pre-fixture-harness aspirational, per the pre-approval check list above)
9. On rejection: discard the proposed diff but keep the per-source SHA updates from Phase 1 (so next session knows the SHA was checked)

### SKILL (single-reference targeted update)
Same as REFRESH, but limited to one reference's resources. Faster when you're working on one topic and only want that reference re-checked.

### NEW (register a new reference)
NEW writes through the same staging gate as DISCOVER/REFRESH — it does not touch the live tree directly. It reads from `$CTX_ROOT` and writes into the sibling `$CTX_PROPOSED` (`<slug>-context.proposed/`); the proposal lands live only when the user runs `/skill-engine:apply <name>`.
1. Human provides reference name (e.g., `<area-domain>-billing`) and a list of source URLs
2. The engine crawls the resources and drafts the new reference under `$CTX_PROPOSED/references/` following the [02-artifact-contract.md](02-artifact-contract.md) conventions (manifest status `added`)
3. The engine adds the catalog row to `$CTX_PROPOSED/SKILL.md` (copy-on-write from live; manifest status `modified`)
4. If the reference covers an unregistered source, the engine registers it in `$CTX_PROPOSED/research/source-paths.json` (`modified`) as part of the same proposal
5. *(pre-fixture-harness aspirational.)* The engine appends the new reference's SHA-256 to the checksum fixture. The pre-fixture-harness state skips this step.
6. Pre-stage validation against an ephemeral merged view of live + the proposed changes, then finalize `$CTX_PROPOSED/.review/manifest.json` + `REVIEW.md` and surface the proposal for `/skill-engine:review` → `/skill-engine:apply` (or `/skill-engine:discard`)

### STATUS (read-only dashboard)
1. Load state file
2. For each skill, compute days since `last_crawled`
3. Render a table: skill name, last update, age in days, traffic-light status (fresh/stale/critical) per the cadence thresholds, importance (max over the skill's resources that carry the field; default `3` when the skill has no resources or no resource carries the field)
4. Show count of pending sessions, recently-affected skills
5. When `monorepo-config.json` is present, group slice rows under their parent monorepo, labeled by `slice_id` from the state schema's additive fields. See [`07-monorepo-adapter.md`](07-monorepo-adapter.md) §7.7 for the field semantics.
6. When `research/.engine-stats.json` is present, render "Recent sessions" (last 5 from `.engine-stats.json`) and "Approval rate" (rolling-30-day percentage). See [Engine effectiveness telemetry](#engine-effectiveness-telemetry) below for the schema and rendering contract.

No mutations. Free to run, useful as a "should I run REFRESH this week?" check.

## SELF-AUDIT (drift audit)

Read-only by default. After surfacing findings, SELF-AUDIT may offer a per-run propose → validate → approve gate that applies the **deterministic** fixes among them — see [Optional fix flow](#optional-fix-flow) below. The two HARD-GATEs (no write without explicit human approval; pre-approval validation must pass) remain in force; the workflow never writes without an explicit `y`/`APPROVE` from the human for this session.

SELF-AUDIT audits the *artifact* — the navigator, the references, the catalog — for the kinds of drift the freshness checks cannot detect on their own.

SHA comparison and clone-and-crawl find out-of-date *content*. SELF-AUDIT finds out-of-date *framing*: stale dates, dead links, references that haven't moved while their sources have, catalog rows that no longer describe what they index, cross-reference rules pointing where content used to be. Framing drift is invisible to a SHA-based pipeline because the hash of a stale reference doesn't change just because its claims have aged out.

**Eight drift checks:**

1. **Stale "as of" dates.** References commonly anchor claims to a moment in time with phrases like *"as of 2025-03-12"*. The agent greps every reference for `as of YYYY-MM-DD`-style phrases more than 180 days old and flags them for review. The phrase doesn't have to be wrong - just stale enough that the human should reconfirm.
2. **Broken source URLs.** For every `https://<your-git-host>/...` URL referenced in the corpus, issue a HEAD request. Flag 404s, 5xx responses, and redirects to archived locations. Workers handle this in parallel (one URL per worker call), bounded by the concurrency cap. Before probing, filter out URLs containing literal angle-bracket placeholder tokens (`<commit>`, `<path>`, `<source-slug>`, `<owner>`, `<repo>`, or any `<...>` segment) — these are documentation patterns embedded in reference prose, not real citations. Report the placeholder-skip count in Check 2's summary row (e.g., "68 URLs probed, 2 placeholder URLs skipped") so the auditor sees both numbers.
3. **Long-untouched references on active sources.** For each reference, compare its `last_updated` against upstream activity (commits per week in the backing source). Flag any reference unchanged six or more months while sources show 50+ commits in that window. The reference may still be correct, but the gap is the kind of thing a human should look at. Source-side state for this check lives in `research/source-paths.json` (specifically the `lifecycle.last_checked` field per entry, and the upstream activity inferred from the latest probe). `research/.research-state.json` is a setup marker only and is not consulted here.
4. **Catalog row description vs reference content.** For each catalog row in the navigator, diff its one-line description against the reference's **body framing** — the first paragraph under the H1, or the bullets under a `## When to Use This Reference` section if one is present. References carry no YAML frontmatter, so there is no `description:` field to diff against; the body-section heuristic is the contract (see [02-artifact-contract.md](02-artifact-contract.md) § SELF-AUDIT Check 4). One-token-different wording is fine; a catalog row that no longer matches the reference's stated purpose is the case to find. References with no `## When to Use This Reference` section fall back to the first paragraph under the H1 (DISCOVER is goal-given and emits whatever body shape the source rewards).
5. **Cross-reference map accuracy.** For each cross-reference rule in the navigator (e.g., *"questions about pricing → `<area-domain>-billing`"*), verify the routing matches what the referenced file actually covers. A reference that has drifted in scope is the canonical case where cross-reference rules quietly stop pointing where they should.
6. **Review-state staleness.** Flag the contextualizer as stale when the persisted sign-off in `research/review-state.json` (written by `/skill-engine:apply`) has been overtaken by REFRESH activity. Heuristic: ledger present with `review_state ∈ {reviewed, provisional}` AND any in-scope `git-managed` source has `lifecycle.last_checked > reviewed_at` with a non-null `lifecycle.last_checked_sha`. Legacy skills with no ledger AND ≥1 git-managed source that has been probed are stale on the first SELF-AUDIT pass. *Auto-fixable* — the single mutation is to rewrite the ledger so `review_state: "stale"`. See [`self-audit/SKILL.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/skills/self-audit/SKILL.md) § Check 6 for the full heuristic and output format.
7. **Paragraph→permalink density on the references corpus.** Measure the fraction of prose paragraphs in `$CTX_ROOT/references/**/*.md` that carry a SHA-pinned (or stable-tag-pinned) GitHub permalink within a 5-line window. Threshold: ≥80% corpus-wide coverage required to PASS. Scope is the references corpus only; the navigator (`$CTX_ROOT/SKILL.md`) is out of scope, consistent with the SHA-pin discipline applying to reference bodies rather than navigator prose (this check — Check 7, `permalink_density.py` — *is* the SHA-pin gate; it is a CI lint, not part of `verify.sh`). The threshold was sourced from the measurement that motivated this check (46.9% corpus-wide baseline, 7%–87% by-file range) and makes the structural-honesty disclaimer — *"where a paragraph lacks a nearby permalink, treat the claim as unverified"* — mechanically true at the moment the contextualizer ships. *Judgment-required* — there is no mechanical mutation that adds a meaningful permalink to a paragraph; the author follows the per-paragraph findings and re-runs SELF-AUDIT until coverage clears the threshold. See [`self-audit/SKILL.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/skills/self-audit/SKILL.md) § Check 7 for the full definition and output format.
8. **Grounded-citation rate.** For each `needs_reference` prompt in `$CTX_ROOT/research/eval-prompts.json`, run the contextualizer's `SKILL.md` against Claude Haiku 4.5 with a single `read_reference` tool and grade whether the model both opened ≥1 reference AND emitted a SHA-pinned (or stable-tag-pinned) GitHub permalink in its final response text. Threshold: ≥80% by default. *Opt-in* — Check 8 makes paid Anthropic API calls (~$0.01–$0.05 per run); the maintainer enables it by setting `SKILL_ENGINE_RUN_EVAL=1` per invocation. When the opt-in is absent the check emits an `[N/A]` row noting the lever; when `eval-prompts.json` is absent or empty the check is also N/A (no silent skip). *Judgment-required* — a low `grounded_rate` is remediated by tightening the Claims policy block, expanding inline permalinks in references (Check 7's surface), or revising the prompt corpus; the engine cannot mutate any of these mechanically. The permalink regex is imported from the Check 7 lint so the two checks share one source of truth. See [`self-audit/SKILL.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/skills/self-audit/SKILL.md) § Check 8 for the full definition and output format.

**Output format.**
Every audit run emits a summary table with one row per check — no silent skips, even when a check is trivially N/A. The table shape:

```
| Check # | Name                                              | Status | Findings | Notes |
|---------|---------------------------------------------------|--------|----------|-------|
| 1       | Stale "as of" dates                               | PASS   | 0        |       |
| 2       | Broken source URLs                                | PASS   | 0        | 68 URLs probed, 2 placeholder URLs skipped |
| 3       | Long-untouched references on active sources       | N/A    | 0        | All references mtime today; no comparison window yet |
| 4       | Catalog row description vs reference content      | PASS   | 0        |       |
| 5       | Cross-reference map accuracy                      | FAIL   | 1        | See findings list below |
```

`Status` is one of `PASS`, `FAIL`, or `N/A`. `N/A` rows MUST include a one-line reason in `Notes` — silent skips are a doctrine violation because they hide whether the check ran. After the table, list findings (one per row in the prior table where `Findings > 0`) with file path, drift kind, and suggested action.

**How it runs.**
Same shape as REFRESH. Deterministic checks (1, 4, 5) are inline bash for the engine: cheap to run, no token cost beyond the main thread's own loop. Parallelizable checks (2, 3) the model elects to dispatch to Haiku subagents when warranted, under the existing concurrency cap.

For Check 2 specifically, dispatch Haiku subagents only when the URL count exceeds ~100. Below that threshold, inline `curl -I -L` from the main thread is faster end-to-end than subagent dispatch + result aggregation — the per-call I/O latency dominates and subagent scheduling adds overhead, not parallelism benefit. The concurrency cap applies when subagents are dispatched; the inline path runs sequentially. A typical small-to-mid contextualizer (~10 references, ~50-100 URLs) stays on the inline path; large contextualizers (~30+ references, ~200+ URLs) cross the threshold and benefit from subagent dispatch.

The engine aggregates findings into a per-finding list — each finding names the file, the kind of drift, and a suggested action — then walks the list through the same **surface → human approval → write** loop as REFRESH. Nothing auto-applies. Mutations propose specific edits (e.g., *"refresh the as-of date to today's"*, *"update the catalog row to match the new section heading"*); the human accepts, rejects, or amends each one.

A single SELF-AUDIT pass on a mature contextualizer (~30 references, ~100 source URLs) is bounded by the broken-URL HEAD requests; the deterministic checks add negligible time beyond a `find` + `grep` over the references directory.

### Optional fix flow

After the findings table prints, if total findings > 0 the workflow classifies each finding as **auto-fixable** or **judgment-required**:

| Check | Auto-fixable? | Why |
|---|---|---|
| 1 — Stale `as of YYYY-MM-DD` >180 days | ✅ Yes | Deterministic: refresh to today's UTC date. |
| 2 — Broken source URL | ❌ No | Requires intent: replace, remove, link archive snapshot? |
| 3 — Long-untouched reference on active source | ❌ No | The fix is REFRESH against the source, not a self-audit mutation. |
| 4 — Catalog row vs reference body framing | ✅ Yes | Deterministic: sync catalog row to the body framing (first paragraph under the H1, or the `## When to Use This Reference` bullets). |
| 5 — Cross-reference map accuracy | ❌ No | Requires routing judgment. |
| 6 — Review-state staleness | ✅ Yes | Deterministic: rewrite `research/review-state.json` so `review_state: "stale"`. |
| 7 — Paragraph→permalink density | ❌ No | No mechanical permalink-insertion; the right citation depends on the paragraph's claim. |
| 8 — Grounded-citation rate | ❌ No | Remediation is curatorial — Claims policy revision, references corpus expansion, or prompt corpus review. |

When at least one auto-fixable finding exists, SELF-AUDIT prompts the human (with `K = N − M`, the count of judgment-required findings):

```
Found N findings — M auto-fixable, K need judgment.

Apply auto-fixable findings now?
  y       Draft fixes for all M; show diff for APPROVE / DEFER / REJECT
  n       Exit with findings only (default)
  select  Choose which auto-fixable findings to draft
```

Empty input is `n`. The opt-in is per-run — there is no setting to default this on, by doctrine.

On `y` or `select`, the workflow reuses the REFRESH Phase 3-6 shape:

1. **Propose.** Draft the deterministic edits on a sandbox copy at `/tmp/skill-engine-validate-<session-id>/` — the same sandbox infrastructure documented above under [Pre-approval validation](#pre-approval-validation-the-load-bearing-contract). The working tree is byte-identical until Phase 6.
2. **Validate.** Run `bash verify.sh` from the sandbox copy. Every check must pass or report N/A — the no-frontmatter rule (Check 5) and catalog bijection (Check 4) are among its named checks, so this is the same pre-approval contract REFRESH uses. (Checksum fixture refresh and full test suite are pre-fixture-harness aspirational; see the [Pre-approval validation](#pre-approval-validation-the-load-bearing-contract) section above.)
3. **Human review.** Surface the unified diff plus a one-line rationale per finding. Wait for explicit `APPROVE`, `DEFER`, or `REJECT`. On `DEFER`, exit cleanly with findings unchanged. On `REJECT`, append to `research/.rejection-log.json` per the rejection-memory schema.
4. **Apply.** On `APPROVE`, write to the working tree. Append a `session_type: "SELF-AUDIT"` entry to `research/.engine-stats.json` carrying `approved_proposals` and `rejected_proposals`; log per-session detail to `research/sessions/<session-id>.json`. The state-trail schema is unchanged from REFRESH.

For **judgment-required findings** (Checks 2, 3, 5, 7, 8), the workflow prints a one-line recommendation per finding and exits without drafting any mutation. Sample recommendations:
- Check 2 (broken URL): `references/foo.md:42 — broken URL; replace manually or link archive snapshot.`
- Check 3 (long-untouched): `references/bar.md — unchanged 8mo while source advanced 73 commits; run /skill-engine:refresh.`
- Check 5 (cross-ref): `cross-reference map: billing → identity — verify routing manually.`
- Check 7 (density): `references/foo-bar.md — 12.5% paragraph→permalink coverage (below 80% threshold); add SHA-pinned permalinks to the uncovered paragraphs listed above.`
- Check 8 (grounded-rate): `grounded_rate 40.0% (below 80% threshold) — review per-prompt failure markers; remediate by tightening the Claims policy block, expanding inline permalinks in references (Check 7), or revising the prompt corpus.`

When M == 0 (no auto-fixable findings), skip the prompt entirely — print only the recommendation list and exit.

**Why this scope.** Checks 1, 4, and 6 have a single correct mutation each (refresh-the-date, sync-the-row, flip-the-ledger-to-stale); a drafted fix is right ~100% of the time and the propose/approve loop reads as a sanity confirmation rather than a content judgment. Checks 2/3/5/7/8 require knowing the user's intent or carry curatorial weight (which broken URL replacement is right? what is the new routing? which paragraph deserves which permalink? does the Claims policy need to tighten or is the prompt corpus unrepresentative?); a drafted fix here would frequently be wrong and would erode trust in the approve/defer prompt elsewhere. The propose surface stays narrow on purpose.

**Cadence.**
Every 2–4 weeks. Pair with DISCOVER on the same day to get a single "quarterly maintenance touch" rhythm — DISCOVER finds new resources to track; SELF-AUDIT cleans up drift in what's already tracked. Both are read-only by default and both surface findings before any write.

**What it is not.**
SELF-AUDIT does not replace REFRESH or STATUS. REFRESH detects content drift (the *source* changed); STATUS shows quantitative state (which references are due); SELF-AUDIT detects framing drift (the *artifact* has aged out of sync with the source). Three different lenses on the same corpus. End-of-session reflection (next section) audits a fourth surface — the *engine template itself* — kept distinct from artifact-side drift so the agent's observations about its own prompt do not get mixed with content-side findings the human is meant to act on.

SELF-AUDIT also does not validate the artifact contract. The four reference invariants, frontmatter rules, filename conventions, and other shape-of-the-corpus checks are owned by `verify.sh` (the stamped per-contextualizer audit). If the auditor notices a contract-side question (e.g., "doctrine says no frontmatter but references have it"), that question belongs in the session-reflection's `## Template ambiguities` block, not the findings list. The eight drift checks above are the entire scope of SELF-AUDIT's findings surface; broadening it would conflate framing drift with invariant compliance and erode the per-lens separation that makes the three workflows actionable. Checks 7 and 8 sit orthogonally to Checks 1–6: the first six detect framing drift across several axes (stale dates, broken URLs, long-untouched references, catalog rows, cross-reference rules, review-state); Check 7 measures structural-honesty density on the references corpus; Check 8 measures behavioral citation rate when the model answers — same workflow, three lenses on the same doctrine.

**Where it lives.**
The engine-side prose for SELF-AUDIT — including the activation hook (engine doctor) that primes the run — lives in [`maintenance-agent.md.template`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/engine-bootstrap-templates/maintenance-agent.md.template); this section documents the doctrine.

## End-of-session reflection

A short, structured artifact the agent writes at the close of every session — meta-feedback on the engine itself, kept distinct from the artifact-side findings that surface as approval-gate proposals.

**What the agent writes.**
A 3-section markdown file at `research/.session-reflections/<session-id>.md`:

1. **Rationalizations** — moments during the session where the agent reached for a justification that the prompt's `Rationalizations to refuse` table would call out (e.g., *"SHA matches but the README looks newer; re-crawl just to be safe"*). The agent records what it reached for and what stopped it.
2. **Template ambiguities** — phrases in the agent prompt that the agent had to re-read or guess at. The intent is not to propose template edits autonomously — only to surface observations the human reads on the next activation.
3. **Workflow timing surprises** — places where a phase ran much faster or slower than expected (e.g., a Phase 2 crawl that returned in 3 seconds instead of 30, or a SHA-comparison check that took 90 seconds for ten resources). Useful signal for tuning concurrency caps and cadence.

Each section names the referenced area-domain(s) inline so the per-domain clustering step at activation has a clean grep-target. For single-domain contextualizers this is one domain in every line; for multi-domain contextualizers (one navigator routing across many area-domains) it is the load-bearing field that lets per-domain patterns surface independently.

**What the agent reads at activation.**
The most-recent 3 reflections (lexicographic-desc sort = chronological-desc per the ISO-8601 filename prefix). The agent **clusters them by referenced area-domain** so per-domain patterns surface even when other domains are clean. The clustered observations seed the orchestrator's `Rationalizations to refuse` table for the new session, so cross-session patterns become inputs rather than re-discovered each time.

**Filename convention.**
`YYYY-MM-DDTHH-MM-SSZ-<short-suffix>.md`. ISO 8601 UTC, colons → hyphens for filesystem safety, plus a 4-character random suffix to disambiguate within-second collisions. Lex sort equals chrono sort because every timestamp component is fixed-width and zero-padded; the `T` separator and `Z` suffix sit at fixed positions. Suffix-level lex order within a single second is non-deterministic but irrelevant to last-N selection.

**Rotation policy.**
At activation, prune any reflection beyond the most-recent 20. Older entries are already incorporated into the rationalization-table seed; the directory is bounded over a multi-year contextualizer lifetime.

**What this is not.**
The agent does not propose template edits autonomously; it surfaces observations for the human to read on the next activation. End-of-session reflection is *meta-feedback on the engine itself*, kept distinct from artifact-side findings (which surface as approval-gate proposals via REFRESH/SKILL/NEW).

**How this differs from SELF-AUDIT and from STATUS.**
SELF-AUDIT audits the *artifact* — navigator, references, catalog. End-of-session reflection audits the *engine template* — the agent prompt itself. STATUS shows quantitative state (which references are due); end-of-session reflection captures qualitative observations the human reads when re-activating. Three separable mechanisms, one cohesive maintenance loop.

**Where it lives.**
The orchestrator-side hooks — the per-workflow `**Next steps.**` line and the activation-time read-of-3-reflections — live in `maintenance-agent.md.template`; this section documents the doctrine.

## Engine effectiveness telemetry

A per-session telemetry record the agent appends at session close, giving STATUS a quantitative view of engine activity to complement end-of-session reflection's qualitative one.

**What the agent writes.**
At the end of every session, the agent appends one record to `research/.engine-stats.json`. The file is a single JSON document with a top-level `schema_version: 1` field and an `entries` array, mirroring the shape established by [`12-evaluation.md`](12-evaluation.md) for evals.

**Per-session record schema.**
Every entry carries:

- `session_id` — string; matches the session id used by end-of-session reflection.
- `session_type` — one of `REFRESH | SKILL | NEW | STATUS | DISCOVER | SELF-AUDIT`.
- `started_at`, `ended_at` — ISO 8601 UTC timestamps.
- `sources_probed` — array of `{path, branch, sha_at_probe, probed_at}` for every source the session probed. `probed_at` is ISO 8601 UTC at probe time. Enables REFRESH "since-last-refresh" deltas per source.
- `approved_proposals` — array of `{category, reference}`.
- `rejected_proposals` — array of `{category, reference, rationale}`.
- `notes` — optional free-form maintainer text.

The `category` field on `approved_proposals` and `rejected_proposals` carries the same closed enum of eight values as the rejection-log schema (see [Rejection memory at activation](#rejection-memory-at-activation) below): `over-eager-restructure`, `scope-creep`, `naming-drift`, `stale-citation`, `bijection-drift`, `description-quality`, `prose-voice-drift`, `other`.

**Why this shape.**
`sources_probed` is the producer for cross-session "since-last-refresh" deltas; `rejected_proposals` is the producer that the rejection-log denormalizer reads to build its `category × reference` clustering. Without this coupling, the rejection-log would have nowhere to harvest its inputs.

**STATUS rendering contract.**
When `research/.engine-stats.json` is present, STATUS reads the most-recent 5 entries (deterministic last-N tail of the array) and renders two sub-sections: "Recent sessions" — one row per session with session_id, type, `started_at`, `sources_probed` count, approved/rejected proposal counts — and "Approval rate" — rolling-30-day `approved / (approved + rejected)` percentage. Absent file: render "no telemetry yet". Pure bash plus `jq`; no third-party deps.

**Source-paths additive fields.**
The contextualizer's `research/source-paths.json` (the document the engine reads to know which source roots to probe — see [`02-artifact-contract.md`](02-artifact-contract.md) for the `source_id` derivation contract) gains two additive optional fields:

- `freshness_policy` (per source, optional enum). Values: `local-trust` (probe whatever's at the local path; no network), `fetch-and-compare` (default for git-managed sources — `git fetch` first, compare local HEAD to `origin/<branch>`, surface divergence to the user before probing), `remote-only` (probe `origin/<branch>` directly via `git show`; strongest fidelity, network-heavy). Default: `fetch-and-compare` for git-managed sources, `local-trust` for non-git paths. Failure modes: a source with no `origin` configured degrades to `local-trust` for the session and emits a one-line user-visible warning; a missing `origin/<branch>` fails loudly naming the branch (silent fallback would mask stale config); a `git fetch` network error fails loudly with the error (silent degradation could mark sources as freshness-checked when they weren't).
- `probe_budget` (document-root, optional integer ≥ 1). When set, REFRESH probes at most N sources per session, prioritized by descending importance score, with ties broken by oldest `probed_at` first (missing-from-telemetry treated as `1970-01-01T00:00:00Z` so never-probed sources sort to the front), with further ties broken by lexicographic ascending path. Sources beyond the budget are explicitly skipped (not silently dropped) — REFRESH renders `"M of K sources skipped this session due to probe_budget=N (next-eligible: <list>)"`. The fetch cost of `freshness_policy: fetch-and-compare` is NOT counted against `probe_budget` — only the probe step is budgeted (`probe_budget` controls model-token cost, not network cost). Validation: `probe_budget` MUST be a JSON integer ≥ 1 when present; values 0, negative integers, and non-integer types fail loudly at REFRESH activation naming both the field and the offending value. Absent budget: probe all sources every session.

**REFRESH temporal-delta verbiage.**
REFRESH renders an opening line `Incorporating updates to existing references since last refresh ({date}, {N} days ago)...` and a closing line `REFRESH complete. {N} references with drift to incorporate. {M} sources skipped (no delta).` This makes the temporal-delta concept user-visible and distinguishes REFRESH (incorporate-source-changes) from SELF-AUDIT (audit-artifact-hygiene) at the language level.

**What this is not.**
The agent does not auto-tune anything from telemetry. STATUS shows quantitative state; the maintainer reads the trend and decides whether to widen or narrow cadence, raise or lower `probe_budget`, etc. End-of-session reflection captures qualitative observations; engine-effectiveness telemetry captures quantitative ones.

**How this differs from `## State schema`.**
`research/.research-state.json` is the artifact-side state — which references exist, what their `last_commit_sha` is, freshness counters. `research/.engine-stats.json` is the engine-side telemetry — which sessions ran, what they probed, what was approved or rejected. Two separable files; the engine reads both at activation but writes them at different points (state per-resource on commit; telemetry per-session at close).

**Where it lives.**
The orchestrator-side STATUS rendering and REFRESH temporal-delta lines live in `maintenance-agent.md.template`; this section documents the doctrine.

## Rejection memory at activation

A denormalized cross-session view of human rejections, surfaced at activation so the agent can see its own pattern history before proposing again.

**What the agent writes.**
On every human rejection of a proposed change (in REFRESH / SKILL / NEW / SELF-AUDIT), the agent appends one entry to `research/.rejection-log.json`. The file is denormalized from the per-session `rejected_proposals` arrays in `research/.engine-stats.json` (see [Engine effectiveness telemetry](#engine-effectiveness-telemetry) above) — the log is the cross-session view, organized for fast `category × reference` clustering at activation.

**Schema.**
The file is a single JSON document with a top-level `schema_version: 1` field and an `entries` array. Each entry carries:

- `ts` — ISO 8601 UTC timestamp.
- `session_id` — the writing session's id.
- `category` — closed enum (see below).
- `reference` — the affected reference filename without `.md`.
- `rationale` — free-form maintainer text capturing the human's stated reason.

**Closed enum for `category` (v1, exactly 8 values):** `over-eager-restructure`, `scope-creep`, `naming-drift`, `stale-citation`, `bijection-drift`, `description-quality`, `prose-voice-drift`, `other`. Schema validation rejects any value outside this set; future categories require an explicit story to extend the enum and bump `schema_version` to 2.

**`schema_version` type pinning.**
The field MUST be a JSON integer ≥ 1; non-integer types (string, float, null, boolean) fail loudly with the offending type named; values 0 and negative integers fail loudly as unknown-version. Files missing the `schema_version` field are treated as v1 (back-compat for any logs written between this story landing and a hypothetical v2 story). Same integer-pin discipline as [`12-evaluation.md`](12-evaluation.md).

**Migration contract for v2.**
When a future story adds, removes, or renames an enum value, it MUST bump `schema_version: 2`, ship a one-step migration helper at `bin/migrate-rejection-log-v1-to-v2.sh`, and extend the verify check to accept either v1 or v2 during the migration window. Files carrying an unknown `schema_version` fail loudly naming the version. Same migration shape as [`12-evaluation.md`](12-evaluation.md).

**What the agent reads at activation.**
The agent loads `research/.rejection-log.json` (if present) and clusters entries by `category × reference`. For any cluster with `count >= 3`, the agent surfaces a one-line warning at activation: `You've been rejected {count} times for {category} on {reference} — review pattern before proposing`. Below-threshold clusters are aggregated silently into the rationalization-table seed (the same seed end-of-session reflection feeds; both inputs combine).

**Why ≥3 not ≥2.**
Two rejections of the same `category × reference` pair could be coincidence; three is a pattern. The threshold is informally tunable — a future story may parameterize it on the contextualizer's `research/.research-state.json`. v1 hardcodes 3.

**What this is not.**
The agent does not block proposals based on rejection memory. The warning is informational; the human always has the final say. Rejection memory is a SURFACE for cross-session pattern detection, not a GATE.

**How this differs from end-of-session reflection.**
End-of-session reflection captures the agent's qualitative observations about its own template; rejection memory captures the human's quantitative corrections to the agent's proposals. Reflection is engine-side meta-feedback (markdown, free-form); rejection memory is artifact-side correction history (JSON, schema-validated). Both feed the rationalization-table seed; both are bounded over a multi-year contextualizer lifetime — reflections via the rotation-at-20 policy, rejection-log via natural decay (older entries simply stop firing the ≥3 threshold once newer entries dominate the cluster, no rotation needed).

**Where it lives.**
The orchestrator-side activation-read step and the per-rejection write step (a Critical rule that fires across all workflows) live in `maintenance-agent.md.template`; this section documents the doctrine.

## Why manual triggering

The agent runs exactly when a human starts a session. There is no cron, no GitHub Action, no scheduled trigger.
This is a deliberate design stance, not a missing feature.

The full rationale lives in [06-release-doctrine.md](06-release-doctrine.md), but in short:
* **Single maintainer ownership** aligns with Anthropic's published guidance on effective agents.
* **Cadence is irregular.** Upstream activity varies; a fixed schedule wastes tokens on quiet weeks and misses bursts.
* **The approval gate is context-integrity-critical.** A bad crawl pattern silently propagating to every consumer is worse than slower maintenance.

Resist the urge to add cron. If you find yourself wanting to, ask first whether what you actually want is better STATUS visibility (so you remember to run REFRESH).

[Next: 04-delivery.md - CLI install, plugin marketplace, Desktop zip, metadata schema, legacy upgrades](04-delivery.md)