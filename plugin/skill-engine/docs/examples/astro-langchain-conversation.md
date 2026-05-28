# Astro × langchain — a conversation

This is the full Claude Desktop conversation excerpted in the [repo
README](../../README.md). Two contextualizers were loaded — one built from
the Astro framework's architecture, integration model, and release notes
(`astro-context`), and one built from the langchain ecosystem's v1 agent
primitives, Deep Agents, and LangGraph deployment patterns
(`langchain-context`). The conversation runs two prompts: a weighted-
shortest-job-first brainstorm across five candidate jobs the langchain
agent layer could do for the team that maintains Astro, then an
implementation drill-down on the top-scored idea.

The receipts you'll see — file paths, workflow names, package names, the
fixture-`outDir` trap — are real artifacts of the Astro codebase. A reader
can `git clone withastro/astro` and verify each citation. That's the point
of a contextualizer: the answers carry receipts the model couldn't have
produced from training data alone.

---

## Prompt 1 — WSJF brainstorm

`/astro-context`
`/langchain-context`

(Slash-invoking both contextualizers to make sure their guidance is in
scope — astro-context carries the framework's architecture, integration
model, and recent release notes; langchain-context carries the v1 agent
primitives, Deep Agents, and LangGraph deployment patterns.)

I've been thinking about the team that maintains Astro and the integration
ecosystem around it. The scope is genuinely impressive: a release cadence
measured in weeks, first-party integrations spanning half a dozen UI
frameworks (React, Vue, Svelte, Solid, Lit, Preact), a curated community-
built integrations directory, and a steady inflow of contributors — many of
them newer to open source, working in an industry where AI-assisted code
submissions have changed both the volume and the variance of what shows up
in a PR queue. Releases that introduce or refine core APIs — Server
Islands, View Transitions, the Content Layer — cascade into work for
integration authors the core team doesn't directly write but does have to
coordinate.

The core team's time is the constraint, and most of the obvious load is
reactive: review queues, integration triage, migration-guide writing, docs
lift. I'm curious whether a langchain-agent layer — owned by the core
team, opinionated about Astro's conventions — could move the needle here
without violating the team's manual-cadence-and-trust posture.

A few candidate jobs I have in mind, but I'm open to the agent layer
suggesting better ones:

- Pre-review triage of integration PRs against Astro's plugin contract
- Breaking-change-candidate detection from core PRs into integration-
  author advisories
- First-pass migration-guidance drafts when a major version touches a
  published API
- Onboarding nudges for first-time contributors before a human responds

I'd like you to brainstorm how langchain could be used to make Astro
maintenance more sustainable. Use weighted shortest job first (WSJF)
scoring — Cost of Delay (User-Business Value + Time Criticality + Risk
Reduction / Opportunity Enablement) divided by Job Size, on a Fibonacci
scale. Present five ideas with their scoring as a table, then a short
paragraph on each. After, I'll pick one to take into an implementation
plan.

## Response 1

Both skills are loaded — astro-context for the integration contract,
changeset workflow, CI matrix, governance levels, and stability tiers;
langchain-context for the v1 agent surface, Deep Agents, and LangGraph's
interrupt/checkpoint primitives that fit the team's manual-cadence-and-
trust posture.

Before the table, one architectural note that applies to every entry
below: the v1 `create_agent` returns a LangGraph `StateGraph`, so every
one of these can be built as a graph with `interrupt()` gates at the
publish/post step. That's what lets the agent layer draft-and-wait rather
than draft-and-ship — exactly the trust posture you described.
Checkpointers persist state across the wait, so a maintainer can approve
hours later from a phone.

I'm substituting two of your four candidates. Pre-review onboarding nudges
fold into a broader "pre-flight" agent that also handles changeset linting
and CI explanation (those three jobs hit the same surface — first comment
on a fresh PR — and splitting them is more cost than coordination saves).
I'm also adding an issue-triage assistant that scored higher on WSJF than
the breaking-change pipeline once I costed the job sizes honestly.
Integration-contract triage stays, breaking-change advisory stays,
migration-guide first-draft stays.

