---
name: skill-engine-context
description: "Answers questions about nick-railsback/skill-engine — the Claude Code plugin that scaffolds and maintains 'contextualizer' skills. Covers its workflows (bootstrap, discover, refresh, review, apply, self-audit, status), the source-paths.json and reference-file artifact contract, the four reference invariants and verify.sh checks, the staging/proposed review model, monorepo handling, and versioning. References load on demand from references/."
---

# Context navigator

## Overview

This navigator catalogs references for the source(s) registered with the engine. The navigator itself stays small; references load only when relevant to the current question.

When asked a question this navigator's domain covers:

1. Scan the **Catalog** below for the matching topic.
2. Follow the link to read the reference file.
3. If the question spans multiple references, consult the **Cross-reference map**.
4. If a reference points at a source URL for deeper detail, follow it only if the reference itself didn't answer the question.

## Claims policy

Cite by default, and make load-bearing claims verifiable:

1. **Inline-cite every load-bearing claim with its SHA-pinned permalink** — the `https://github.com/<owner>/<repo>/blob/<sha>/<path>#L<start>-L<end>` link the reference gives for that fact (versions, defaults, signatures, deprecations, behavior a user could get wrong by guessing). Put the permalink inline, on the claim. Use a bare filename parenthetical (e.g. *(reference-name.md)*) only when the reference genuinely provides no permalink. This inline permalink is what the grounded-citation eval (SELF-AUDIT Check 8) grades.
2. Don't cite orientational prose — *"what is X?"*, *"when did X launch?"* — answer those from this navigator alone; opening a reference is itself a citation gesture.
3. End with a one-line provenance footer, emitted italic, formatted `*References consulted: foo.md, bar.md. Grounded in {{LIBRARY}}@{{VERSION}} — [reference index]({{INDEX_URL}}).*` The footer is a **summary of what you read — not a substitute** for the inline permalinks on the claims. The `{{LIBRARY}}` / `{{VERSION}}` / `{{INDEX_URL}}` tokens are agent-substituted at answer time, so they appear literally in the stamped `SKILL.md`.
4. If no reference was opened, say so in the footer (*"Answered from general knowledge — no {{LIBRARY}} references consulted"*) — never fake it.

The voice is competent and careful — no "as an AI assistant" hedging.

## Local operating notes

Working preferences for this machine, not upstream behavior. They live in the
navigator rather than `references/` because DISCOVER and REFRESH regenerate
that corpus and its permalink-density lint expects upstream citations.

- **The apply gate is intentional — never an error.** `apply` blocks when
  review never ran, or when `REVIEW.md` Step 2 still holds its unpopulated
  placeholder. If the user asks to skip review, say upfront that the gate will
  block and ask whether to override explicitly. Do not stall on it, retry
  around it, or report it as a failure.
- **Replace template placeholders in place.** When generating reference files,
  substitute into the placeholder — never append content after it.
- **SHA-pin every source reference.** See
  [invariants](references/nick-railsback-skill-engine-invariants.md) for the
  permalink form and what enforces it.

## Catalog

| Reference | Description |
|---|---|
| [overview](references/nick-railsback-skill-engine-overview.md) | Start-here orientation: what skill-engine is, the four-part contextualizer anatomy (navigator + references/ + source-paths.json + verify.sh), the three install levels, the bootstrap→discover→review→apply lifecycle with the full command catalog, and how a contextualizer answers a question at runtime. |
| [principles](references/nick-railsback-skill-engine-principles.md) | The engine's design philosophy — progressive disclosure, goal-given delegation to the model, consent-gated source materialization, treating crawled content as data, and the trust model (verify.sh checks + human reviewer + permalink density; run-to-run variance is expected). |
| [artifact-contract](references/nick-railsback-skill-engine-artifact-contract.md) | The data contract: the research/source-paths.json per-source schema and its enums (kind/status/lifecycle.state), the four source kinds and url-XOR-path rules, reference-file shape (no frontmatter, depth-1, file vs directory form), git-managed permalink vs web-doc/external-doc provenance citations, the optional SKILL.json trijection, and the navigator 5K budget. |
| [invariants](references/nick-railsback-skill-engine-invariants.md) | The four reference invariants (first-5K, depth-1, max-100-line-TOC, SHA-pin), the paragraph→permalink density rule, and the eleven verify.sh named checks with their PASS/FAIL/N-A/WARN semantics — what the gate enforces mechanically vs what the reviewer backstops. |
| [discover-refresh](references/nick-railsback-skill-engine-discover-refresh.md) | The two content-generating pipelines — DISCOVER (writes new references) and REFRESH (re-checks against upstream) — their goal-given posture, in-scope filter, consent-gated clone cache, the staging/proposed-dir model with manifest.json, and the review/apply/discard gate commands. |
| [workflows](references/nick-railsback-skill-engine-workflows.md) | The full `/skill-engine:` slash-command surface — using-skill-engine router, engine-bootstrap, review, apply, discard, status, new-reference, clean-cache, config-set — with where each writes (live vs staged) and the review→apply gate as its spine. |
| [monorepo](references/nick-railsback-skill-engine-monorepo.md) | How the engine treats a single source that is itself a monorepo — DISCOVER-deferred workspace-member detection (packages/apps/libs/crates), the WARN-not-FAIL monorepo-coverage heuristic, and the monorepo-config.json slice adapter (path-scoped SHA, sparse-checkout). |
| [versioning](references/nick-railsback-skill-engine-versioning.md) | How the engine versions and releases itself (single-version ecosystem, semver posture, gated manual release), the CI-enforced template/example byte-sync and version-parity doctrine, and how a stamped contextualizer migrates across major plugin revisions. |
| [evaluation-and-audit](references/nick-railsback-skill-engine-evaluation-and-audit.md) | The read-only SELF-AUDIT drift checks (including Check 7 permalink density and Check 8 grounded-citation), the routing evaluation harness, and coverage-testing instruments — and how self-audit, verify.sh, and human review divide the trust responsibilities. |

