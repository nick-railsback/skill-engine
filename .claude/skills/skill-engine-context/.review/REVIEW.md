# Review — `skill-engine-context.proposed/`

This file lives at `/Users/snailsack/git/skill-engine/.claude/skills/skill-engine-context.proposed/.review/REVIEW.md`. It is the audit trail for a single DISCOVER or REFRESH proposal. The live contextualizer at `/Users/snailsack/git/skill-engine/.claude/skills/skill-engine-context/` is untouched until you run `/skill-engine:apply skill-engine`.

The review is in three steps. Fill Step 1 first, save, then re-run `/skill-engine:review skill-engine` to populate Step 2. Tick exactly one box in Step 3 and save again before `apply` or `discard`.

**What Step 2 will look like.** The guidance for Step 2 lives here, in this intro, rather than inside the section itself: `review`'s second pass rewrites everything between the Step 2 markers, so anything written in there is gone the next time the pass runs. Leave it here.

- **How many disagreements to expect.** The budget is a function of the proposal's counted entries — the manifest entries whose status is `added`, `modified` or `removed`. `unchanged` entries are left out, so the ask follows the size of *this proposal* rather than the size of the contextualizer. Small proposals get a 5–9 window; the window rises by two at each further forty counted entries and stops at a ceiling of 21–25, so the ask stays four wide and never becomes a quota to pad out.
- **When the set arrives grouped.** A proposal touching more than one catalog section of the navigator is written as one sub-heading per section, each carrying that section's counted-entry count and its own ranking, so you can sign off on the part of the corpus you actually own and leave the rest to whoever owns it. A proposal confined to one catalog section stays a single flat ranked list. Entries no catalog row cites are collected under `Unattributed`, which is shown only when the set is already grouped.
- **Two lines that are not disagreements.** The `Paragraph→permalink density:` line and the `Re-emit candidates:` line are report-only figures the pass computes alongside the set. Neither is a disagreement and neither counts against the budget above, so neither can crowd a real disagreement out of the list.

## Step 1 — Predictions (fill these before reading the diff)

Write your predictions before scrolling. The point is to surface your model of what this contextualizer should be, then let the disagreement set in Step 2 show you where the engine's draft diverges from your intent. If you read the diff first, Step 2 has nothing to teach.

- *"This skill is for me, the app owner to use on iterative feature work."*
- *"This skill should NOT lie"*
- *"The reference I'd cut: none, looks good."*

<!-- Do not scroll past this line until the three blanks above are filled. -->

## Step 2 — Disagreement set

Paragraph→permalink density: 99.4% (report-only; not one of the disagreements below).
Re-emit candidates: 9 of 9 references cite changed paths (63 changed paths uncited).
Re-pinned: 204 of 218 citations moved mechanically; 14 read by hand.

- [X] accept  [ ] reject   You predicted this skill is for you, the app owner, on iterative feature work, but the substance of this refresh is fleet mode — `--all` sweeps, a six-column fleet table, an `owner` column — aimed at a platform team running dozens of contextualizers, and it now occupies material in four of the nine references.
- [X] accept  [ ] reject   `workflows.md` gained a federated-review paragraph whose stated premise is "fifty navigators and no one person who can honestly sign off on all of them", documenting a `provisional`-vs-`reviewed` tier distinction that collapses to one person on a single-owner install.
- [X] accept  [ ] reject   `evaluation-and-audit.md` now describes `run-eval.sh --installed-set` and its confusion table, which measure whether a contextualizer stays dormant while its siblings compete for the same query — a 1×1 cell with one contextualizer installed.
- [X] accept  [ ] reject   `artifact-contract.md` gained an `owner` field row seeded from CODEOWNERS, but your `source-paths.json` carries no `owner` key and this refresh did not add one, so the field is documented and unexercised.
- [X] accept  [ ] reject   Against your "should NOT lie" prediction: `invariants.md` now says twelve `verify.sh` named checks (what the validator actually runs) while the doctrine chapter it cites, `05-invariants.md` L32, still says eleven — the reference is correct and disagrees with its own source, and the real fix is upstream rather than in this proposal.
- [X] accept  [ ] reject   Also against that prediction: the navigator's standing instructions measure 7324 bytes against the 5K first-5K budget this corpus documents as load-bearing, and this proposal added 254 of those bytes in the fleet cross-reference line — the artifact teaching the invariant violates it, and no check catches it.
- [X] accept  [ ] reject   `overview.md` and `versioning.md` now assert `0.11.0` as the current version in prose, but the version-parity gate covers `plugin.json`, `marketplace.json`, README, SECURITY and CHANGELOG — not reference prose — so both claims go stale at the next release with nothing naming them.
- [X] accept  [ ] reject   You said you would cut nothing and nothing was cut, but nothing was added either: fleet mode was folded across four existing references rather than emitted as its own, leaving `workflows.md` carrying router, review, apply, discard, status, fleet table and federated review in one file.

## Step 3 — Sign-off

Tick exactly one. `apply` refuses to promote until one box is ticked, and refuses to promote at all when `reject` is the ticked state — use `discard` for that path.

- [X] reviewed
- [ ] provisional
- [ ] reject

---

Audit trail: after `/skill-engine:apply skill-engine`, this file is preserved at `/Users/snailsack/git/skill-engine/.claude/skills/skill-engine-context/.review/REVIEW.md`. Commit it or `.gitignore` it at your discretion — the engine does not decide.
