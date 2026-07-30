---
name: self-audit
description: Use when checking an existing contextualizer for drift — stale dates, broken URLs, catalog/content disagreement, and more — every two to four weeks; read-only unless the user opts into fixing the deterministic checks.
---

# Self-audit

Run the eight drift checks against the contextualizer's current state: stale
date, broken URL, long-untouched reference, catalog-vs-content disagreement,
cross-reference-vs-content disagreement, review-state staleness,
paragraph→permalink density, grounded-citation rate. Read-only by default; after the findings table
prints, offers an opt-in propose → validate → approve gate for the three
deterministic checks (stale dates, catalog-row drift, review-state
staleness). The other five checks remain advisory — they print a one-line
recommendation each and the human acts manually.

## Contextualizer root

Engine workflows operate inside a contextualizer installed as a project
skill at one of three install levels:

- **User-level:** `~/.claude/skills/<slug>-context/`
- **Local-user-level:** `~/.claude/local/skills/<slug>-context/` (when in use)
- **Project-level:** `<repo>/.claude/skills/<slug>-context/`

Every path below — `research/...`, `references/...`, `verify.sh` —
resolves relative to whichever directory matches. Before reading
anything, locate the root by searching all three install levels in
order:

Run the script in [`shared/locator-block.md`](../../shared/locator-block.md) verbatim before proceeding.

### Selecting a contextualizer

`/skill-engine:self-audit <name>` names the contextualizer to audit:
`<name>` is the directory name without the `-context` suffix, the same
grammar `review`/`apply`/`discard` use. Substitute it (or the empty
string) for `<name>` in the locator above. With no argument,
auto-detection applies — it succeeds when exactly one contextualizer is
installed and lists the matches and exits when more than one is.

Read every subsequent `research/foo` path as `$CTX_ROOT/research/foo`,
every `references/foo` as `$CTX_ROOT/references/foo`, and `verify.sh` as
`$CTX_ROOT/verify.sh`.

## Doctrine surface

The complete SELF-AUDIT protocol — what the eight drift checks do, what they
emit, how the reviewer acts on findings — lives in chapter [`03-engine.md`](../../docs/03-engine.md)
under `## SELF-AUDIT (drift audit)` and the `## Workflow: SELF-AUDIT` section
of [`maintenance-agent.md.template`](../../engine-bootstrap-templates/maintenance-agent.md.template).

## Cadence

Every two to four weeks. Pair with `discover` on the same day for a quarterly
rhythm.

## Invariants

SELF-AUDIT is **read-only by default**. It surfaces findings and exits unless
the human explicitly opts in to applying the deterministic fixes among them
(see "Optional fix flow" below). Two HARD-GATEs remain in force at all times:
no write without explicit human approval, and pre-approval validation must
pass via the contextualizer's `verify.sh` run against the sandbox copy.
Neither gate has an override.

When no human-approval gesture occurs (default path), the audit does not
auto-rewrite catalog rows, does not fetch upstream beyond a HEAD probe, and
does not modify `research/.research-state.json`.

Every audit run records an entry per check — no silent skips. `N/A` entries
include the one-line reason the check did not apply (e.g., "all references
mtime today; no comparison window yet" or "no source URLs in scope"). The
output table format is documented in [`03-engine.md`](../../docs/03-engine.md) under SELF-AUDIT
"Output format."

SELF-AUDIT scope is framing drift, not invariant compliance.
Artifact-contract questions (frontmatter rules, file naming, the four
reference invariants) are owned by `verify.sh` and should not be surfaced
as SELF-AUDIT findings even when something looks off. If the auditor
notices a contract-side question while running, it belongs in the
session-reflection's `## Template ambiguities` block, not the findings
list.

## Check 6 — review-state staleness

Surfaces when a contextualizer's persisted sign-off
(`research/review-state.json`) has aged out of agreement with
`research/source-paths.json`'s per-source `lifecycle.last_checked` —
auto-fixable via the same propose → validate → approve gate as Checks 1
and 4. The staleness heuristic, output format, idempotency guarantee, and
staging-gate-bypass rationale are in
[`references/check-6-and-fix-flow.md`](references/check-6-and-fix-flow.md).

## Check 7 — paragraph→permalink density

Measures structural-honesty density on the references corpus: the
fraction of prose paragraphs carrying a SHA-pinned GitHub permalink
within 5 lines, ≥80% corpus-wide to PASS. Judgment-required, not
auto-fixable. What counts as a paragraph or a permalink, the aggregation
rule, and the exact output format are in
[`references/check-7-permalink-density.md`](references/check-7-permalink-density.md).

## Check 8 — grounded-citation rate

Measures the answering side: for each `needs_reference` eval prompt, did
the model open a reference and cite a SHA-pinned permalink? Opt-in
(`SKILL_ENGINE_RUN_EVAL`), ≥80% threshold, judgment-required. The N/A
rules, cost/dependency notes, and output format are in
[`references/check-8-grounded-citation-rate.md`](references/check-8-grounded-citation-rate.md).

## Optional fix flow

After the findings table, classify each finding auto-fixable (Checks 1,
4, 6) or judgment-required (the rest). On opt-in, draft fixes on a
sandbox copy, validate via `verify.sh`, and surface the diff for
explicit APPROVE / DEFER / REJECT. The exact prompt copy, the three
auto-fix mutations, and the judgment-required recommendation examples
are in
[`references/check-6-and-fix-flow.md`](references/check-6-and-fix-flow.md).
