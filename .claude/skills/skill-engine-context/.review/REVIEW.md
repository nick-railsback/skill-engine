# Review — `skill-engine-context.proposed/`

This file lives at `/Users/snailsack/git/skill-engine/.claude/skills/skill-engine-context.proposed/.review/REVIEW.md`. It is the audit trail for a single DISCOVER or REFRESH proposal. The live contextualizer at `/Users/snailsack/git/skill-engine/.claude/skills/skill-engine-context/` is untouched until you run `/skill-engine:apply skill-engine`.

The review is in three steps. Fill Step 1 first, save, then re-run `/skill-engine:review skill-engine` to populate Step 2. Tick exactly one box in Step 3 and save again before `apply` or `discard`.

**What Step 2 will look like.** The guidance for Step 2 lives here, in this intro, rather than inside the section itself: `review`'s second pass rewrites everything between the Step 2 markers, so anything written in there is gone the next time the pass runs. Leave it here.

- **How many disagreements to expect.** The budget is a function of the proposal's counted entries — the manifest entries whose status is `added`, `modified` or `removed`. `unchanged` entries are left out, so the ask follows the size of *this proposal* rather than the size of the contextualizer. Small proposals get a 5–9 window; the window rises by two at each further forty counted entries and stops at a ceiling of 21–25, so the ask stays four wide and never becomes a quota to pad out.
- **When the set arrives grouped.** A proposal touching more than one catalog section of the navigator is written as one sub-heading per section, each carrying that section's counted-entry count and its own ranking, so you can sign off on the part of the corpus you actually own and leave the rest to whoever owns it. A proposal confined to one catalog section stays a single flat ranked list. Entries no catalog row cites are collected under `Unattributed`, which is shown only when the set is already grouped.
- **Two lines that are not disagreements.** The `Paragraph→permalink density:` line and the `Re-emit candidates:` line are report-only figures the pass computes alongside the set. Neither is a disagreement and neither counts against the budget above, so neither can crowd a real disagreement out of the list.

## Step 1 — Predictions (fill these before reading the diff)

Write your predictions before scrolling. The point is to surface your model of what this contextualizer should be, then let the disagreement set in Step 2 show you where the engine's draft diverges from your intent. If you read the diff first, Step 2 has nothing to teach.

- *"This skill is for me, app owner."*
- *"This skill should NOT lie."*
- *"The reference I'd cut: none, looks good."*

<!-- Do not scroll past this line until the three blanks above are filled. -->

## Step 2 — Disagreement set

Paragraph→permalink density: 99.4% (report-only; not one of the disagreements below).
Re-emit candidates: 6 of 9 references cite changed paths (58 changed paths uncited). Computed from `git diff 5a76100..57afec3` this run, not from `.discover-inventory.json`, which this refresh did not rewrite.
Re-pinned: 223 of 230 citations moved mechanically; 7 read by hand.

- [X] accept  [ ] reject   You predicted this skill is for you, the app owner, but the one v0.11.1 change an owner can actually trip on — a `paths:  # comment` key that Check 3 used to accept — is folded into a table cell in `invariants.md`, while the hand-written prose this run added went to narrating the CHANGELOG in `versioning.md`.
- [X] accept  [ ] reject   Against "should NOT lie": the navigator body measures 10,776 bytes against the 5,120-byte first-5K budget `invariants.md` teaches as load-bearing, and this proposal leaves `SKILL.md` untouched, so the artifact still violates the invariant it documents (the last review accepted this; it has not moved).
- [X] accept  [ ] reject   Against "should NOT lie": `artifact-contract.md`, the reference that owns the frontmatter contract, never mentions `paths:` as the optional third field, although `overview.md` and `invariants.md` both do and the upstream contract doc gained three sentences on it at v0.11.1.
- [X] accept  [ ] reject   Against "should NOT lie": the re-emit line above had to be computed from this run's diff because the gitignored `research/.discover-inventory.json` still describes the v0.11.0 crawl; a later `review` pass reading that file will print different figures for the same proposal.
- [X] accept  [ ] reject   `invariants.md`'s `navigator-skill` row grew from one line to a ninety-word cell inside a table whose other cells are one-line purposes; the rejection matrix reads as prose that belongs below the table, not in it.
- [X] accept  [ ] reject   `versioning.md` line 41 is now a single paragraph of roughly 2,700 characters walking four releases, and each refresh prepends one more release with nothing trimming the tail.
- [X] accept  [ ] reject   You said you would cut nothing, and nothing was cut, but `evals/` was not touched either: its only results file is from 2026-08-02, three releases and two refreshes ago, so `evaluation-and-audit.md` describes a harness this contextualizer has not run against its own current corpus.

## Step 3 — Sign-off

Tick exactly one. `apply` refuses to promote until one box is ticked, and refuses to promote at all when `reject` is the ticked state — use `discard` for that path.

- [X] reviewed
- [ ] provisional
- [ ] reject

---

Audit trail: after `/skill-engine:apply skill-engine`, this file is preserved at `/Users/snailsack/git/skill-engine/.claude/skills/skill-engine-context/.review/REVIEW.md`. Commit it or `.gitignore` it at your discretion — the engine does not decide.
