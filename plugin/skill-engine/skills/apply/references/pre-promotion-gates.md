# Pre-promotion gates

The six checks apply runs before mutating either tree, in order, and the exact halt message each produces.

## Pre-promotion gates

Run these in order. Any failure halts the apply and exits non-zero without mutating either tree.

1. **Manifest exists and parses.** `<install>/<name>-context.proposed/.review/manifest.json` must exist and parse as JSON with the schema documented in `discover/SKILL.md` § Output contract. If absent or unparseable, surface a one-line diagnostic and exit.

2. **`REVIEW.md` exists and parses.** `<install>/<name>-context.proposed/.review/REVIEW.md` must exist. Read it in full (Step 1, Step 2, and Step 3).

3. **The review actually ran.** A ticked Step-3 box on its own does not prove the predict-then-compare pass happened — a user can tick `reviewed` on an otherwise-untouched template. Apply must confirm the review loop ran before treating the tick as sign-off. Two literal-content checks, both required:

   - **Step 1 predictions are filled.** Search the three Step-1 prediction lines for the literal substring `___` (the same heuristic `review/SKILL.md` § Second pass uses to decide Step 1 is filled). If any still contains `___`, the user never filled their predictions.
   - **Step 2 was populated.** The unpopulated template carries the literal line `(Run /skill-engine:review <name> again after filling Step 1 to populate this section.)` (the `<name>` is substituted at stamp time). If that placeholder is still present, `review`'s second pass never generated the disagreement set.

   If either check fails, halt without mutating either tree:

   ```
   REVIEW.md is signed off but the review never ran (<reason>). Run /skill-engine:review <name> to fill Step 1 and generate the Step 2 disagreement set, then re-run /skill-engine:apply <name>.
   ```

   where `<reason>` is `Step 1 predictions still contain the ___ blanks` or `Step 2 still holds the unpopulated placeholder`.

4. **Exactly one Step 3 box is ticked.** Count occurrences of `- [x]` and `- [X]` (case-insensitive) on the three Step 3 lines (`reviewed`, `provisional`, `reject`). Zero or two-plus ticks halts the apply with:

   ```
   Sign-off state is ambiguous (<K> boxes ticked in Step 3). Edit REVIEW.md so exactly one box is ticked, then re-run /skill-engine:apply <name>.
   ```

5. **The ticked box is not `reject`.** When the single ticked box is `reject`, halt with:

   ```
   Sign-off state is 'reject'. Run /skill-engine:discard <name> to throw away the proposed dir, or edit REVIEW.md and tick 'reviewed' or 'provisional' to promote.
   ```

   Exit non-zero. `apply` never promotes a rejected proposal.

6. **The live tree has not changed since staging.** The manifest records each entry's `sha_before` — the live file's content-hash at staging time. Anything that wrote to the live tree after DISCOVER/REFRESH staged the proposal (a SELF-AUDIT fix the user approved, a hand edit) makes the proposal stale for that path: promoting would `mv` the stale proposed file over work that landed after staging, silently reverting it. For each manifest entry, compare the live file's current content-hash against the manifest before any `mv`:

   - `modified` — the live hash must equal `sha_before`, **or** equal `sha_after` (that entry was already promoted by a partial prior pass; the resume check in § Promotion skips it).
   - `removed` — the live file must be absent (already removed on a prior pass) or its hash must equal `sha_before`.
   - `added` — the live path must be absent, or match `sha_after` (prior partial pass).
   - `unchanged` — no check; the entry is a no-op and a post-staging edit to it is not at risk.

   Any other state halts without mutating either tree:

   ```
   Live tree changed since this proposal was staged: <path> (live hash != manifest sha_before). Promoting would overwrite work that landed after staging (e.g. a SELF-AUDIT fix or a hand edit). Re-run /skill-engine:discover or /skill-engine:refresh to restage against the current live tree, or /skill-engine:discard <name> to drop the proposal.
   ```
