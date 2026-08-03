---
name: apply
description: Use when a staged proposal has been reviewed and signed off — REVIEW.md Step 3 ticked reviewed or provisional — and is ready to promote into the live contextualizer.
---

# Apply

Promote a reviewed proposal into the live contextualizer. Atomic-rename per file. Preserve the `REVIEW.md` audit trail in the live tree. Refuse to run when the proposal has not been signed off, when the sign-off is `reject`, or when more than one Step 3 box is ticked.

## When to invoke

After `/skill-engine:review <name>` has run, the user has filled Step 1 of `REVIEW.md`, re-run `review` to populate Step 2, ticked verdict boxes on each disagreement (optional — for the engine's own read; the engine does not consume these), and ticked exactly one Step 3 box (`reviewed` or `provisional`).

## Resolving `<name>` and `<install>`

Same resolution as `/skill-engine:review`: `<name>` is the slug without the `-context` suffix; bare invocation works when exactly one `*-context.proposed/` exists under `<install>`. See `review/SKILL.md` § Resolving `<name>` for the full rule.

## Pre-promotion gates

Run these in order; any failure halts the apply and exits non-zero without
mutating either tree: the manifest exists and parses, `REVIEW.md` exists
and parses, the review loop actually ran (not just a ticked box — two
literal-content checks against Step 1/Step 2), exactly one Step 3 box is
ticked and it isn't `reject`, and the live tree hasn't changed since
staging (per-entry content-hash comparison against the manifest's
`sha_before`/`sha_after`). The exact checks, halt messages, and per-status
hash rules are in
[`references/pre-promotion-gates.md`](references/pre-promotion-gates.md).

## Promotion, review-state and preamble reconciliation

Promote file-by-file from the manifest (resume-safe per entry), then —
before moving the audit trail — write `research/review-state.json` (the
persisted sign-off ledger) and reconcile the `provisional`-mode preamble
block in the live `SKILL.md`, then move `REVIEW.md` + `manifest.json` into
the live `.review/` and remove the emptied proposed directory. The
per-status promotion rules, the ledger schema, and the preamble's exact
delimiter format and four reconciliation cases are in
[`references/promotion-and-reconciliation.md`](references/promotion-and-reconciliation.md).

## Exit message

On successful promotion:

```
Applied <name>-context.proposed/ → <name>-context/.
<A> added, <M> modified, <K> removed, <U> unchanged.
Sign-off persisted as <review_state> at <install>/<name>-context/research/review-state.json.
Audit trail (REVIEW.md + manifest.json) preserved at <install>/<name>-context/.review/. Commit or .gitignore at your discretion.
```

## What this skill does NOT do

- It does not run `verify.sh` post-promotion. The proposed tree's `verify.sh` already passed before DISCOVER or REFRESH wrote its manifest (per `discover/SKILL.md` § Staging directory), so the live tree inherits that property by file move. A separate post-apply verify is redundant work.
- It does not write `review-state.json` to the proposed tree. The ledger is engine state about the promotion event, not part of the reviewable proposal — DISCOVER and REFRESH must not stage it, and the manifest must not enumerate it.
- It does not `git add` or `git commit` the live tree. The user decides what to commit and when. The engine's "no git mutations" doctrine binds (see [`05-invariants.md`](../../docs/05-invariants.md) on git mutations, enforced by doctrine.sh check 4).
- It does not auto-promote on sign-off. The user runs `apply` explicitly; sign-off in `REVIEW.md` is necessary but not sufficient.
- It does not preserve a backup of the pre-apply live tree. If a `modified` overwrites a file the user wishes they had kept, recovery is via `git` (whatever the user's repo history holds) — not via the engine.