| # | Job | UBV | TC | RR/OE | CoD | Size | **WSJF** |
|---|---|---|---|---|---|---|---|
| 1 | Pre-flight PR agent (changeset bump-level check + CI-failure explainer + first-timer welcome) | 8 | 5 | 5 | 18 | 3 | **6.0** |
| 2 | Issue triage assistant (duplicate detection, p1–p5 suggestion, needs-repro lifecycle) | 5 | 5 | 5 | 15 | 3 | **5.0** |
| 3 | Migration-guide first-draft from changesets at major-bump time | 13 | 2 | 5 | 20 | 5 | **4.0** |
| 4 | Breaking-change advisory pipeline (core PR → integration-author notice) | 13 | 8 | 8 | 29 | 8 | **3.6** |
| 5 | Integration-PR contract triage against the 11 lifecycle hooks | 8 | 3 | 5 | 16 | 5 | **3.2** |

**1. Pre-flight PR agent (WSJF 6.0).** Fires once on every new PR to
`withastro/astro`. Reads the diff, infers whether the change is a
patch/minor/major bump per the changeset bump-level rules, and either
confirms the contributor's changeset is right or proposes one inline. If
CI has failed, it reads the failure and maps it back to the local command
from `astro-ci-checks` (the fixture-`outDir` trap and the import-from-dist
rule alone account for a lot of "works on my machine" comments). For
first-time contributors it adds a friendly welcome and a checklist of what
reviewers will look for. This is a textbook `create_agent` with
middleware: one model call, a small tool surface (read PR diff, read CI
logs, post comment), and a `before_model` middleware that decides whether
to engage based on PR label state. Narrow, high-volume, low-risk — it's
the agent equivalent of pre-commit hooks. The reason it tops WSJF isn't
glamour, it's frequency: every PR, every day, immediate utility, three
days to build.

