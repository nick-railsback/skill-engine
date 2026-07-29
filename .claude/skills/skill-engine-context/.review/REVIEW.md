# Review — `skill-engine-context.proposed/`

This file lives at `<install>/skill-engine-context.proposed/.review/REVIEW.md`. It is the audit trail for a single DISCOVER or REFRESH proposal. The live contextualizer at `<install>/skill-engine-context/` is untouched until you run `/skill-engine:apply skill-engine`.

The review is in three steps. Fill Step 1 first, save, then re-run `/skill-engine:review skill-engine` to populate Step 2. Tick exactly one box in Step 3 and save again before `apply` or `discard`.

## Step 1 — Predictions (fill these before reading the diff)

Write your predictions before scrolling. The point is to surface your model of what this contextualizer should be, then let the disagreement set in Step 2 show you where the engine's draft diverges from your intent. If you read the diff first, Step 2 has nothing to teach.

- *"This skill is for me the creator to reference the features of the app I've created."*
- *"This skill should NOT lie."*
- *"The reference I'd cut: none, looks good!"*

<!-- Do not scroll past this line until the three blanks above are filled. -->

## Step 2 — Disagreement set

- [ ] accept  [ ] reject   You framed this as a place to "reference the features of the app," but the proposal is pitched at implementer altitude — it documents internal contracts and mechanics in depth (the four invariants, verify.sh's eleven checks with line-ranges, the manifest schema) rather than a lighter feature tour; on-target if you wanted a deep operational reference, a trim if you wanted a feature list.
- [ ] accept  [ ] reject   The web-doc source kind and its `recipes/web-doc-setup` crawl/setup flow get no dedicated reference — they are only summarized inside `artifact-contract` and `discover-refresh` — so a real feature is under-covered if web-doc sources are something you use.
- [ ] accept  [ ] reject   A few claims are pinned to their true home rather than the "obvious" chapter (the three install levels cite `using-skill-engine/SKILL.md`; the untrusted-upstream threat model cites `SECURITY.md`) because the assigned doctrine files did not state them — accurate and honest, but the sourcing is less predictable than a reader might expect.
- [ ] accept  [ ] reject   Every reference is pinned to commit `711e3144` (the cached snapshot, still the current HEAD today), so the corpus will not reflect upstream edits made after that commit until you run `/skill-engine:refresh` — by design, but the "should not lie" guarantee depends on that pin staying fresh.
- [ ] accept  [ ] reject   You said you would cut nothing; for symmetry, note what got no row of its own — `SECURITY.md` and `CHANGELOG.md` were folded into `principles`/`versioning`, and `.github/`, `.semgrep/`, `LICENSE`, and `docs/case-studies|proposals/` were skipped as low-signal — in case any deserves promotion to its own reference.

*This proposal aligns closely with your predictions — the five items above are advisory nuances, not defects; none contradicts "don't lie" and none points to a reference worth cutting.*

## Step 3 — Sign-off

Tick exactly one. `apply` refuses to promote until one box is ticked, and refuses to promote at all when `reject` is the ticked state — use `discard` for that path.

- [X] reviewed
- [ ] provisional
- [ ] reject

---

Audit trail: after `/skill-engine:apply skill-engine`, this file is preserved at `<install>/skill-engine-context/.review/REVIEW.md`. Commit it or `.gitignore` it at your discretion — the engine does not decide.
