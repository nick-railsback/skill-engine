---
name: review
description: Review a staged proposal and sign off before applying it.
---

# Review

A pending proposal lives at `<install>/<name>-context.proposed/`. This skill inspects that staging directory without mutating either it or the live contextualizer at `<install>/<name>-context/`. The user's review is what teaches the engine what "good" means for this source — `review` is the surface that loads the question, not a rubber stamp on a pre-committed artifact.

## When to invoke

Invoke `/skill-engine:review <name>` after DISCOVER or REFRESH has surfaced a "Proposal staged at `<name>-context.proposed/`" line in its post-run summary. The skill runs in two passes against the same proposal: the first pass prints the manifest, the configured diff command, and the path to `REVIEW.md`; the second pass (after the user fills Step 1 of `REVIEW.md`) re-reads the file, generates the Step 2 disagreement set, and rewrites that section in place.

## Resolving `<name>`

The `<name>` argument is the contextualizer slug *without* the `-context` suffix. `/skill-engine:review vitejs-vite` operates on `<install>/vitejs-vite-context.proposed/`.

Bare invocation (no argument) works when exactly one `*-context.proposed/` directory exists under `<install>`. When zero match, surface `no proposed staging dir found under <install>` and exit cleanly. When two or more match, surface the list and ask which one (mirrors `discover/SKILL.md`'s "Multiple contextualizers" pattern).

Resolve `<install>` from the live contextualizer location. The proposed directory always sits as a sibling of the live `<name>-context/` directory; `<install>` is whichever level the live skill is installed at (`~/.claude/skills/`, `~/.claude/local/skills/`, or `<repo>/.claude/skills/`). Iterate the same three roots `using-skill-engine`'s router walks (see the "Locating the contextualizer root" block in `discover/SKILL.md`); the first match wins.

## First pass — manifest and diff command

When `REVIEW.md` exists but Step 1 still contains the literal `___` blanks (i.e., the user has not yet filled their predictions), do the following in order:

1. **Read the manifest.** Parse `<install>/<name>-context.proposed/.review/manifest.json`. The schema is documented in `discover/SKILL.md` § Output contract; the relevant fields here are `entries[].path` and `entries[].status` (`added` / `modified` / `removed` / `unchanged`).

2. **Print the summary.** Render one paragraph per status bucket. Group `added`, `modified`, and `removed` entries by status; omit `unchanged` from the print (it is recorded in the manifest for `apply` to consume but is not interesting to a reviewer). One line per file, prefixed with the status verb:

   ```
   Added (N):
     - <path>
   Modified (M):
     - <path>
   Removed (K):
     - <path>
   ```

   Empty buckets are omitted, not surfaced as "Added (0):".

3. **Print the diff command.** Read the configured `diff.tool` value from `$CLAUDE_PLUGIN_DATA/config.json` (the same plugin-data tree the `SessionStart` hook already uses for `state/current.json`). If the file is absent, or the key is absent, or `$CLAUDE_PLUGIN_DATA` is unset, fall back to the default: `git diff --no-index --color`.

   Print one line naming the command and the two paths to diff:

   ```
   To inspect the diff, run:
     <diff-command> <install>/<name>-context/ <install>/<name>-context.proposed/
   ```

   For first-run proposals where the live `<name>-context/` does not yet exist, substitute `/dev/null` for the live path so `git diff --no-index` still produces a meaningful one-sided diff.

4. **Open `REVIEW.md` or print its path.** The primary caller of this skill is a non-interactive Claude agent session in which `$EDITOR` is unset; the print-path branch is what fires in practice. Print the absolute path plus a one-line instruction:

   ```
   Open <install>/<name>-context.proposed/.review/REVIEW.md in your editor, fill Step 1, save, then re-run /skill-engine:review <name>.
   ```

   The secondary `$EDITOR`-set branch is a convenience for a human running the command directly in a terminal: when `$EDITOR` is set, spawn `$EDITOR <path-to-REVIEW.md>` and wait. Either branch leaves the user at the same edit-loop: fill Step 1, save, re-run.

## Second pass — populate Step 2

When `REVIEW.md` exists and the three Step-1 lines no longer contain the literal `___` substring (heuristic: search each of the three prediction lines for the substring `___`; if all three are absent, Step 1 is filled), do the following:

1. **Re-read `REVIEW.md`** and the proposed tree.

2. **Compute 5–9 disagreements** between the user's predictions and the proposed contextualizer's coverage. Rank by magnitude:
   - **Scope-mismatch disagreements** rank highest: the prediction's "for ___" or "NOT ___" boundary differs from the navigator's actual coverage (e.g., user says "this skill is for the runtime API only" but the proposal includes plugin-authoring references).
   - **Content-style disagreements** rank next: prose voice, reference partition shape, depth-of-detail choices.
   - **Reference-count disagreements** rank lowest: number of references emitted, whether a borderline candidate became its own reference or got folded.

3. **Write 5–9 disagreements** between the existing Step 2 section markers, leaving Steps 1 and 3 byte-for-byte unchanged. Each disagreement is one sentence with verdict checkboxes:

   ```
   - [ ] accept  [ ] reject   <one-sentence disagreement>
   ```

   If fewer than 5 disagreements exist (a tightly-aligned proposal), surface what there is and add a trailing italic line: *"Only <N> disagreement<s?> surfaced — this proposal aligns closely with your predictions."* If more than 9 exist, take the top 9 by magnitude and add a trailing italic line: *"<K> additional disagreement<s?> not shown."*

4. **Save the file** with Steps 1 and 3 preserved exactly as the user left them. Do not auto-tick any verdict box; the user does that.

5. **Print a one-line confirmation** naming the file path and the disagreement count.

## Edge cases

- **Manifest missing.** A proposed directory that lacks `.review/manifest.json` is incomplete — DISCOVER or REFRESH did not finish. Surface a diagnostic naming the proposed dir, suggest `/skill-engine:discard <name>` to remove the half-written staging tree, then exit non-zero.

- **`REVIEW.md` missing but manifest present.** Stamp the `REVIEW.md.template` body (with `<name>` substituted) into `<install>/<name>-context.proposed/.review/REVIEW.md`, then continue with the first pass. This makes the skill self-healing for proposed dirs whose template stamp was interrupted.

- **Step 1 filled but Step 2 already populated.** The user has filled their predictions, the engine has populated Step 2, and the user is invoking `review` again. Treat this as "user wants a refresh of Step 2" — recompute the disagreement set against the current proposed tree (which may have advanced if a REFRESH ran in between) and rewrite Step 2 in place.

- **Step 3 already ticked.** The user has signed off but is re-running `review` to inspect the manifest or diff before `apply`. Do not regenerate Step 2; just run the first-pass manifest/diff print.

## What this skill does NOT do

- It does not promote the proposed dir to the live tree. That is `/skill-engine:apply`'s job.
- It does not remove the proposed dir. That is `/skill-engine:discard`'s job.
- It does not invoke `git diff` itself; it prints the command for the user to run. The user's diff tool may not be `git` at all — `delta`, `kdiff3`, or any other configured command is the user's choice.
- It does not validate the diff output for content correctness; the disagreement set in Step 2 is the engine's read, not a lint.
- It does not auto-tick Step 3. Sign-off is an explicit user gesture.
