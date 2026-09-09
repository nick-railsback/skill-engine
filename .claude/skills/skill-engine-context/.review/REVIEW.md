# Review — `skill-engine-context.proposed/`

This file lives at `<install>/skill-engine-context.proposed/.review/REVIEW.md`. It is the audit trail for a single DISCOVER or REFRESH proposal. The live contextualizer at `<install>/skill-engine-context/` is untouched until you run `/skill-engine:apply skill-engine`.

The review is in three steps. Fill Step 1 first, save, then re-run `/skill-engine:review skill-engine` to populate Step 2. Tick exactly one box in Step 3 and save again before `apply` or `discard`.

## Step 1 — Predictions (fill these before reading the diff)

Write your predictions before scrolling. The point is to surface your model of what this contextualizer should be, then let the disagreement set in Step 2 show you where the engine's draft diverges from your intent. If you read the diff first, Step 2 has nothing to teach.

- *"This skill is for the app owver and agents gaining context of the project during feature development"*
- *"This skill should NOT make false claims."*
- *"The reference I'd cut: none, looks good"*

<!-- Do not scroll past this line until the three blanks above are filled. -->

## Step 2 — Disagreement set

Paragraph→permalink density: 99.4% (report-only; not one of the disagreements below).
Re-emit candidates: 9 of 9 references cite changed paths (50 changed paths uncited).

- [X] accept  [ ] reject   Your "should NOT make false claims" bar is the one this run could not meet cleanly: v0.9.0 ships four doctrine files that contradict its own behavior (`02-artifact-contract.md:191` and `08-discover-pipeline.md:244` still say the engine never auto-detects archival; `refresh/SKILL.md:81` and `drift-detection-and-phases.md:3` still say "four-phase probe"), so the corpus can be true about the engine or agree with its own cited sources, but not both — this run chose true-about-the-engine and names the lag in the prose, which is a judgment made on your behalf rather than one you asked for.
- [X] accept  [ ] reject   "For the app owner and agents gaining context during feature development" frames a consumer audience, but the `archived` paragraph now spends three clauses on which doctrine chapters are stale — engine-maintenance trivia that helps you and actively wastes an agent that only wanted to know whether archival is automatic.
- [X] accept  [ ] reject   The two field rows this run added to `artifact-contract.md` (`probe_budget`, `importance`) document budgeting that exists to make a tens-of-sources registry affordable; your contextualizer registers one source, so that row pair is coverage for an install you do not have — the same single-repo-audience mismatch the last review raised about `forge` and `workspace_roots`.
- [X] accept  [ ] reject   The harvest named seven false or stale sentences; this run fixed ten, adding `discover-refresh.md:94`, `monorepo.md:30`, and `invariants.md:42` on its own initiative — every one of them a false claim, so they serve prediction 2, but they are discretion exercised past the brief you wrote.
- [X] accept  [ ] reject   `monorepo.md`'s Check 6 paragraph grew from one sentence to four to carry the absolute-path restriction *and* the `./docs/` failure it prevents, so an orientation file now contains a bug postmortem — the same density complaint the last review filed against this exact paragraph, one cycle later and worse.
- [X] accept  [ ] reject   `workflows.md`'s `engine-bootstrap` section went from one paragraph to three because five new flags had to be named, making intake the longest-treated workflow in a reference read mostly by someone about to run `refresh`.
- [X] accept  [ ] reject   Twenty-two citations had a visible line range in their link text that disagreed with the range in the URL, and this run silently re-synced all of them — nineteen were already wrong in the live corpus before this refresh, so that is a correctness fix you neither requested nor rejected, made invisible by being folded into a re-pin.
- [X] accept  [ ] reject   Zero references added or cut, matching "none, looks good" exactly, but all nine were rewritten and 205 permalinks re-pinned, so the blast radius is the whole corpus while the evidence that nothing broke is mechanical rather than editorial: `verify.sh` 11/0, density flat at 99.4%, and 215/215 permalinks resolving in-bounds at `b075dae`.

## Step 3 — Sign-off

Tick exactly one. `apply` refuses to promote until one box is ticked, and refuses to promote at all when `reject` is the ticked state — use `discard` for that path.

- [X] reviewed
- [ ] provisional
- [ ] reject

---

Audit trail: after `/skill-engine:apply skill-engine`, this file is preserved at `<install>/skill-engine-context/.review/REVIEW.md`. Commit it or `.gitignore` it at your discretion — the engine does not decide.