**2. Issue triage assistant (WSJF 5.0).** Watches `withastro/astro` issues
at open time. Runs a duplicate-search pass against historical issues
(langchain's retrieval surface over an embedded index of closed issues),
suggests a p1–p5 label based on the heuristics in
`astro-issue-triage-and-security`, and posts the `needs-repro` request if
no reproduction is attached. Re-fires on a schedule for stale
`needs-repro` issues to nudge the original reporter. Also another
`create_agent` with middleware, plus a `langchain-core-retrieval` vector
store keyed on issue title+body. Scores well because the issue queue
compounds invisibly — every duplicate that lands in the queue is a
maintainer-minute spent realizing it's a duplicate. The reason this beat
the breaking-change pipeline is size, not value: it's a smaller cone of
work and reuses the same comment-posting harness as #1.

**3. Migration-guide first-draft (WSJF 4.0).** When a `major` changeset
lands on `next`, the agent reads every changeset accumulated since the
last major, groups them by affected user-facing surface (per the 133-entry
exports map), and drafts a migration guide as a PR against
`withastro/docs`. This is the natural fit for `create_deep_agent`: it
needs planning (outline the doc structure), filesystem (write the MDX file
in the docs repo's expected location), and sub-agents (one per major
surface — content layer, transitions, server islands — each writing its
own section in parallel). The user-business value is high per-occurrence
but the frequency is low, which is what pushes it below the high-volume
jobs on WSJF. Worth doing precisely because it's rare-and-painful: the
team only does this work once every twelve-to-eighteen months, so the
muscle memory is always cold.

**4. Breaking-change advisory pipeline (WSJF 3.6).** Watches core PRs
that modify the public surface (changes to `packages/astro/`'s `exports`
map, changes to the `AstroIntegration` shape in `astro-integrations-api`,
changes to anything not under `_internal/*`). When it detects one, it
identifies which official integrations consume the changed surface,
drafts an advisory, and `interrupt()`s for a maintainer to review before
posting to the integration-author channel. This one genuinely wants
LangGraph rather than a flat `create_agent`: there's a real graph here
(detect → impact-analyze → draft advisory → human gate → publish →
track responses), checkpointing matters because the human-gate step might pause
for a day, and the impact-analysis step is itself agentic enough that you
want it as its own node. The reason this scores lower than its cost-of-
delay suggests is that the job size honestly is 8 — public-API diffing,
integration consumption mapping, the human-gate workflow, the multi-week
feedback loop on whether advisories actually landed. Pay for it if you
have the capacity, but don't start here.

**5. Integration-PR contract triage (WSJF 3.2).** Runs the
`AstroIntegration` contract checks on every PR that touches
`packages/integrations/*` or that's tagged community-integration. Verifies
the 11 lifecycle hooks are used correctly, that
`addRenderer`/`injectRoute`/`setAdapter` calls match their hook
contracts, and that the integration's changeset bump reflects what the
diff actually does (independent changesets per integration). Another
`create_agent` with middleware, but the contract is large enough that
encoding the checks well takes real work — the 11-hook surface has subtle
invariants that the skill captures but that need to be turned into
agent-legible checks. The reason this scores at the bottom isn't that
it's not valuable — it absolutely is — it's that the job size grows fast
as you encode more contract rules, and the volume of integration PRs is
lower than the volume of all PRs. If you do #1 first, you'll have most
of the harness built when you come back to this.

Pick one and I'll take it into an implementation plan — repo wiring
(GitHub Action vs. external service), the LangGraph graph shape, the
middleware composition, the human-gate UX, and the eval harness in
LangSmith so you can ship it behind a `try-the-bot` label before turning
it on for everyone.

---

## Prompt 2 — Implementation drill-down

Let's dig into 1. Pre-flight PR agent (WSJF 6.0). Read through the
contextualizers again and cater the plan specifically to Astro's
environment. The plan should address:

- **CI/CD integration:** What does the Astro repo's existing GitHub
  Actions / release pipeline already do? What reusable workflows or
  patterns should the agent layer compose with rather than replace?
- **Context scoping:** How can a langchain agent get *enough but not too
  much* context to review a change that touches a given surface? The
  runtime, the integration boundary, the docs site, the build pipeline —
  these have different review surface areas and the agent should route
  accordingly.
- **Hosting:** Trade-off matrix on cloud-hosting choices — LangGraph
  Platform vs. self-hosted (Modal / Fly / similar) vs. in-Action runner.
  Frame for an OSS-team-owned deployment that the core maintainers would
  actually take on.
- **Self-update story:** As Astro's core APIs evolve release-to-release,
  how does the agent layer's context stay accurate? What triggers a
  re-index, who reviews the diff, and what's the eval gate that decides
  whether the new index is promoted?
- **Things to deliberately not do:** An explicit anti-recommendations
  list — adjacent moves that might be tempting but wouldn't fit Astro's
  posture (auto-merge, opaque retrieval, replacing human judgment,
  etc.).

Present a detailed implementation plan with concrete steps in landing
order, each step delivering value standalone so the work can be paused or
promoted independently.

## Response 2

Going to load the relevant references before drafting — the question hits
five different surfaces and I want to ground each in what's actually true
about Astro's current setup and langchain v1's primitives, not pattern-
matched recall. Loaded the references. Here's the plan, grounded in
Astro's actual workflow scaffolding and langchain v1's primitives.

### Pre-flight PR agent: implementation plan

#### 1. CI/CD integration — compose, don't recreate

The repo already has the scaffolding you'd want. The agent's job is to
*add a layer*, not to relitigate decisions the existing workflows have
already made.

What's already there in `.github/workflows/`:

- **`congrats.yml`** — first-time contributor welcome message. The agent
  must not duplicate this. Two welcome bots is worse than one, and
  `congrats.yml` is the unfiltered human-warmth moment that should stay
  un-cluttered by checklist substance.
- **`.github/labeler.yml`** — directory-to-label mapping (`pkg: astro`,
  `pkg: integration`, `pkg: react`, `feat: markdown`, etc.). This is the
  agent's routing primitive — it does not re-derive what surface the PR
  touches; it reads what the labeler bot already decided.
- **`dorny/paths-filter`** is already used in `ci.yml` to skip
  `test-language-tools` and to trigger the `smoke` job's docs-rebuild
  branch. The agent's workflow mirrors this idiom rather than inventing
  its own path-routing.
- **The PR template's three sections** (Changes / Testing / Docs, each
  with `DON'T DELETE THIS SECTION!`) are the surface the agent checks
  for completeness.
