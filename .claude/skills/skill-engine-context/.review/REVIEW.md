# Review — `skill-engine-context.proposed/`

This file lives at `<install>/skill-engine-context.proposed/.review/REVIEW.md`. It is the audit trail for a single DISCOVER or REFRESH proposal. The live contextualizer at `<install>/skill-engine-context/` is untouched until you run `/skill-engine:apply skill-engine`.

The review is in three steps. Fill Step 1 first, save, then re-run `/skill-engine:review skill-engine` to populate Step 2. Tick exactly one box in Step 3 and save again before `apply` or `discard`.

## Step 1 — Predictions (fill these before reading the diff)

Write your predictions before scrolling. The point is to surface your model of what this contextualizer should be, then let the disagreement set in Step 2 show you where the engine's draft diverges from your intent. If you read the diff first, Step 2 has nothing to teach.

- *"This skill is for me, the app owner."*
- *"This skill should NOT lie."*
- *"The reference I'd cut: none, looks good."*

<!-- Do not scroll past this line until the three blanks above are filled. -->

## Step 2 — Disagreement set

Paragraph→permalink density: 99.4% (report-only; not one of the disagreements below).
Re-emit candidates: 4 of 9 references cite changed paths (19 changed paths uncited).
Re-pinned: 210 of 217 citations moved mechanically; 7 read by hand.

- [ ] accept  [ ] reject   Five of the nine references — `evaluation-and-audit`, `invariants`, `monorepo`, `principles`, `workflows` — had every permalink moved to `89bb5fa` but not one sentence re-read, so the corpus now asserts it is true as of v0.10.1 while those claims were last checked against an older commit; `cited_paths.py` only establishes that no *cited path* moved, which is a file-granularity signal and not a guarantee the prose still holds.
- [ ] accept  [ ] reject   The staged `source-paths.json` keeps `archived: false` and `lifecycle.state: "reachable"` although Phase 0.5 never read the forge's archived flag — `gh api` could not reach api.github.com from this session — so the file carries a fact this run did not verify, resting on a `git ls-remote` that only proves the remote answered.
- [ ] accept  [ ] reject   `artifact-contract.md` is a re-emit candidate whose single citation into a changed file (drift-detection § Phase 0.5, `#L233-L298`) was remapped byte-equal and then left unedited on my judgment that its claim was intact — the one place in this proposal where a wrong call is indistinguishable from a right one, since no check covers it.
- [ ] accept  [ ] reject   Your prediction names the app owner as the reader, but this corpus is agent-facing reference prose — 217 SHA-pinned permalinks at 99.4% paragraph density, shaped to be loaded by a navigator answering a question — and nothing in this proposal moves it toward a human reader, nor should a REFRESH be the thing that does.
- [ ] accept  [ ] reject   `discover-refresh.md`'s inventory-path sentence now carries the `CTX_ROOT` rationale, the invisible-misplaced-copy failure mode and two separate guards inside one soft-wrapped paragraph, which is upstream's own framing but runs well past the sentence length the rest of the corpus keeps.
- [ ] accept  [ ] reject   `versioning.md` now describes two releases in one paragraph — the `0.10.1` head plus the `0.10.0` it follows, each with its own citation — where the live reference described one, so "current head" became a claim the reader has to track across two links rather than read off one.
- [ ] accept  [ ] reject   You would cut nothing, and this proposal cuts and adds nothing, but 6 of the 19 uncited changed paths are `41c4f1d`'s new test surface and `citation_labels.py` is now a shipped gate that no reference in the catalog covers — a gap REFRESH is not allowed to close, so "nothing to cut" is hiding "something to add" that only DISCOVER can act on.

## Step 3 — Sign-off

Tick exactly one. `apply` refuses to promote until one box is ticked, and refuses to promote at all when `reject` is the ticked state — use `discard` for that path.

- [X] reviewed
- [ ] provisional
- [ ] reject

---

Audit trail: after `/skill-engine:apply skill-engine`, this file is preserved at `<install>/skill-engine-context/.review/REVIEW.md`. Commit it or `.gitignore` it at your discretion — the engine does not decide.
