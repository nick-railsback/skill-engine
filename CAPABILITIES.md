# Capabilities

Skill-engine builds navigator skills that reason across many sources at once.
Register a git repository, an external doc set, a local path, a giant monorepo
— register all four — and the engine emits one skill that holds the tensions
between them: the older intent, the newer correction, the constraint that
overrides both. The unit of value is not "a skill that knows your repo." It is
*the navigator that composes them*: per-domain contextualizers, each expert in
one source, assembled into a single skill that holds their disagreements as
output, stays accurate against its upstreams, and audits itself when it drifts.
The [README](./README.md) makes the one-paragraph case for that; the rest of
this document is the detail behind it.

**Where this earns its keep.** The contextualizer's value is *grounded,
auditable, offline* answers over a chosen corpus — one local read, every
load-bearing claim pinned to a reviewed snapshot at a fixed commit, no per-query
web fetch. On a large, well-documented *public* library, a web-enabled frontier
model is already competitive on correctness, so the edge there is provenance and
reproducibility rather than raw accuracy. The leverage is highest where the web
can't help at all: **private code and internal docs** the model has never seen,
and **air-gapped or cost-controlled deployments** where live search isn't an
option. The bundled `examples/` use public libraries because a stranger can
verify them — they demonstrate the mechanism, not the ceiling of its value.

## Contents

