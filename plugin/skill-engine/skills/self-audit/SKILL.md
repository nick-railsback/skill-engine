---
name: self-audit
description: When the user wants the engine to audit its own configuration and recently emitted artifacts for invariant violations and drift.
---

# Self-audit

Run the five drift checks against the contextualizer's current state: stale
date, broken URL, long-untouched reference, catalog-vs-content disagreement,
cross-reference-vs-content disagreement. Read-only by default; after the
findings table prints, offers an opt-in propose → validate → approve gate
for the two deterministic checks (stale dates, catalog-row drift). The
other three checks remain advisory — they print a one-line recommendation
each and the human acts manually.

## Contextualizer root

Engine workflows operate inside a contextualizer installed as a project
skill at `.claude/skills/<slug>-context/`. Every path below —
`research/...`, `references/...`, `verify.sh` — resolves relative to that
directory.

Before reading anything, locate the root from the project working
directory:

```bash
ctx_roots=$(find .claude/skills -mindepth 1 -maxdepth 1 -type d -name '*-context' 2>/dev/null)
n=$(printf '%s\n' "$ctx_roots" | grep -c .)
if [ "$n" -eq 0 ]; then
  echo "No contextualizer found under .claude/skills/*-context/. Run /skill-engine:engine-bootstrap first."
  exit 1
elif [ "$n" -gt 1 ]; then
  echo "Multiple contextualizers under .claude/skills/; specify one:"
  printf '%s\n' "$ctx_roots"
  exit 1
fi
CTX_ROOT="$ctx_roots"
```

Read every subsequent `research/foo` path as `$CTX_ROOT/research/foo`,
every `references/foo` as `$CTX_ROOT/references/foo`, and `verify.sh` as
`$CTX_ROOT/verify.sh`.

## Doctrine surface

The complete SELF-AUDIT protocol — what the five drift checks do, what they
emit, how the reviewer acts on findings — lives in chapter [`03-engine.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/03-engine.md)
under `## SELF-AUDIT (drift audit)` and the `## Workflow: SELF-AUDIT` section
of [`maintenance-agent.md.template`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/engine-bootstrap-templates/maintenance-agent.md.template).

## Cadence

Every two to four weeks. Pair with `discover` on the same day for a quarterly
rhythm.

## Invariants

SELF-AUDIT is **read-only by default**. It surfaces findings and exits unless
the human explicitly opts in to applying the deterministic fixes among them
(see "Optional fix flow" below). Two HARD-GATEs remain in force at all times:
no write without explicit human approval, and pre-approval validation must
pass via `worker-verify`. Neither gate has an override.

When no human-approval gesture occurs (default path), the audit does not
auto-rewrite catalog rows, does not fetch upstream beyond a HEAD probe, and
does not modify `research/.research-state.json`.

Every audit run records an entry per check — no silent skips. `N/A` entries
include the one-line reason the check did not apply (e.g., "all references
mtime today; no comparison window yet" or "no source URLs in scope"). The
output table format is documented in [`03-engine.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/03-engine.md) under SELF-AUDIT
"Output format."

SELF-AUDIT scope is framing drift, not invariant compliance.
Artifact-contract questions (frontmatter rules, file naming, the four
reference invariants) are owned by `verify.sh` and should not be surfaced
as SELF-AUDIT findings even when something looks off. If the auditor
notices a contract-side question while running, it belongs in the
session-reflection's `## Template ambiguities` block, not the findings
list.

## Optional fix flow

After the findings table, when total findings > 0, classify each finding as
auto-fixable (Checks 1 and 4) or judgment-required (Checks 2, 3, 5). The two
auto-fixable checks have a single correct mutation:

- **Check 1 (stale `as of` dates):** refresh the date to today's UTC date.
- **Check 4 (catalog row vs frontmatter `description`):** sync the catalog
  row's one-line description to the reference frontmatter's `description:`
  field (the canonical statement).

When at least one auto-fixable finding exists, prompt the human (with `K = N − M`, the count of judgment-required findings):

```
Found N findings — M auto-fixable, K need judgment.

Apply auto-fixable findings now?
  y       Draft fixes for all M; show diff for APPROVE / DEFER / REJECT
  n       Exit with findings only (default)
  select  Choose which auto-fixable findings to draft
```

Empty input is `n`. On `y` or `select`, follow the REFRESH propose →
validate → approve gate documented in [`03-engine.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/03-engine.md) §"Optional fix flow":

1. Draft the edits on the sandbox copy at `/tmp/skill-engine-validate-<session-id>/`.
2. Run `worker-verify` against the sandbox (four pre-approval checks).
3. Surface the diff for explicit `APPROVE` / `DEFER` / `REJECT`.
4. On `APPROVE`, write to the working tree; log to
   `research/sessions/<session-id>.json`; append a
   `session_type: "SELF-AUDIT"` entry to `research/.engine-stats.json`.

For judgment-required findings (Checks 2, 3, 5), print a one-line
recommendation per finding and exit without drafting any mutation. Sample
recommendations: `references/foo.md:42 — broken URL; replace manually`,
`references/bar.md — unchanged 8mo while source advanced 73 commits; run
/skill-engine:refresh`, `cross-reference map: billing → identity — verify
routing manually`.

When all findings are judgment-required (M == 0), skip the prompt and print
only the recommendation list.
