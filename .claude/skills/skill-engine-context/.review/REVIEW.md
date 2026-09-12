# Review — `skill-engine-context.proposed/`

This file lives at `<install>/skill-engine-context.proposed/.review/REVIEW.md`. It is the audit trail for a single DISCOVER or REFRESH proposal. The live contextualizer at `<install>/skill-engine-context/` is untouched until you run `/skill-engine:apply skill-engine`.

The review is in three steps. Fill Step 1 first, save, then re-run `/skill-engine:review skill-engine` to populate Step 2. Tick exactly one box in Step 3 and save again before `apply` or `discard`.

## Step 1 — Predictions (fill these before reading the diff)

Write your predictions before scrolling. The point is to surface your model of what this contextualizer should be, then let the disagreement set in Step 2 show you where the engine's draft diverges from your intent. If you read the diff first, Step 2 has nothing to teach.

- *"This skill is for me, the app owner"*
- *"This skill should NOT lie"*
- *"The reference I'd cut: none, looks good."*

<!-- Do not scroll past this line until the three blanks above are filled. -->

## Step 2 — Disagreement set

Paragraph→permalink density: 99.4% (report-only; not one of the disagreements below).
Re-emit candidates: 9 of 9 references cite changed paths (43 changed paths uncited).
Re-pinned: 198 of 216 citations moved mechanically; 18 read by hand.

- [ ] accept  [ ] reject   You predicted this skill is for you, the app owner, but the corpus is written for a *consumer* of skill-engine applying it to their own domain — the maintainer-facing surfaces you actually operate (the six version surfaces `/release` moves, `ci-local`'s three-workflow residual, this corpus's own tag-pinning discipline) appear as engine behaviour rather than as your procedure.
- [ ] accept  [ ] reject   This refresh expanded coverage twice rather than only correcting it — three `slice_*` rows added to artifact-contract's field table and a `monorepo-config` row to invariants' check table — on the argument that v0.10.0 made both tables incomplete; if your model is "REFRESH keeps the corpus true, DISCOVER grows it", that boundary was crossed and wants ratifying.
- [ ] accept  [ ] reject   "Should NOT lie" holds claim-by-claim but not by omission: the corpus now documents the slice *fields* and the slice-aware *checks* while carrying no section on how slices actually work, so a reader asking v0.10.0's headline question gets silence — I deferred that section to DISCOVER.
- [ ] accept  [ ] reject   The 14 label/href disagreements this run repaired have no guard behind them, so "not lying" currently means "true as of this apply" rather than "structurally prevented from drifting" — the next range-remapping refresh can reintroduce the same defect silently.
- [ ] accept  [ ] reject   `monorepo.md`'s three rewritten claims are version-stamped in prose ("as of v0.10.0"), which is precise now but opens a fresh staleness surface at every adapter change; stating current behaviour unstamped and letting the pin carry the "as of" would age better.
- [ ] accept  [ ] reject   `versioning.md`'s CHANGELOG paragraph enumerates the 0.10.0 entries by feature, making it the highest-churn sentence in the corpus — guaranteed stale at the next release, where a structural phrasing would not be.
- [ ] accept  [ ] reject   You would cut nothing and nothing was cut — the set stands at 9 — but `evaluation-and-audit.md` and `principles.md` moved on the pin alone with zero prose change, so if you expected this cycle to touch them substantively, it did not.

## Step 3 — Sign-off

Tick exactly one. `apply` refuses to promote until one box is ticked, and refuses to promote at all when `reject` is the ticked state — use `discard` for that path.

- [X] reviewed
- [ ] provisional
- [ ] reject

---

Audit trail: after `/skill-engine:apply skill-engine`, this file is preserved at `<install>/skill-engine-context/.review/REVIEW.md`. Commit it or `.gitignore` it at your discretion — the engine does not decide.