## Cross-reference map

- **"What is skill-engine / how do I get started?"** → `overview` first; it sketches every other reference.
- **"How do I build or maintain a contextualizer end-to-end?"** → `overview` for the lifecycle map, then `discover-refresh` for the pipeline mechanics and `workflows` for the exact command contracts.
- **"What must a reference / navigator / `source-paths.json` look like?"** → `artifact-contract` for the shape and schema; `invariants` for the four invariants and the verify.sh checks that enforce them.
- **"Why did verify.sh or self-audit flag something?"** or **"what does check X do?"** → `invariants` for the verify.sh named checks; `evaluation-and-audit` for the SELF-AUDIT drift checks and the grounded-citation eval.
- **"How does discover stage its writes / what's in the `.proposed` dir?"** → `discover-refresh` (staging model + `manifest.json`), then `workflows` for review→apply→discard.
- **"`apply` won't run / it says review is required."** → `workflows` (the review→apply gate: apply blocks until `REVIEW.md` Step 2 is populated).
- **"Why does the engine work this way?"** → `principles`; pairs with `invariants` (the trust model) and `discover-refresh` (goal-given delegation).
- **"My source is a monorepo."** → `monorepo`; pairs with `discover-refresh` (how members become references).
- **"What changed across versions / how do I upgrade a contextualizer?"** → `versioning`.

## Markdown style for generated references

Reference files use **soft wrapping**: one paragraph per line, no hard line breaks at fixed column widths. Editors and rendered Markdown reflow at viewport width. Do not insert manual line breaks within a paragraph to keep lines under ~80 columns — that produces mid-sentence breaks in rendered output and makes diffs noisier. Code blocks, tables, bullet lists, and headings follow their own rules; this directive applies to prose paragraphs only.

## Instructions to Claude

When loading a reference file, the path syntax depends on the platform:

* **Claude Code**: Read the reference using the platform-provided skill-directory variable: `Read $CLAUDE_SKILL_DIR/references/<source-slug>-<topic>.md`

* **Claude Desktop**: Read the reference using a relative path; the platform resolves it from the skill's installed location: `Read references/<source-slug>-<topic>.md`

Loading rules:

* Load one reference at a time unless the Cross-reference map says to load both.
* If the primary reference doesn't fully answer the question, follow any source URL pointers it provides for deeper detail.
* Do not eagerly load companion files; only follow companion links when the primary reference says to.
* If the user's question is clearly out of scope for this contextualizer, don't invoke this skill at all.

## Progressive disclosure

References prioritize curated insight over re-specifying upstream sources:

* **Gotchas, cross-system patterns, and "why" context** are kept in the reference (curation value).
* **Exact schemas, API signatures, and parameter lists** are summarized in the reference and linked to their authoritative source via source URLs.

When a reference includes a source URL pointer, follow it only when the reference's own summary didn't cover the question. The contextualizer is optimized for the common case; the upstream source is the long tail.

## Optional SKILL.json sibling

This navigator MAY ship a `SKILL.json` sibling alongside this `SKILL.md` for machine-readable consumers (downstream tools and non-Claude agents that prefer structured metadata to markdown parsing). The sibling is purely opt-in additive — contextualizers without it pass verification unchanged.

When `SKILL.json` is present, the `## Catalog` table above, the SKILL.json `catalog[]` entries, and the `references/<source-slug>-*.md` files on disk must be in three-way correspondence. Entries carrying `"draft": true` in SKILL.json are excluded from this trijection and surface as a one-line summary at verify time. The `skill-json-trijection` named check fires only when SKILL.json is present; absence is a silent-skip pass.
