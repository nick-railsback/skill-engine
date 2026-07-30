# Check 6 and the optional fix flow

Review-state staleness detection, plus the shared propose → validate → approve mechanics every auto-fixable finding (Checks 1, 4, 6) goes through.

## Check 6 — review-state staleness

Check 6 surfaces the case where the contextualizer's persisted sign-off
(`research/review-state.json`, written by `/skill-engine:apply`) has aged
out of agreement with the upstream-state record carried in
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
  the review-state ledger and is treated as stale on the first SELF-AUDIT run that
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
`research/review-state.json` so `review_state: "stale"`, leaving
`reviewed_at` and `schema_version` unchanged. Wire it into the auto-fix
opt-in prompt alongside Checks 1 and 4.

**Idempotency (load-bearing).** The flip is one-way and self-limiting:
the "Ledger present and outdated" condition above fires *only while*
`review_state ∈ {"reviewed", "provisional"}`, so once the auto-fix writes
`"stale"` that condition no longer holds — Check 6 neither re-flags nor
re-emits the `[WARN]` on subsequent runs. `review_state == "stale"` is
itself the idempotency marker; no separate "already flagged" field is
needed. `reviewed_at` is deliberately **not** advanced by the auto-fix:
bumping it would erase the original attestation timestamp and falsely
imply a fresh review. The flag clears only when the maintainer re-attests
— a full REFRESH + `apply` (which writes a new `reviewed_at`), or a
deliberate hand-edit of `reviewed_at` — never by repeated audits. Do not
"fix" the preserved `reviewed_at` into a bump: that would re-introduce a
re-firing loop the instant `review_state` were ever reset to `reviewed`.

**Bypass of the staging gate.** The Check-6 mutation is NOT routed through
the `<slug>-context.proposed/` staging gate. SELF-AUDIT's existing
fix flow writes directly to the working tree via its sandbox-validate
→ APPROVE path, and `review-state.json` mutations follow that same
pattern. The rationale: a stale flag is engine state about the skill's
review status, not skill content; routing it through `.proposed/` +
`REVIEW.md` would invert the trust signal (the engine asking the user to
predict whether their own ledger should say stale).

## Optional fix flow

After the findings table, when total findings > 0, classify each finding as
auto-fixable (Checks 1, 4, and 6) or judgment-required (Checks 2, 3, 5, 7, 8).
The three auto-fixable checks have a single correct mutation:

- **Check 1 (stale `as of` dates):** refresh the date to today's UTC date.
- **Check 4 (catalog row vs reference body framing):** sync the catalog
  row's one-line description to the reference's body framing — the first
  paragraph under the H1, or the bullets under a `## When to Use This
  Reference` section if one is present. References carry no frontmatter,
  so the body-section heuristic is the canonical statement (see
  [`03-engine.md`](../../../docs/03-engine.md) §SELF-AUDIT check 4). If neither
  yields a usable one-line statement, demote the finding to
  judgment-required rather than inventing content.
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
validate → approve gate documented in [`03-engine.md`](../../../docs/03-engine.md) §"Optional fix flow":

1. Draft the edits on the sandbox copy at `/tmp/skill-engine-validate-<session-id>/`.
2. Run `bash verify.sh` from the sandbox copy — every check must pass
   (or report N/A) before the diff is surfaced.
3. Surface the diff for explicit `APPROVE` / `DEFER` / `REJECT`.
4. On `APPROVE`, write to the working tree; log to
   `research/sessions/<session-id>.json`; append a
   `session_type: "SELF-AUDIT"` entry to `research/.engine-stats.json`.

For judgment-required findings (Checks 2, 3, 5, 7, 8), print a one-line
recommendation per finding and exit without drafting any mutation. Sample
recommendations: `references/foo.md:42 — broken URL; replace manually`,
`references/bar.md — unchanged 8mo while source advanced 73 commits; run
/skill-engine:refresh`, `cross-reference map: billing → identity — verify
routing manually`, `references/foo-bar.md — 12.5% paragraph→permalink
coverage (below 80% threshold); add SHA-pinned permalinks to the uncovered
paragraphs listed above`, `grounded_rate 40.0% (below 80% threshold) — review
the per-prompt failure markers; remediate by tightening the Claims policy block,
expanding inline permalinks in references (Check 7), or revising the prompt corpus`.

Check 6 (review-state staleness) is auto-fixable and follows the same
`y` / `n` / `select` prompt — `M` counts include Check 6 findings. The
single mutation rewrites `research/review-state.json` so
`review_state: "stale"`; other fields stay as-is.

When all findings are judgment-required (M == 0), skip the prompt and print
only the recommendation list.