- **`release.yml`** and the changesets pipeline are owned. The agent
  verifies a changeset is present and suggests a bump level; it never
  writes the file.
- **`format.yml`** runs `pnpm run format` post-merge. The agent doesn't
  complain about formatter noise — that's already automated away.

The new workflow is a single file: `.github/workflows/preflight-agent.yml`,
triggered on `pull_request` events (`opened`, `synchronize`, `reopened`,
`labeled`). It runs a Python script that posts (or edits in place) one
sticky comment per PR. Edit-in-place is non-negotiable — a contributor
force-pushing eight times shouldn't see eight bot comments.

Two Astro-specific quirks the agent must accommodate:

- **Fork PRs skip the build step** because `TURBO_TOKEN` isn't available
  outside the `withastro` owner (`if: ${{ matrix.os == 'ubuntu-latest' &&
  github.repository_owner == 'withastro' }}` in `ci.yml`). When the
  agent's CI-failure explainer sees "build was skipped on this fork PR,"
  it explains that this is expected behavior, not a regression. First-
  timer confusion on this specific point is a known recurring pattern.
- **CI is paths-aware**: edits to `.vscode/**`, `**/*.md`, and
  `.github/ISSUE_TEMPLATE/**` skip the whole pipeline. The agent should
  also skip — no value in commenting on a doc-comment-only PR.

#### 2. Context scoping — route by label, not by retrieval

Different surfaces want different checks. The cheapest accurate router is
the labeler-bot output that the repo already produces. The agent's first
move is `gh pr view --json labels` and then a switch.

