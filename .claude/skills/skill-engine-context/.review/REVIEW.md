# Review — `skill-engine-context.proposed/`

This file lives at `<install>/skill-engine-context.proposed/.review/REVIEW.md`. It is the audit trail for a single DISCOVER or REFRESH proposal. The live contextualizer at `<install>/skill-engine-context/` is untouched until you run `/skill-engine:apply skill-engine`.

The review is in three steps. Fill Step 1 first, save, then re-run `/skill-engine:review skill-engine` to populate Step 2. Tick exactly one box in Step 3 and save again before `apply` or `discard`.

## Step 1 — Predictions (fill these before reading the diff)

Write your predictions before scrolling. The point is to surface your model of what this contextualizer should be, then let the disagreement set in Step 2 show you where the engine's draft diverges from your intent. If you read the diff first, Step 2 has nothing to teach.

- *"This skill is for the app owner and agents gaining context of the project during feature development"* (carried forward from the 2026-09-09 v0.9.0 review at the maintainer's direction — no new predictions were offered for this re-pin)
- *"This skill should NOT make false claims."* (carried forward)
- *"The reference I'd cut: none, looks good"* (carried forward)

<!-- Do not scroll past this line until the three blanks above are filled. -->

## Step 2 — Disagreement set

Paragraph→permalink density: 99.4% (report-only; not one of the disagreements below).
Re-emit candidates: 5 of 9 references cite changed paths (16 changed paths uncited).

- [X] accept  [ ] reject   Your "for the app owner and agents gaining context during feature development" names a consumer audience, and this proposal changes nothing that audience reads — zero references added or cut, no coverage moved — while rewriting all nine files, so its whole blast radius (215 permalinks, ten files `modified`) is maintenance a reader only notices when a permalink is followed.
- [X] accept  [ ] reject   Your "should NOT make false claims" is why two sentences were deleted rather than rewritten: they said the doctrine chapters "still" described archival as user-set and "still" called this "the four-phase probe", true at the previous pin and false at this one, and the fix is silence plus four citations — a call made on your behalf that the corpus should not narrate the engine's own doc corrections.
- [X] accept  [ ] reject   The `archived` paragraph in `artifact-contract.md` now ends in a four-citation Source list (two skill files, two doctrine chapters) for one behavior, one cycle after you accepted a disagreement that this exact paragraph carried too much engine-maintenance trivia — the trivia is gone, but the citation count went up.
- [X] accept  [ ] reject   `discover-refresh.md` keeps "the half-numbered first phase is the seam where v0.9.0 added archival detection ahead of a probe order that was already fixed" — engine history of the same kind this run removed two sentences later, left in because it explains the 0.5 numbering rather than describing drift, a line you may not draw where I did.
- [X] accept  [ ] reject   The pin advanced to `f772c0d`, an ordinary CI-script commit, rather than to a release commit as the previous refresh deliberately chose; the corpus is true at HEAD today and is re-staled by the next commit to any of its 50 cited paths, and nothing in the references says which commit they describe beyond the SHA inside every URL.
- [X] accept  [ ] reject   46 line ranges shifted and 9 overlapped the doc-correction hunks; the shifted ranges were checked by byte comparison of the cited text and the 9 overlaps by reading old against new, but the visible `L<a>-L<b>` in link text was machine-synced, so the evidence that every citation still points where its sentence claims is structural (215/215 resolve, one SHA) rather than editorial.
- [X] accept  [ ] reject   Zero references added or cut matches "none, looks good" exactly, and the 16 uncited changed paths — the contextualizer's own files, the `/release` command, `ci-local.sh`, one test — stay uncited on the judgment that this corpus should not describe the repo's own CI loop, even though `versioning.md` already describes the doctrine checks CI runs.

## Step 3 — Sign-off

Tick exactly one. `apply` refuses to promote until one box is ticked, and refuses to promote at all when `reject` is the ticked state — use `discard` for that path.

- [X] reviewed
- [ ] provisional
- [ ] reject

---

Audit trail: after `/skill-engine:apply skill-engine`, this file is preserved at `<install>/skill-engine-context/.review/REVIEW.md`. Commit it or `.gitignore` it at your discretion — the engine does not decide.
