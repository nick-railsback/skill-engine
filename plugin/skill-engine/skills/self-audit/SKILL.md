---
name: self-audit
description: When the user wants the engine to audit its own configuration and recently emitted artifacts for invariant violations and drift.
---

# Self-audit

Run the six drift checks against the contextualizer's current state: stale
date, broken URL, long-untouched reference, catalog-vs-content disagreement,
cross-reference-vs-content disagreement, review-state staleness. Read-only
by default; after the findings table prints, offers an opt-in propose →
validate → approve gate for the three deterministic checks (stale dates,
catalog-row drift, review-state staleness). The other three checks remain
advisory — they print a one-line recommendation each and the human acts
manually.

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

## Check 6 — review-state staleness

Check 6 surfaces the case where the contextualizer's persisted sign-off
(`research/review-state.json`, written by `/skill-engine:apply` per Batch 4
AC1) has aged out of agreement with the upstream-state record carried in
`research/source-paths.json` per-source `lifecycle.last_checked` fields.
SELF-AUDIT is read-only by default; Check 6 runs the same way and only
proposes a mutation through the existing auto-fix opt-in prompt.

**Staleness heuristic.** A contextualizer's `review_state` is auto-flipped
to `"stale"` when either of the following holds:

- **Ledger present and outdated.** `research/review-state.json` exists with
  `review_state ∈ {"reviewed", "provisional"}` AND **any** in-scope
  `git-managed` source in `research/source-paths.json` has
  `lifecycle.last_checked > reviewed_at` AND `lifecycle.last_checked_sha`
  is non-null. The semantics: REFRESH only writes `last_checked` (and only
  writes `last_checked_sha`) when it successfully probed upstream; a
  `last_checked` newer than `reviewed_at` therefore signals "REFRESH
  observed upstream after the user attested" — strictly stronger than
  "time has passed." Per-source granularity is OR-reduced: any one source
  qualifying flips the whole skill to stale.
- **Ledger absent on a legacy skill.** When `research/review-state.json`
  does not exist AND the skill carries at least one in-scope `git-managed`
  source with a non-null `lifecycle.last_checked_sha`, the skill predates
  Batch 4 and is treated as stale on the first SELF-AUDIT run that
  surfaces it. Fresh-bootstrap skills with no `last_checked_sha` yet (no
  DISCOVER/REFRESH has probed) are N/A, not stale.

SELF-AUDIT does not differentiate per-source staleness in the finding — it
surfaces the skill as one unit. The maintainer's options after a staleness
finding are (a) run REFRESH to bring the references in line with current
SHAs, then `apply` with `reviewed`, or (b) hand-edit `review-state.json`
to bump `reviewed_at` and attest that the user reviewed the implicit diff.

**Output format.** Check 6 emits a `[WARN]` line in the existing
SELF-AUDIT output format:

```
[WARN] review-state-stale: reviewed_at 2026-04-02T14:00:00Z; source <id>'s last_checked is 2026-05-15T09:31:00Z (sha def5678). Run REFRESH + apply or accept the staleness flag.
```

When no in-scope `git-managed` source carries a `last_checked_sha` (fresh
bootstrap, pre-DISCOVER), Check 6 emits one N/A entry with the standard
one-line reason: `[N/A] review-state-stale: no in-scope git-managed source has been probed yet.`

**Auto-fix class.** Check 6 is auto-fixable in the Check-1/Check-4 sense:
there is a single deterministic mutation — rewrite
`research/review-state.json` so `review_state: "stale"` (other fields
unchanged). Wire it into the auto-fix opt-in prompt alongside Checks 1
and 4.

**Bypass of the staging gate.** The Check-6 mutation is NOT routed through
the Batch-3 `<slug>-context.proposed/` staging gate. SELF-AUDIT's existing
fix flow writes directly to the working tree via its sandbox-validate
→ APPROVE path, and `review-state.json` mutations follow that same
pattern. The rationale: a stale flag is engine state about the skill's
review status, not skill content; routing it through `.proposed/` +
`REVIEW.md` would invert the trust signal (the engine asking the user to
predict whether their own ledger should say stale).

## Optional fix flow

After the findings table, when total findings > 0, classify each finding as
auto-fixable (Checks 1, 4, and 6) or judgment-required (Checks 2, 3, 5).
The three auto-fixable checks have a single correct mutation:

- **Check 1 (stale `as of` dates):** refresh the date to today's UTC date.
- **Check 4 (catalog row vs frontmatter `description`):** sync the catalog
  row's one-line description to the reference frontmatter's `description:`
  field (the canonical statement).
- **Check 6 (review-state staleness):** rewrite
  `research/review-state.json` so `review_state: "stale"` (other fields
  unchanged).

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

Check 6 (review-state staleness) is auto-fixable and follows the same
`y` / `n` / `select` prompt — `M` counts include Check 6 findings. The
single mutation rewrites `research/review-state.json` so
`review_state: "stale"`; other fields stay as-is.

When all findings are judgment-required (M == 0), skip the prompt and print
only the recommendation list.
