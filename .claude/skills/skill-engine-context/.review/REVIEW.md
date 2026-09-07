# Review — `skill-engine-context.proposed/`

This file lives at `<install>/skill-engine-context.proposed/.review/REVIEW.md`. It is the audit trail for a single DISCOVER or REFRESH proposal. The live contextualizer at `<install>/skill-engine-context/` is untouched until you run `/skill-engine:apply skill-engine`.

The review is in three steps. Fill Step 1 first, save, then re-run `/skill-engine:review skill-engine` to populate Step 2. Tick exactly one box in Step 3 and save again before `apply` or `discard`.

## Step 1 — Predictions (fill these before reading the diff)

Write your predictions before scrolling. The point is to surface your model of what this contextualizer should be, then let the disagreement set in Step 2 show you where the engine's draft diverges from your intent. If you read the diff first, Step 2 has nothing to teach.

- *"This skill is for me, the app owner."*
- *"This skill should NOT misinterpret the app  "*
- *"The reference I'd cut: none - looks good."*

<!-- Do not scroll past this line until the three blanks above are filled. -->

## Step 2 — Disagreement set

Paragraph→permalink density: 99.4% (report-only; not one of the disagreements below).
Re-emit candidates: 9 of 9 references cite changed paths (31 changed paths uncited).

- [ ] accept  [ ] reject   Your "for me, the app owner" frames a single-repo audience, but this run added three source-entry field rows (`forge`, `files_of_interest`, `workspace_roots`) and a sparse-clone/nine-workspace-roots paragraph describing configuration your one registered source does not use — coverage aimed at someone pointing the engine at other people's monorepos, not at you pointing it at this one.
- [ ] accept  [ ] reject   "Should NOT misinterpret the app" is most at risk where the pack now asserts a version: it says the engine ships at `0.8.0`, true of `main` at `e8561a9` but not of the plugin actually installed on this machine, which is `0.6.0` — so the pack describes an engine two minors newer than the one your `/skill-engine:*` commands are running.
- [ ] accept  [ ] reject   `artifact-contract.md` still states that `.discover-cache.json` and other dot-prefixed `research/*.json` files are gitignored runtime state, which is the engine's doctrine faithfully reported but false of this install — no such ignore rule exists here, and this run's own `.discover-inventory.json` is now untracked inside a tracked contextualizer.
- [ ] accept  [ ] reject   The run went past a pure re-pin in two places the harvest did not ask for — a § REFRESH paragraph on the re-emit candidate set and three rows in the field table — and while your "cut nothing" prediction licenses no deletions and there are none, it does not speak to additions, which is where this run exercised discretion.
- [ ] accept  [ ] reject   The Check 6 rewrite in `monorepo.md` turned one sentence into four (cache-tree resolution, hex-suffix matching, nine roots, `[N/A]` on an absent sparse root), leaving that paragraph denser than its neighbors — accurate, but it reads like reference documentation where the rest of the file reads like orientation.
- [ ] accept  [ ] reject   `discover-refresh.md`'s cache-lifecycle sentence now carries two `Source:` links, the only double-cited sentence in that file, because the original GC claim was mis-attributed to `09-discover-config.md`, which never documented GC at all — the alternative was splitting one sentence into two.
- [ ] accept  [ ] reject   Zero references added or cut, matching "none — looks good" exactly, but all 9 were rewritten and 202 permalinks re-pinned, so the blast radius is the whole corpus and the evidence that nothing broke is mechanical rather than editorial: `verify.sh` 11/0, density 99.4% flat against baseline, and all 204 links validated in-bounds at `e8561a9`.

## Step 3 — Sign-off

Tick exactly one. `apply` refuses to promote until one box is ticked, and refuses to promote at all when `reject` is the ticked state — use `discard` for that path.

- [X] reviewed
- [ ] provisional
- [ ] reject

---

Audit trail: after `/skill-engine:apply skill-engine`, this file is preserved at `<install>/skill-engine-context/.review/REVIEW.md`. Commit it or `.gitignore` it at your discretion — the engine does not decide.