- [How it synthesizes across sources](#how-it-synthesizes-across-sources) — multi-source reasoning, per-domain contextualizers, composition discipline
- [How it knows it's still right](#how-it-knows-its-still-right) — five self-audit checks, four reference invariants, the bijection
- [How it stays accurate](#how-it-stays-accurate) — SHA-pinned drift detection, REFRESH, stale-date and circuit breaker
- [How you evaluate it](#how-you-evaluate-it) — three runs, 70/30 split, three-persona stratification, drop-in templates
- [How it gets built](#how-it-gets-built) — DISCOVER, source-paths.json, bootstrap scaffolding
- [How it handles failure](#how-it-handles-failure) — archived, renamed, deleted, transient, permanent
- [How it's distributed](#how-its-distributed) — plugin install, hand-rolled, Claude Desktop
- [How human review fits](#how-human-review-fits) — propose–review–promote, gates, SHA audit trail
- [Appendix — Command reference](#appendix--command-reference) — every slash command and what it does

---

## How it synthesizes across sources

A navigator skill earns its keep precisely when no single source has the whole
answer. Skill-engine produces skills that meet that bar by composing per-domain
contextualizers, each one expert in its own source, each one written so the
others can stand next to it without overlap. A careful prompt with four
pasted documents collapses under the fifth; a navigator built this way
doesn't, because the routing discipline and the freshness contracts are
properties of the artifact, not of the operator's working memory.

Every contextualizer is a small skill that knows one source kind — a git
repository, an external doc set, a local path, a monorepo slice — and
describes *when* to consult it rather than *what* it contains. At query time
the navigator consults the contextualizers whose descriptions match — often
more than one — and synthesizes their answers into a single response that
names where they agree and where they don't. Composition is enforced by the
WHEN-not-WHAT description discipline: each contextualizer's description names
the queries it owns, so the navigator can pick correctly when N descriptions
sit side by side. For monorepos — where a single "source" may be the size of
all the others combined — the freshness unit is the *slice* (one
contextualizer per coherent subtree), which is how the model scales from four
sources to hundreds without the contextualizer set turning into mush. The
rest of this section walks the composition rules, the synthesis behavior at
query time, and the scaling targets.

### Multi-source synthesis at build and query time

The synthesis is built at discover time: the model reads each source,
decides what matters, writes references that cite their origins by
`(source_id, path, sha)` triple, and the navigator's catalog maps each
reference back to the sources it draws from. Reasoning across that graph
happens at query time — when Claude answers a question that touches four
sources at once, it holds the tensions between them.

This is what the Solutions Engineer persona depends on. Five competing
payment protocols plus a business-context skill collapse into one reasoning
surface; Claude weighs them against each other rather than reading them in
sequence. The Senior Product Manager persona depends on the same primitive
in a different dressing: Confluence-exported strategy memos register as an
`external-doc` source, the platform monorepo registers as `git-managed`,
and the navigator surfaces where documented intent and deployed reality have
drifted.

Not because the engine works on any single source — because it holds across
all of them.

### Per-domain contextualizers compose cleanly

Each contextualizer is a Claude skill at `.claude/skills/<slug>-context/`
with its own `source-paths.json`, its own references, and its own navigator
description. Skills are namespaced by directory. Two contextualizers
referencing concepts with the same name (e.g., both have a "Gateway"
concept that means different things) don't collide because each lives
inside its own navigator's catalog.

A solutions engineer evaluating five payment protocols can spin up one
contextualizer per protocol, plus one for the business domain. When she
asks Claude *"does AP2 plus ACP cover our purchase range, or do we need
MPP?"* — only the contextualizers whose descriptions match that intent
fire. The business one (her catalog is in scope), the AP2 navigator
(mandates mentioned), the ACP navigator (checkout mentioned). MPP doesn't
activate unless the question reaches into it.

### The WHEN-not-WHAT description discipline

Composition only works if each contextualizer's top-line description
describes *when to invoke* rather than *what it is*. If two protocol
contextualizers describe themselves overlappingly ("payment protocol for
AI agents"), they'll both fire on every payment question whether they're
relevant or not — defeating the layered-loading benefit.

Skill-engine's evaluation harness (see [How you evaluate it](#how-you-evaluate-it))
exists precisely to tune these descriptions before they ship. The harness
scores how reliably each contextualizer activates on in-scope queries and
stays dormant on out-of-scope ones.

### Cross-contextualizer awareness

Contextualizer A can reference contextualizer B's outputs by name. The
Solutions Engineer's protocol contextualizers can cross-reference each
other (*"see also `acp-protocol-context/references/acp-checkout.md` for
how ACP integrates with AP2 mandates"*) without merging into a single
mega-contextualizer.

### Monorepo slice as freshness unit

A multi-gigabyte monorepo's parent HEAD advances on every commit;
SHA-comparison against the parent HEAD would invalidate every reference in
the contextualizer on every push. Skill-engine treats *slices* as the
freshness unit instead. A slice is a path-scoped sub-unit of a monorepo
declared in `monorepo-config.json`, and its SHA is *path-scoped* — the SHA
of the most recent commit touching any file matching the slice's path
patterns. CODEOWNERS scaffolds initial slices at bootstrap time.
Sparse-checkout against the slice's paths keeps the crawl bounded: the
engine reads only the slice's working tree, not the universe. The
SHA-comparison short-circuit still applies; the slice composes with the
rest of the contextualizer like any other source.

### Hundreds-of-sources scaling target

The architecture is explicitly designed for "hundreds of sources."
`source-paths.json` indexes linearly, with a deterministic `source_id`
derived from each entry's relative path (`sha256(relative-path)[:8]`).
DISCOVER and REFRESH batch operations rather than running per-source, and
the model elects subagent dispatch (capped at 10 concurrent in-flight) when
context isolation is warranted. The 8-character `source_id` value space is
safe to about a thousand sources; the design includes a future widening to
16 characters when contextualizers approach the ten-thousand-source band.

To be precise about the boundary between design and demonstration: the
"hundreds" figure is a design target the linear index and batched operations
are built for, not a benchmarked result. Demonstrated scale today is the
bundled examples (up to eight sources in `langchain-context`); the headroom
above that rests on the architecture, not on a run at that size.

### What this is *not*

Skill-engine doesn't enforce naming conventions across forks. It doesn't
auto-resolve conflicts between contextualizers that disagree on the same
concept. It doesn't ship a federation layer for community-published
contextualizers. Composition works at the loading-and-activation level —
the architectural primitive — not at the semantic-merging level. When
contextualizers disagree, the human reviewer adjudicates, not the engine.

See also: [How you evaluate it](#how-you-evaluate-it) (for tuning
descriptions for activation precision), [How it gets built](#how-it-gets-built)
(for the monorepo bootstrap recipe).

---

## How it knows it's still right

Drift detection catches *changes in the source*. Skill-engine has a second
check that catches *drift in the artifact itself*: SELF-AUDIT plus a layered
invariants regime that runs before any proposed change reaches a human
reviewer.

### The five drift checks SELF-AUDIT runs

SELF-AUDIT runs five read-only checks against the artifact — navigator,
references, catalog — for the kinds of drift the freshness checks cannot
detect:

1. **Stale `as of` dates.** Greps every reference for `as of YYYY-MM-DD`-style
   phrases more than 180 days old; flags them for human reconfirmation.
2. **Broken source URLs.** HEAD-requests every `https://` URL in the corpus,
   in parallel under a concurrency cap; flags 404s and redirects to archived
   locations. Placeholder tokens (`<commit>`, `<sha>`, `<path>`) are filtered
   out before probing so documentation patterns embedded in reference prose
   don't generate false positives.
3. **Long-untouched references on active sources.** Compares each reference's
   `last_updated` against upstream commit activity; flags references unchanged
   six-plus months while sources show 50+ commits in that window.
4. **Catalog row vs. reference content.** Diffs each catalog row's one-line
   description against the reference's frontmatter `description:` field —
   the canonical, model-readable statement of what the reference is for.
   Substantive divergence is the case the check is built to catch.
5. **Cross-reference map accuracy.** Verifies the navigator's "questions
   about X → load Y" rules still point where they should after a reference
   has drifted in scope.

### The four reference invariants

Every reference file in `references/` is authored to four shape invariants.
They differ in *how* — and *whether* — each is mechanically enforced; the
annotations below are exact:

- **first-5K** — the navigator's standing instructions (invariants, critical
  rules, dispatch logic) fit in the first 5 KB of `SKILL.md` so the platform's
  auto-compaction never silently truncates them mid-conversation.
  *(Authoring discipline — not yet machine-checked.)*
- **depth-1** — every reference is reachable from `SKILL.md` in exactly one
  link traversal; nested reference subdirectories are forbidden so Claude
  never shallow-probes a partial file.
  *(Enforced by `verify.sh`, inside its `catalog-bijection` check.)*
- **max-100-line-TOC** — any reference body over 100 lines carries a `##
  Contents` marker within the first 30 lines, so Claude lands at the right
  section instead of reading top-to-bottom.
  *(Authoring discipline — not yet machine-checked.)*
- **SHA-pin** — source-repo URLs in reference bodies are pinned to a 40-char
  commit SHA, not a branch. Branch-pinned URLs rot at 38-66% over a one-to-
  two-year horizon; SHA-pinning makes them immutable.
  *(Enforced by the `permalink_density.py` CI lint — SELF-AUDIT Check 7 — not
  by `verify.sh`.)*

### The bijection invariant

The navigator's catalog table and the set of primary references form a
bijection: every catalog row points to a real primary, and every primary
appears as a catalog row. An orphaned file is invisible to the AI; a phantom
row makes the AI try to read a missing file mid-conversation. The
correspondence is checked mechanically by `verify.sh`, or the skill doesn't
ship.

### Pre-approval validation

Before any proposed diff reaches a human, the engine runs automated checks
in an isolated sandbox at `/tmp/skill-engine-validate-<session-id>/`: no
stray frontmatter on references, catalog bijection holds, and the
contextualizer's own `./verify.sh` passes. If any fails, the engine fixes
the issue and re-runs — never surfaces broken work to the reviewer. The
fix-retry loop is capped at three attempts per proposal; a fourth failure
halts and emits a structured `attempts[]` finding for human triage rather
than masking the failure by deletion or revert. (Per-reference SHA-256
byte-equality fixtures and a full test-suite harness are pre-fixture-harness aspirational
— see [05-invariants.md](plugin/skill-engine/docs/05-invariants.md) for the
fixture-harness contract; the pre-fixture-harness state ships with `verify.sh` as the single validation
anchor.)

### What's deliberately not built

SELF-AUDIT does not validate the artifact contract — the four reference
invariants and the bijection are owned by `verify.sh`, not by SELF-AUDIT.
SELF-AUDIT is the framing-drift lens; `verify.sh` is the contract lens.
Three workflows, three different lenses on the same corpus, kept separable
so a finding from one doesn't dilute a finding from another.

See also: [How it stays accurate](#how-it-stays-accurate) (for drift
detection of the underlying sources), [How human review fits](#how-human-review-fits)
(for the propose–review–promote loop).

---

## How it stays accurate

The maintenance question every long-lived knowledge artifact faces: *will it
still be correct six months from now?* Static CLAUDE.md files and unmaintained
skill directories silently bit-rot. Skill-engine treats freshness as a
first-class concern.

### Drift detection via SHA-comparison

Every source registered in `source-paths.json` is pinned to its content hash
at ingest time. When you run `/skill-engine:refresh`, the engine re-fetches
each source's current SHA and compares against the pinned value. A hash
change means the upstream has shifted — and the references derived from that
source may no longer reflect reality.

The pinning happens at the (source_id, path, sha) triple level — fine enough
to detect any meaningful upstream change, coarse enough that REFRESH runs in
seconds against tens of sources and costs cents per cycle.

### The REFRESH workflow

REFRESH is a three-phase freshness staircase: sandbox isolation (each source
is re-checked in isolation so a flaky upstream can't poison the run), then
re-emission of references where the SHA moved, then human review of the
proposed diffs.

REFRESH does not auto-merge. It surfaces a per-file diff plus a one-line
rationale (*"src/api/routing.py changed lines 12-30; updated reference to
match"*). You approve, defer, or reject each one.

### Stale-date detection

Beyond SHA-level changes, skill-engine flags references that haven't been
*reviewed* in N days. A reference whose SHA hasn't moved in six months but
whose surrounding ecosystem has shifted may still need a fresh look. Stale-
date detection catches that class of drift — the kind SHA-pinning can't see.

### The circuit breaker

REFRESH halts after three consecutive same-phase failures. Three SHA-comparison
errors in a row indicates a systemic issue — expired auth, rate limit, network
partition — not three flaky individual repos. Halting and surfacing state is
cheaper than retrying into a wall.

### What's deliberately not built

Skill-engine does not run REFRESH on cron, does not auto-clone upstreams, does
not parse lockfiles for transitive change detection, does not auto-rewrite
SHA-pinned URLs when a source moves. Each of these was a tempting feature; each
was set aside because manual cadence is the default operating mode — and
because automated freshness against a moving target is the failure mode every
RAG-based tool ships with.

See also: [How it knows it's still right](#how-it-knows-its-still-right) (for
SELF-AUDIT, the framing-drift check), [How human review fits](#how-human-review-fits)
(for the reviewer gate semantics).

---

## How you evaluate it

Most Claude skills ship with no evaluation harness. Their authors hope the
navigator description triggers reliably and that the references answer
questions accurately, but nobody checks. Skill-engine ships the harness.

### Three runs per query

Every eval entry runs three times per invocation. Language-model routing is
not deterministic at the matching layer — a description that fires correctly
two runs out of three is a different signal from one that fires three out of
three, and single-run evaluation hides that distinction. The harness records
pass/fail per run; the renderer reports the majority-vote outcome and flags
any entry that *flickers* across the three runs. Flickering is itself a
signal: it usually points at a description that almost-but-not-quite
discriminates, and the fix is editing the description, not retrying.

### 70/30 train/test split

When the eval set has more than ten entries, hold out a random 30% as
`evals/evals-test.json` and use the remaining 70% as `evals/evals-train.json`.
Two files, not one buffer with a flag — physical segregation is what makes
over-fitting take work. The train set is what you iterate against while
editing the navigator description; the test set runs occasionally, at
description-stability checkpoints, to check whether train-set gains generalize.
If the test-set pass rate diverges from the train-set pass rate over time,
the description has been over-fit to the train set's specific phrasings; the
fix is new entries drawn from real consumer queries, not invented.

### Three-persona stratification

Each eval entry carries a `persona` field naming the audience phrasing:
`domain-expert` (the maintainer's natural register, fluent in the jargon),
`domain-naive-technical` (a senior engineer from a sibling team — technically
literate but unfamiliar with this specific domain), and `non-technical`
(a PM, support engineer, or end-user phrasing the question without jargon).
Author the eval set with all three personas represented in roughly equal
proportion — a heavy `domain-expert` bias is the default failure mode, and
a description tuned only against expert phrasing passes its own evals and
fails real users. The renderer stratifies aggregation per-persona AND
overall, so the maintainer can see which audiences route well and which
don't.

### Deterministic renderer

The renderer is byte-identical across runs on the same `results-*.json` file.
No timestamps in output, no random ordering. Determinism is what makes the
diff between two renderer runs a meaningful artifact to paste into a pull
request review.

### Drop-in eval templates

Three templates ship with the plugin under
`plugin/skill-engine/engine-bootstrap-templates/eval/`:
`run-eval.sh.template` (the bash harness, zero third-party dependencies),
`eval-viewer.html.template` (a single-file HTML5 viewer that loads results
from `file://` with no fetch), and `render-eval-results.sh.template` (the
deterministic aggregator that produces persona-stratified summaries and
per-query deltas). You don't build evaluation infrastructure from scratch;
you fill in queries against the schema.

See also: [How it synthesizes across sources](#how-it-synthesizes-across-sources)
(for the WHEN-not-WHAT discipline the eval harness measures).

---

## How it gets built

Two questions every adopter has: *what do I point this at*, and *how does it
decide what to write*. Skill-engine answers both with explicit, reviewable
primitives rather than opaque automation.

### Goal-given DISCOVER

The planning engine. `/skill-engine:discover` hands the model a task —
*"discover the essence of the registered sources; write references for the
parts that matter; satisfy the four reference invariants (first-5K, depth-1,
max-100-line-TOC, SHA-pin)"* — and validates the structural output via
`verify.sh` (with SHA-pinning checked by the `permalink_density.py` lint)
rather than prescribing a step-by-step pipeline. The model decides how to spend its
context, what to read, what to skip, what to propose.

A `--hint` flag lets you steer the run with one sentence of intent — *"I'm
forward-deployed at customer accounts; surface integration patterns and the
gotchas FDEs hit most often"* — without authoring a config file. Re-running
discover is idempotent: the per-source-SHA enrichment cache at
`research/.discover-cache.json` keys on `(source_id, sha)`, so cached work
replays cleanly when sources haven't moved and only new work is paid for.

### source-paths.json — the contract

The schema for what skill-engine watches. Four first-class source kinds:
`git-managed` (repositories tracked by SHA-comparison and shallow or
sparse-checkout crawl), `external-doc` (pre-curated markdown outside any
code repository, tracked by content hash and required `source_url` /
`crawl_date` / `decay` provenance frontmatter), `web-doc` (documentation
sites acquired via WebFetch / MCP fetch — see
[docs/recipes/web-doc-setup.md](plugin/skill-engine/docs/recipes/web-doc-setup.md)
— with sitemap discovery or an explicit `page_list`, an HTTP HEAD probe in
REFRESH, and a cache at `~/.cache/skill-engine/web-doc/<source_id>-<crawl_id>/`),
and `local-path` (filesystem paths). Each kind has its own crawl strategy
and its own staleness gate; the discriminator routes downstream behavior
across DISCOVER, REFRESH, and the cache. Each entry also carries two state-machine axes that never collapse:
`status` (the curation lifecycle: `intake → confirmed | rejected`) and
`lifecycle.state` (the upstream lifecycle: `reachable | moved | removed |
unknown`). A `confirmed` source can become `removed` upstream without
invalidating the curation, and the engine surfaces both axes separately so
the reviewer sees the full picture.

### Bootstrap scaffolding

`/skill-engine:engine-bootstrap` stamps a fresh contextualizer skeleton into
`.claude/skills/<slug>-context/`. It auto-detects source kind from the URL
shape — URLs whose path ends in `/` or lacks a `.git` suffix and whose HTTP
HEAD `Content-Type` is `text/html` are proposed as `web-doc` with
`crawl_mode: sitemap` — prompts once for an explicit `branch` when the
contextualizer should follow a non-default ref, and offers (defaults to
**No**) to seed a local clone of each git-managed source into
`~/.cache/skill-engine/`. The engine never clones without explicit consent.

### Monorepo bootstrap

For monorepo sources, bootstrap reads CODEOWNERS to scaffold initial slices
— each slice is the freshness unit, not the whole repo. Subsequent REFRESH
runs sparse-checkout against the slice's path patterns and computes a
*path-scoped* SHA (the SHA of the most recent commit touching the slice's
paths), so the SHA-comparison short-circuit still applies in a multi-gigabyte
monorepo where the parent HEAD changes constantly.

### What's deliberately not built

DISCOVER does not auto-clone proposed companion sources (the author must approve
`git clone` or do so themselves); does not recurse companion discovery past depth-1;
does not parse lockfiles for transitive dependencies; does not do live
registry calls for commodity filtering by default; does not auto-detect
"archived" upstream state (the user sets `archived: true` manually); does
not auto-rewrite SHA-pinned URLs when an upstream source moves. Each
constraint preserves the goal-given posture — the engine's leverage is in
the contract, not the recipe.

See also: [How it synthesizes across sources](#how-it-synthesizes-across-sources), [How human review fits](#how-human-review-fits).

---

## How it handles failure

Most tooling documents the happy path. Skill-engine documents the unhappy
paths and ships explicit recovery for each.

### Archived upstream repo

Phase 0.5 of every freshness sweep is an archive check — one HTTP call per
source (e.g., `gh api repos/<owner>/<repo>` for the `archived` boolean, or
HTTP HEAD for a web resource) before any clone or SHA work. An archived
source short-circuits the rest of the pipeline: REFRESH flags in the
proposed diff that the source is dead and the references derived from it
should be reviewed for staleness. The user manually sets `archived: true`
on the source-paths entry; the engine never auto-flips the field. Once
archived, DISCOVER and REFRESH skip the source's crawl pass.

### Renamed or deleted branch

`source-paths.json` entries with a `branch` field track a specific upstream
ref. A named branch that no longer exists upstream is a *permanent* error:
the engine surfaces the diagnostic, transitions `lifecycle.state` to
`unknown`, and skips the source for this run rather than silently falling
back to HEAD. Silent fallback would let a contextualizer monitoring a `dev`
branch quietly start referencing main-branch commits — exactly the kind of
drift the SHA-pin invariant exists to prevent.

### Transient errors

HTTP 429 (rate limit), network timeout, DNS resolution failure, auth token
expired mid-run — these are recoverable. The engine retries with exponential
backoff up to three attempts per source. After three failures the error is
re-categorized as transient-but-blocking and the source is skipped with
explicit telemetry, leaving the contextualizer in a known-incomplete state
the reviewer can see. The retry policy lives in the workflow prompt as an
explicit matrix; the model does not invent its own retry behavior at
runtime.

### Permanent errors

HTTP 404, repo renamed, schema mismatch in an expected file format, file
unreadable — these are unrecoverable. Single skip, explicit user-facing
report, no silent retry. The batch continues with the next source so a
single dead source doesn't poison the whole REFRESH run; the dead source's
diagnostic surfaces in the proposed diff as a finding the reviewer can act
on.

### Circuit breaker

After three consecutive same-phase failures, the engine halts the batch and
surfaces current state for triage. Three SHA-comparison failures in a row
is not three flaky repos — it's expired auth, a rate limit hitting the same
endpoint, or a network partition. Doomed retries waste tokens; halting and
asking the human is cheaper. The same three-strike rule applies to the
validation fix-retry loop on any single proposal: three failed fixes halt
the loop for that proposal, emit a structured `attempts[]` finding for
triage, and continue with other queued proposals in the same session.

See also: [How it stays accurate](#how-it-stays-accurate) (for the full
freshness staircase the failure modes live inside).

---

## How it's distributed

Skill-engine ships through three paths, each suited to a different reader.
The artifact a contextualizer produces is itself distributable — a `.zip`
into Claude Desktop, a clone-and-install for Claude Code, a published
plugin for the marketplace.

### Plugin install (recommended)

`/plugin marketplace add nick-railsback/skill-engine` registers the repo as
a marketplace; `/plugin install skill-engine@skill-engine-marketplace`
stamps the engine's commands into the Claude Code session under
`/skill-engine:`. From that point forward, `/skill-engine:engine-bootstrap`,
`/skill-engine:discover`, and the rest are available in any session. This
is the lowest-friction path for a Claude Code user already inside the
environment, and it's the path the project README's quickstart recommends.

### Hand-rolled

The escape hatch. Copy
`plugin/skill-engine/engine-bootstrap-templates/maintenance-agent.md.template`
into a contextualizer's repo (e.g., as `agents/maintenance-agent.md`), then
paste its prose into a fresh Claude Code session as the system prompt. The
model reads the prompt, internalizes the engine's role, and presents the
workflow menu. The activation pattern is intentionally low-tech — no
special CLI, no SDK boilerplate. The engine's "infrastructure" is the
model's ability to follow a system prompt; anything fancier is something
else to maintain.

### Use a contextualizer in Claude Desktop

A contextualizer is a self-contained skill directory — the navigator
`SKILL.md` plus its `references/` — so it runs anywhere Claude Code skills
do, including Claude Desktop. There is no separate installer to build: to add
one to Desktop, zip the skill directory and upload it.

1. Zip the contextualizer's skill directory so the **top-level entry inside
   the zip is the skill folder itself** (`<slug>-context/`), not a nested
   path — Desktop's upload rejects nested-path zips. From the directory that
   contains it: `zip -r <slug>-context.zip <slug>-context -x '*.DS_Store'`.
2. In Claude Desktop, open the skill upload (Settings → Capabilities →
   Skills) and add the zip.
3. The skill is then available the same way it is in Claude Code.

Once installed, the contextualizer **answers entirely from its bundled
references** — the navigator reads `references/*.md` on demand. No engine
install, no clone cache, and no network are needed at answer time: the
`~/.cache/skill-engine/` clones and the engine workflows are authoring- and
refresh-time only. (The exact Desktop menu path can shift between releases;
confirm the current upload flow in Desktop's settings if it has moved.)

### Version pinning across surfaces

A published contextualizer carries one version string, in its
`.claude-plugin/plugin.json`; bump it per the release checklist in
[06-release-doctrine.md](plugin/skill-engine/docs/06-release-doctrine.md).
Content freshness is tracked separately and more granularly: every source in
`source-paths.json` pins to the reviewed upstream SHA it was last checked
against (`lifecycle.last_checked_sha`), so "what revision of the upstream
does this reference reflect" is answerable per source, not just per release.
A refresh that finds drift surfaces the SHA delta in the proposed diff for
review.

### What's deliberately not built

No SaaS distribution. No hosted service. No auto-update beyond what the
plugin marketplace itself offers. The engine has no telemetry, and makes no
network calls beyond the source fetches you explicitly confirm. Code-signing
the Desktop zip is out of scope; organizations that require it layer that on
top. The constraint stack stays bash + markdown + JSON with `jq` as the only
non-shell dependency, so the engine works the same way on every Tier 1
platform (macOS, Linux, WSL2) without a portability matrix.

---

## How human review fits

Reviewer-in-the-loop is the default operating mode. The engine surfaces
every proposed change as a diff before applying it. This is a design
choice, not a safety bolt-on — the contents of a contextualizer become
Claude's source of truth for an entire domain, and silent propagation of
wrong content is a worse failure than five minutes of review.

### The propose–review–promote loop

The reviewer gate takes two shapes, depending on what is changing. DISCOVER
and REFRESH stage their work into a sibling `<slug>-context.proposed/`
directory rather than touching the live contextualizer; the run ends with a
"Proposal staged at `<slug>-context.proposed/`" line, and promotion is a
separate, explicit step. `/skill-engine:review <slug>` drives a
predict-then-compare sign-off — the engine surfaces the manifest and the diff
command, the reviewer records in `REVIEW.md` what they expect each changed
file to say, and a second pass generates the points where prediction and
reality diverge. Only a signed-off proposal can be promoted by
`/skill-engine:apply <slug>` (atomic per-file rename, with `REVIEW.md` carried
into the live tree as an audit trail) or dropped by
`/skill-engine:discard <slug>`. SELF-AUDIT's optional fix flow uses the
lighter in-session shape instead: deterministic fixes are drafted on an
isolated sandbox copy at `/tmp/skill-engine-validate-<session-id>/` and
surfaced inline for an explicit `APPROVE` / `DEFER` / `REJECT`.

Both shapes share the same two hard gates — pre-approval validation must pass
(no stray frontmatter, catalog bijection holds, `./verify.sh` passes), and
nothing reaches the live tree without explicit human approval. On approval the
engine records the session in `research/.engine-stats.json`. (Per-reference
SHA-256 fixture refresh is pre-fixture-harness aspirational; the
pre-fixture-harness state has no fixture-refresh step.) On rejection the
proposal is logged to `research/.rejection-log.json` with a maintainer-provided
rationale; at the next session activation the engine clusters rejections by
`category × reference` and surfaces a warning when the same pattern crosses
three rejections — so the agent sees its own mistakes before proposing again.

### Per-workflow review gates

Each workflow frames its gate around its own operational question.
DISCOVER's is "should this companion source be confirmed, should this
reference land." REFRESH's is "this source moved; is the re-emission
correct." SELF-AUDIT's optional fix flow gates the deterministic
auto-fixes (stale-date refresh, catalog-row sync to the frontmatter
canonical) while leaving judgment-required findings (broken URLs, scope
drift, cross-reference accuracy) as recommendations the human acts on
manually.

### Audit trail via SHA history

Every source is SHA-pinned at ingest and at each subsequent REFRESH;
references cite their sources by `(source_id, path, sha)` triple; the
per-session `research/sessions/<session-id>.json` files record what the
agent proposed and what the human approved. Together they form a de facto
audit trail — every line of every reference is traceable to a specific
upstream snapshot, and every change to a reference is traceable to a
specific approval. A contextualizer's history is traceable, not opaque.

### Citation discipline

Reference bodies cite source-repo URLs as SHA-pinned permalinks —
`https://github.com/<owner>/<repo>/blob/<sha>/<path>#L<start>-L<end>` —
rather than branch-pinned ones. Branch-pinned URLs rot at 38-66% over a
one-to-two-year horizon; SHA-pinned URLs are immutable. The discipline holds
at two points: the permalink-density lint (SELF-AUDIT Check 7) enforces
SHA-pinning in reference *bodies*, and the navigator's Claims policy tells
Claude to *surface* those permalinks when it answers — so the reader lands on a specific
snapshot at a specific line range, not a vague gesture at "the docs." The
grounded-citation eval (SELF-AUDIT Check 8) measures the second: the worked
result in [`eval-results.md`](examples/modelcontextprotocol-python-sdk-context/research/eval-results.md)
went from 30% to 90% once the Claims policy instructed permalink citation.
Navigator prose and README pointers may carry unpinned URLs because they are
*intentional latest* — meant to track the current state of an upstream, not freeze.

### Future direction: opt-in autonomy flags

Review-first is the default; that's the v1 contract. A future opt-in flag
(e.g., `--auto-refresh` for low-risk operations — REFRESH against a source
whose SHA moved by one commit on a stable branch, say) is on the roadmap
as a deliberate direction. The flag does not exist today. It is named here
so readers know review-first is a chosen default that can relax for
specific low-risk paths, not a missing feature that simply hasn't shipped.

See also: [How it stays accurate](#how-it-stays-accurate),
[How it knows it's still right](#how-it-knows-its-still-right).

---

## Appendix — Command reference

The slash commands under `/skill-engine:` and what each does, in roughly the
order a contextualizer's lifecycle visits them — scaffold, propose, review,
audit, maintain. Operational detail lives in each workflow's `SKILL.md`; this
appendix is the index.

| Command | What it does | Read more |
|---|---|---|
| `/skill-engine:engine-bootstrap` | Scaffolds a fresh contextualizer skeleton into `.claude/skills/<slug>-context/`. | [SKILL.md](./plugin/skill-engine/skills/engine-bootstrap/SKILL.md) |
| `/skill-engine:discover` | Goal-given reference generation: reads registered sources and stages references that satisfy the four invariants for review. | [SKILL.md](./plugin/skill-engine/skills/discover/SKILL.md) |
| `/skill-engine:refresh` | Drift-triggered re-emission: re-checks SHAs, stages updated references for review. | [SKILL.md](./plugin/skill-engine/skills/refresh/SKILL.md) |
| `/skill-engine:new-reference` | Single-reference addition without a full DISCOVER pass. | [SKILL.md](./plugin/skill-engine/skills/new-reference/SKILL.md) |
| `/skill-engine:review` | Inspects a staged proposal (`<slug>-context.proposed/`) and drives the predict-then-compare sign-off in `REVIEW.md` before anything is promoted. | [SKILL.md](./plugin/skill-engine/skills/review/SKILL.md) |
| `/skill-engine:apply` | Promotes a signed-off proposal into the live contextualizer — atomic per-file rename, preserving the `REVIEW.md` audit trail. | [SKILL.md](./plugin/skill-engine/skills/apply/SKILL.md) |
| `/skill-engine:discard` | Drops a staged proposal without promoting it, leaving the live contextualizer untouched. | [SKILL.md](./plugin/skill-engine/skills/discard/SKILL.md) |
| `/skill-engine:self-audit` | Five drift checks on the artifact: stale dates, broken URLs, long-untouched references, catalog drift, cross-reference accuracy. | [SKILL.md](./plugin/skill-engine/skills/self-audit/SKILL.md) |
| `/skill-engine:status` | Read-only health report: which references are fresh, stale, or critical. | [SKILL.md](./plugin/skill-engine/skills/status/SKILL.md) |
| `/skill-engine:clean-cache` | Opt-in deletion of the local clone cache (dry-runs by default). | [SKILL.md](./plugin/skill-engine/skills/clean-cache/SKILL.md) |
| `/skill-engine:config-set` | Sets an engine-wide config value (currently the `review` diff tool). | [SKILL.md](./plugin/skill-engine/skills/config-set/SKILL.md) |
| `/skill-engine:using-skill-engine` | Router for "do something with the engine here" intent; dispatches to the right workflow based on contextualizer state. | [SKILL.md](./plugin/skill-engine/skills/using-skill-engine/SKILL.md) |
