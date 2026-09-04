# Review — `skill-engine-context.proposed/`

This file lives at `<install>/skill-engine-context.proposed/.review/REVIEW.md`. It is the audit trail for a single DISCOVER or REFRESH proposal. The live contextualizer at `<install>/skill-engine-context/` is untouched until you run `/skill-engine:apply skill-engine`.

The review is in three steps. Fill Step 1 first, save, then re-run `/skill-engine:review skill-engine` to populate Step 2. Tick exactly one box in Step 3 and save again before `apply` or `discard`.

## Step 1 — Predictions (fill these before reading the diff)

Write your predictions before scrolling. The point is to surface your model of what this contextualizer should be, then let the disagreement set in Step 2 show you where the engine's draft diverges from your intent. If you read the diff first, Step 2 has nothing to teach.

- *"This skill is for citing the source forge's own SHA-pinned grammar, not github.com's."*
- *"This skill should NOT restate the five-grammar enumeration outside the artifact contract."*
- *"The reference I'd cut: none — this is a re-pin, not a coverage change."*

<!-- Do not scroll past this line until the three blanks above are filled. -->

## Step 2 — Disagreement set

- [X] accept  [ ] reject   This is a re-pin forced by chunk 02 of the forge-agnostic-trust feature editing 7 files this corpus cites (`02-artifact-contract.md`, `03-engine.md`, `08-discover-pipeline.md`, `13-coverage-testing.md`, `proposal-and-post-run.md`, `self-audit/SKILL.md`, `check-7-permalink-density.md`), pinned at `9ba4fae` → `f9e5b36`. No new source, no cut reference, no coverage change beyond what re-pinning naturally shifts (99.4%, up from the pre-refresh baseline).
- [X] accept  [ ] reject   39 permalink citations across the 6 affected references; 31 remapped mechanically (identical cited content, sha + line-range swap only, verified by locating the exact quoted block at the new commit) and 8 got real prose rewrites because the content they cited changed meaning — not just moved.
- [X] accept  [ ] reject   Two of the 8 rewrites are the specific inversions chunk 01's retro flagged forward: `invariants.md` no longer says "non-GitHub URLs do not count" and `evaluation-and-audit.md` no longer says the lint is "GitHub-source-blind by design" or that Check 8's regex is "imported" from Check 7 (it now says Check 8 builds its grammar from the same resolver Check 7 uses — the accurate post-chunk-01 relationship).
- [X] accept  [ ] reject   The other 6 rewrites are the same "GitHub permalink" → "permalink in the source forge's grammar" substitution repeated at: the contract's own canonical-form citation (cited twice, from `artifact-contract.md` and `invariants.md`), Check 7's rule + what-counts paragraphs (`invariants.md`), Check 7's and Check 8's definitions (`evaluation-and-audit.md`), and the DISCOVER density paragraph (`discover-refresh.md`).
- [X] accept  [ ] reject   `workflows.md` and `overview.md` are in the modified set but carry zero prose change — pure sha/line-range re-pins on content that didn't move in meaning, only in position or literal sha. Confirmed via a normalized diff that strips citation URLs before comparing.
- [X] accept  [ ] reject   `monorepo.md`, `principles.md`, and `versioning.md` are untouched — none cites any of the 7 files chunk 02 edited.

*Forced re-pin, not a discretionary refresh: the judgment is concentrated in the 8 rewrites, all of which restate a fact this repo's own chunk-review already approved in chunk 02's diff.*

## Step 3 — Sign-off

Tick exactly one. `apply` refuses to promote until one box is ticked, and refuses to promote at all when `reject` is the ticked state — use `discard` for that path.

- [X] reviewed
- [ ] provisional
- [ ] reject

---

Audit trail: after `/skill-engine:apply skill-engine`, this file is preserved at `<install>/skill-engine-context/.review/REVIEW.md`. Commit it or `.gitignore` it at your discretion — the engine does not decide.
