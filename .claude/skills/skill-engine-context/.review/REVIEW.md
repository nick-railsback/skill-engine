# Review — `skill-engine-context.proposed/`

This file lives at `<install>/skill-engine-context.proposed/.review/REVIEW.md`. It is the audit trail for a single DISCOVER or REFRESH proposal. The live contextualizer at `<install>/skill-engine-context/` is untouched until you run `/skill-engine:apply skill-engine`.

The review is in three steps. Fill Step 1 first, save, then re-run `/skill-engine:review skill-engine` to populate Step 2. Tick exactly one box in Step 3 and save again before `apply` or `discard`.

This proposal came from REFRESH, not DISCOVER: no reference was added or cut, and no source was added. It re-pins an existing corpus and repairs the claims that the re-pin falsified.

## Step 1 — Predictions (fill these before reading the diff)

Write your predictions before scrolling. The point is to surface your model of what this contextualizer should be, then let the disagreement set in Step 2 show you where the engine's draft diverges from your intent. If you read the diff first, Step 2 has nothing to teach.

- *"The commits I expect to have moved the corpus: those pushed in the last 2 days"*
- *"Claims I expect to have gone stale since the last pin: pins, evals, etc."*
- *"What I expect this refresh to leave alone: core principles"*

<!-- Do not scroll past this line until the three blanks above are filled. -->

## Step 2 — Disagreement set

- [X] accept  [ ] reject   The old pin `016a9d93` was not merely behind — it was **unresolvable**. It was written on the `agentic-eval-hardening` branch, that branch was squash-merged as `ced4535`, and no ref in this repository reaches the commit any more (`pin_state.py`: `object_present=true, ref_reachable=false`). Every one of the 202 citations was pointing at a commit a fresh `actions/checkout` cannot see at all. The new pin `9ba4fae` (v0.6.0, current `main`) classifies `ancestor`, which restores the strict tier of the dogfood oracle's "pin refreshed" check instead of leaving it on its NOTE-and-substitute path.
- [X] accept  [ ] reject   Three prose claims were rewritten because the v0.6.0 release falsified them, not because their line ranges moved: `overview.md` and `versioning.md` both asserted the plugin reads `0.5.0`, and `versioning.md` described the CHANGELOG head as `[0.5.0] - 2026-06-11` with the 0.5.0 bullet list. These are the only edits in this proposal that change meaning rather than a SHA — if you disagree with any, this is the item to reject.
- [X] accept  [ ] reject   The replacement CHANGELOG summary picks four of the twelve `[0.6.0]` bullets (skill-splitting into routers, the `status` provenance probe, the `review` hand-edit detector, `doctrine.sh` 11→29 checks). That selection is a judgment call made to match the previous sentence's length and register; a different four would be equally true.
- [X] accept  [ ] reject   Of the 48 repo paths this corpus cites, only 5 changed between the two pins — `marketplace.json`, `plugin.json`, `README.md`, `SECURITY.md`, `CHANGELOG.md` — and all 5 changed only in their version surfaces. The other 43 are byte-identical, so their references were re-pinned without being re-read. If you believe a doctrine file drifted in substance without its bytes changing, that is what `--hint` is for.
- [X] accept  [ ] reject   `README.md` and `SECURITY.md` are in the drifted set but needed **no** prose edit: their version edits (README L5 and L125, SECURITY L62 and L64) fall outside every line range this corpus actually cites. Worth confirming you agree the corpus should stay silent about a version bump it never quotes.
- [X] accept  [ ] reject   One citation in `discover-refresh.md` L78 uses a single-line anchor (`#L84`, not `#L84-L84`). The repo's own `permalink_scan.py` matches range-form permalinks only, so that citation is invisible to its `single_consistent_sha` and structural checks — it was re-pinned and structurally verified here by a separate scanner-independent pass, but the repo oracle would not have caught it had it been wrong. A blind spot in the test, not in this proposal.

*This is a mechanical re-pin plus three factual corrections. The substantive judgment is concentrated in items 2 and 3; the rest is bookkeeping.*

## Step 3 — Sign-off

Tick exactly one. `apply` refuses to promote until one box is ticked, and refuses to promote at all when `reject` is the ticked state — use `discard` for that path.

- [X] reviewed
- [ ] provisional
- [ ] reject

---

Audit trail: after `/skill-engine:apply skill-engine`, this file is preserved at `<install>/skill-engine-context/.review/REVIEW.md`. Commit it or `.gitignore` it at your discretion — the engine does not decide.