| Labeler signal | Surface | Surface-specific checks |
|---|---|---|
| `pkg: astro` + diff under `src/core/` or `src/cli/` | Node execution context | Public-vs-internal exports drift (the `exports.test.ts` guard); changeset bump level vs. diff (touching exports → minor; behavior change → patch; removal → major); test files import from `dist/` not `src/`; if the diff touches a shared fixture, flag the `outDir` trap |
| `pkg: astro` + diff under `src/runtime/server/` or `src/runtime/client/` | Vite SSR / browser | Runtime-agnostic check — no `node:fs`, `node:path` imports; if a virtual module is added, the `\0`-prefix convention; if a Vite plugin's `load()` returns Node-API-dependent code, flag it |
| `pkg: astro` + diff under `src/vite-plugin-*/` | Compile-time Vite | Point at `reference/optimize-deps.md` if the symptoms in the PR description match "works in build, fails in dev"; dep-optimizer trap pattern |
| `pkg: integration` plus the per-integration label (`pkg: react`, `pkg: cloudflare`, ...) | Integration boundary | Factory shape: default export is a function returning `AstroIntegration`; `experimental*` prefix on new options; `logger.info`/`warn` not `console.log`; independent changeset (`@astrojs/<name>` bumps separately from `astro`); for adapters, `setAdapter` called once in `astro:config:done`; for renderers, `addRenderer` shape with `clientEntrypoint`/`serverEntrypoint` |
| `pkg: db` | Astro DB | Defer to DB-specific reviewers; agent posts a "this surface needs human review" stub rather than guessing |
| diff under `packages/language-tools/` | LSP / VSCode / ts-plugin | Note ts-plugin tests are known-flaky and don't fail CI; agent does not second-guess flakes |
| diff only under `examples/*` | Examples | No changeset required (per `pnpm-workspace.yaml`'s exclusions); light-touch check; remind about docs PR if README touched |
| diff under `.github/workflows/**` (`🚨 action` label) | CI itself | Agent declines to self-review; posts "this PR touches CI workflows — routing to human reviewer" |

The discipline behind this table: **at step one, this is a routing-and-
rules problem, not a RAG problem.** Astro's contributor rules are short,
structured, and stable. Embedding `CONTRIBUTING.md` into a vector store
and asking the agent to "reason about whether this PR follows
conventions" is tempting and almost certainly wrong on accuracy —
explicit checklists win against retrieval-and-reason when the rules are
written down clearly.

Where retrieval *does* earn its place — and only in a later step — is the
historical-PR-pattern side: "has anyone hit this fixture-outDir trap
before?" → fetch three similar closed PRs and let the agent reference
them. This is one of the rare retrieval surfaces where similarity is
genuinely informative because the symptom-to-cause mapping is fuzzy.

In `langchain` v1 terms: a `create_agent` with a hand-coded `before_model`
middleware that runs the surface router and injects only the relevant
checklist into the system prompt. The tool surface stays small — read PR
diff, read labels, read CI logs, post-or-edit a comment. Token budget per
PR stays under a few thousand input tokens.

#### 3. Hosting — trade-off matrix

The OSS-team-owned constraint is "what does the core team take on as an
operational dependency?" Three reasonable shapes:

| Dimension | LangGraph Platform (LangSmith Deployment) | Self-host (Modal / Fly / Railway) | In-Action runner |
|---|---|---|---|
| Where the agent runs | langchain-hosted long-running HTTP service via `langgraph build` | Container the team operates on chosen IaaS | The GitHub Actions runner that fires per PR event |
| Persistence | Built-in Postgres checkpoints | BYO checkpointer (SQLite via volume or hosted Postgres) | None — every event is a cold start |
| `interrupt()` / human-in-the-loop | First-class; SDK returns a resume URL | Works but you wire the resume endpoint yourself | Doesn't fit; an Action invocation is single-shot |
| Secrets | LangSmith manages keys | Team's IaaS secrets manager | GitHub Actions secrets (already a known surface for the team) |
| Observability | LangSmith traces native via `LANGSMITH_TRACING=true` | Same env-var pattern; OTel optional via `langsmith[otel]` | Same env-var pattern works in Action runners |
| Cost shape | Per-trace + hosted-runtime pricing | Modal/Fly/Railway compute + Postgres | GitHub Actions minutes (free tier generous for OSS) |
| Team operational load | Lowest — one vendor relationship | Highest — container, DB, secrets, monitoring | Lowest infra; highest design friction for stateful work |
| Failure-mode when the agent breaks | langchain's pager | Core team's pager | Posts silently stop; visible to anyone watching the `preflight-agent` workflow |
| Fits Astro's posture? | Trades operational simplicity for a vendor commitment | Best self-determination; highest cost | Most boring; fits the team's existing toolchain |

**Recommendation: start in-Action.** No step in the pre-flight scope
requires durable state. Every check is "read PR diff and CI logs, decide,
post one comment, exit." The agent is a Python script invoked by a
workflow, importing `langchain` and `langgraph` (LangGraph is a hard dep
of v1 anyway — `pip install langchain` pulls it in), <!-- nosemgrep: skill-content-unpinned-pip-install --> building a
`create_agent` per invocation, calling `.invoke(...)` once, posting via
the `gh` CLI, exiting. LangSmith tracing is two env vars stored as
GitHub Actions secrets. Total operational surface added to the core
team: one workflow file, one Python script, one or two secrets.

Promote to LangGraph Platform or self-host *only* when a later job needs
`interrupt()` — the breaking-change advisory pipeline does; this one
doesn't. The in-Action shape is a reversible choice: the same
`create_agent` code moves to LangGraph Server by swapping the entrypoint
and adding a checkpointer, with no rewrite of the agent itself.

#### 4. Self-update story — three context tiers, one eval gate

Astro ships every two weeks. The agent's context drifts on three different
cadences:

- **Slow-drifting (every major):** the `AstroIntegration` hook list, the
  public-vs-internal API boundary's shape, test conventions, the package-
  folder taxonomy.
- **Fast-drifting (every release):** the set of integrations under
  `packages/integrations/*`, entries in `packages/astro/package.json`'s
  exports map, error codes in `errors-data.ts`, the labeler.yml mapping.
- **Stable (years):** the changeset workflow, the PR template, the
  branch model.

The right shape is a tier per cadence:

| Tier | Lives in | Updated by | Eval gate |
|---|---|---|---|
| Conventions (slow) | `AGENTS.md` in `withastro/astro` | Hand-written by maintainers; agent reads at run time | Human review of the `AGENTS.md` PR. No automated gate. |
| Surface facts (fast) | Generated JSON at `.github/preflight-agent-context.json` | A scheduled workflow `generate-preflight-context.yml` that parses `labeler.yml`, the exports map, the integration list, error codes, and emits structured JSON nightly | Diff against the previous committed JSON. Maintainer approves the bot's PR. |
| Historical patterns (optional, deferred) | Vector store of closed PRs and their outcomes | Weekly indexing workflow | LangSmith `Client.evaluate(...)` against a hand-curated dataset of historical PRs; new index promoted only if it matches-or-beats the prior on the dataset |

The eval primitive is `Client.evaluate(...)` from the `langsmith` SDK.
You point it at a dataset, a target function (the agent), and one or more
evaluators (LLM-judge against a rubric, exact-match on which-checks-
fired, etc.). The dataset starts as 20–50 historical PRs the maintainers
annotate with what the right pre-flight comment would have been, and
grows as the agent ships and contributors flag false positives. A prompt
change, model change, or context-JSON regeneration runs through this
gate before merge — that's the lever for keeping the agent honest as
Astro evolves.

The non-RAG tiers don't need anything as elaborate. The fast-drifting
JSON is generated deterministically from authoritative repo files; if the
workflow runs green and the maintainer's PR review passes, it ships.

**Critical move: `AGENTS.md` is the contract.** The agent's behavior
should never depend on a rule that isn't also written in `AGENTS.md`,
because `AGENTS.md` is what human contributors and other AI assistants
read. If the pre-flight agent learns a rule, that rule goes into
`AGENTS.md` first; the agent's behavior derives from the document, not
the other way around. That's how you keep the agent legible to a
maintainer in year three, and how you avoid the agent becoming a private
oral tradition.

#### 5. Anti-recommendations — what the agent must not do

Even if it could, the agent should not:

- **Auto-merge anything.** Including "trivial" doc fixes and formatter-
  bot PRs. The team's manual cadence is a feature, not a bottleneck for
  the agent to remove.
- **Be a required check.** The agent is advisory. An outage of the agent
  must never block PRs from flowing. Required-status would couple the
  team's velocity to the agent's uptime.
- **Generate or modify the changeset file itself.** Suggest the bump
  level, render a draft message in the PR comment, but never push to a
  contributor's branch. The changeset message lands verbatim in release
  notes via `@changesets/changelog-github`; authorship belongs to the
  contributor.
- **Apply or change labels.** The labeler bot owns labels. The agent
  reads them.
- **Edit anyone else's comments.** Only its own sticky comment.
- **Use opaque retrieval as the primary reasoning surface.** If the
  agent says "this looks like a public-API change," it should be because
  it diffed the exports map — not because cosine similarity to past PRs
  lit up. Retrieval is a "have we seen this pattern" affordance, not a
  substitute for deterministic checks.
- **Speculate about reviewer intent.** "A reviewer will probably ask you
  to..." → reframe as "the contributor manual says..." with the link.
  The agent has citations, not opinions.
- **Welcome first-time contributors.** That's `congrats.yml`'s job.
- **Post on every push.** Edit the sticky comment in place.
- **Run on draft PRs without an explicit opt-in label** (`preflight:
  please-check`). Drafts are scratchpads; friction during exploration is
  anti-helpful.
- **Triage PRs from `[ci] release` or the changeset bot.** Bot PRs route
  to humans, not other bots.
- **Touch `withastro/docs` directly.** Docs PRs are a separate trust
  surface in a separate repo; the agent's role is at most to flag "this
  PR's Docs section says N/A but it touched public API — confirm a docs
  PR is unnecessary."

#### Landing order

Each step ships standalone value, can be paused after, and the team can
stop entirely if the next step doesn't earn its keep.

**Step 1 — `AGENTS.md` upgrade pass.** Before any agent code, consolidate
into `AGENTS.md` the rules the agent will encode: the changeset-bump-
level guide, the fixture-`outDir` trap, the import-from-`dist` rule, the
public-vs-internal exports map invariant, the `runtime/`-no-Node-APIs
rule, the integration-factory shape. This is a strictly-human improvement
that lands value even if the agent project is canceled tomorrow — every
human contributor and every other AI assistant a contributor reaches for
benefits from the same consolidation. It's also the contract the agent
will read at runtime, so writing it first inverts the dependency
cleanly.

**Step 2 — Read-only commenter on one surface only.** Ship
`.github/workflows/preflight-agent.yml` plus a small Python script using
`langchain.create_agent`. The script reads the PR diff via `gh api`,
reads applied labels, and handles exactly one case: missing-or-mismatched
changeset on PRs labeled `pkg: integration`. Posts one sticky comment.
Why this scope: integration PRs are the highest-leverage volume (the long
tail of the ecosystem), the changeset check is the most deterministic
rule in the catalog, and shipping read-only-on-one-label tests the
deployment shape before the routing table expands. Behind a `preflight:
please-check` label, opt-in only, until confidence builds.

**Step 3 — CI-failure explainer on the same surface.** Extend the agent's
tool surface with one capability: read CI logs for failing jobs on this
PR. For `pkg: integration` PRs with red CI, the agent identifies the
failing job and posts the local-reproduction command from
`astro-ci-checks` patterns, plus the most likely cause (fixture-`outDir`
trap, import-from-`dist`, `lint:ci` needs a fresh build, fork-build-
skipped, etc.). Still integration-only, still opt-in. This step turns
the agent from a checker into a helper, which is where the maintainer-
time-saved curve starts to bend.

**Step 4 — Surface expansion via the routing table.** Remove the `pkg:
integration`-only restriction; ship the routing table from §2. The router
is a `before_model` middleware; each row is a deterministic checklist
file the agent loads on demand. At this point the team has felt out
accuracy on integrations and can decide whether to flip from opt-in to
opt-out (the agent runs unless labeled `preflight: skip`).

**Step 5 — Eval harness and the `evaluate` gate.** Stand up the LangSmith
dataset of 20–50 hand-curated historical PRs annotated with expected-
comment shape. Wire `Client.evaluate(...)` to run on PRs against the
agent's main branch on a schedule. From here forward, any prompt change,
model change, or context-JSON regeneration runs through the eval gate.
This is the durable lever for keeping the agent honest as Astro evolves,
and it's where the `langsmith` dependency starts paying for itself.

**Step 6 (optional, deferred) — Historical-PR retrieval.** Only if §5's
eval results show the deterministic checks miss recurring patterns.
Index closed PRs into a vector store, expose a `find_similar_past_prs`
tool to the agent, run it before final-comment composition. Promote a
new index only when it beats the current on the eval set. Likely not
needed for the pre-flight agent — included so the path exists if the
data says otherwise.

The through-line: ship value before complexity, keep every step
independently promotable, and never introduce infrastructure (LangGraph
Server, vector store, checkpointer) until the previous step's results
have made the case for it. The choice you have at each step is to
promote or stop — never to roll back.
