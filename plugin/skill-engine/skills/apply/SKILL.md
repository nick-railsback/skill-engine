---
name: apply
description: When the user wants to promote a pending DISCOVER or REFRESH proposal from `<name>-context.proposed/` to the live contextualizer at `<name>-context/`. Runs only after `/skill-engine:review <name>` has surfaced the diff and the user has ticked exactly one Step 3 sign-off box (other than `reject`).
---

# Apply

Promote a reviewed proposal into the live contextualizer. Atomic-rename per file. Preserve the `REVIEW.md` audit trail in the live tree. Refuse to run when the proposal has not been signed off, when the sign-off is `reject`, or when more than one Step 3 box is ticked.

## When to invoke

After `/skill-engine:review <name>` has run, the user has filled Step 1 of `REVIEW.md`, re-run `review` to populate Step 2, ticked verdict boxes on each disagreement (optional — for the engine's own read; the engine does not consume these), and ticked exactly one Step 3 box (`reviewed` or `provisional`).

## Resolving `<name>` and `<install>`

Same resolution as `/skill-engine:review`: `<name>` is the slug without the `-context` suffix; bare invocation works when exactly one `*-context.proposed/` exists under `<install>`. See `review/SKILL.md` § Resolving `<name>` for the full rule.

## Pre-promotion gates

Run these in order. Any failure halts the apply and exits non-zero without mutating either tree.

1. **Manifest exists and parses.** `<install>/<name>-context.proposed/.review/manifest.json` must exist and parse as JSON with the schema documented in `discover/SKILL.md` § Output contract. If absent or unparseable, surface a one-line diagnostic and exit.

2. **`REVIEW.md` exists and parses.** `<install>/<name>-context.proposed/.review/REVIEW.md` must exist. Read the Step 3 section.

3. **Exactly one Step 3 box is ticked.** Count occurrences of `- [x]` and `- [X]` (case-insensitive) on the three Step 3 lines (`reviewed`, `provisional`, `reject`). Zero or two-plus ticks halts the apply with:

   ```
   Sign-off state is ambiguous (<K> boxes ticked in Step 3). Edit REVIEW.md so exactly one box is ticked, then re-run /skill-engine:apply <name>.
   ```

4. **The ticked box is not `reject`.** When the single ticked box is `reject`, halt with:

   ```
   Sign-off state is 'reject'. Run /skill-engine:discard <name> to throw away the proposed dir, or edit REVIEW.md and tick 'reviewed' or 'provisional' to promote.
   ```

   Exit non-zero. `apply` never promotes a rejected proposal.

## Promotion

When the gates pass, promote the proposed tree to the live tree file by file. The unit of promotion is one entry from the manifest.

1. **Create the live root if missing.** First-run apply (the live `<name>-context/` does not exist yet) creates `<install>/<name>-context/` and any subdirectories the manifest entries imply (`research/`, `references/`, `.review/`).

2. **For each manifest entry**, dispatch by `status`:

   | Status | Action |
   |---|---|
   | `added` | `mv <proposed>/<path> <live>/<path>` (create parent directories as needed). |
   | `modified` | `mv <proposed>/<path> <live>/<path>` (overwrites the live file). |
   | `removed` | `rm -f <live>/<path>` (the proposed tree does not contain this file; the manifest is the only record). |
   | `unchanged` | No-op. The file was not copied into the proposed tree (copy-on-write); the live file stays as-is. |

   Each `mv` is atomic on a single filesystem. The overall apply is not transactional across files — a failure mid-promotion leaves both trees in a mixed state. This is intentional and acceptable: the manifest is the audit trail, and a partial failure can be diagnosed by comparing what landed against what the manifest declared. Do not attempt to roll back; surface the failure with the path that errored and exit.

3. **Move `REVIEW.md` to the live `.review/` directory.** After all manifest entries are processed:

   ```bash
   mkdir -p "$live/.review"
   mv "$proposed/.review/REVIEW.md" "$live/.review/REVIEW.md"
   mv "$proposed/.review/manifest.json" "$live/.review/manifest.json"
   ```

   The audit trail (the full filled-in `REVIEW.md` plus the manifest that drove this promotion) is preserved in the live tree.

4. **Remove the empty proposed directory.** After the audit trail moves, the proposed tree should contain no remaining files — every `added`/`modified` was moved out, `removed` files were never staged, `unchanged` files were never copied in, and `.review/` is now empty. Run `rmdir`-style removal that errors on non-empty (do not `rm -rf` the proposed tree blindly — a non-empty proposed dir after promotion signals a manifest/filesystem disagreement the maintainer should see). On failure, surface the leftover paths and exit non-zero.

## Exit message

On successful promotion:

```
Applied <name>-context.proposed/ → <name>-context/.
<A> added, <M> modified, <K> removed, <U> unchanged.
Audit trail (REVIEW.md + manifest.json) preserved at <install>/<name>-context/.review/. Commit or .gitignore at your discretion.
```

## What this skill does NOT do

- It does not run `verify.sh` post-promotion. The proposed tree's `verify.sh` already passed before DISCOVER or REFRESH wrote its manifest (per `discover/SKILL.md` § Staging directory), so the live tree inherits that property by file move. A separate post-apply verify is redundant work.
- It does not `git add` or `git commit` the live tree. The user decides what to commit and when. The engine's "no git mutations" doctrine binds (`_bmad-output/epics.md` § "Locked project decisions" #1).
- It does not auto-promote on sign-off. The user runs `apply` explicitly; sign-off in `REVIEW.md` is necessary but not sufficient.
- It does not preserve a backup of the pre-apply live tree. If a `modified` overwrites a file the user wishes they had kept, recovery is via `git` (whatever the user's repo history holds) — not via the engine.
