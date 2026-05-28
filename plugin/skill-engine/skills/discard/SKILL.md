---
name: discard
description: Discard a staged proposal without promoting it.
---

# Discard

Remove a proposed staging directory. The live contextualizer is not modified. Idempotent — discarding a non-existent proposed dir exits cleanly with a one-line diagnostic.

## When to invoke

Invoke `/skill-engine:discard <name>` when reviewing a proposal that does not warrant promotion — the predictions in Step 1 of `REVIEW.md` and the disagreement set in Step 2 surface enough divergence that re-running DISCOVER with a `--hint=...` is the right next move, not promotion. `discard` is also the path out when the user ticked `[x] reject` in Step 3: `/skill-engine:apply` refuses to promote a rejected proposal and points the user here.

## Resolving `<name>` and `<install>`

Same resolution as `/skill-engine:review`. See `review/SKILL.md` § Resolving `<name>`.

## Pre-discard prompt

Before removing anything, render a one-line confirmation naming the path:

```
Remove <install>/<name>-context.proposed/ (and its .review/ audit trail)? The live <name>-context/ is untouched. [y/N]
```

Accept `y` or `yes` (case-insensitive, leading/trailing whitespace trimmed) as consent. Treat `N`, blank input, or anything else as decline — the prompt is a single-shot, no re-prompt.

On decline, exit cleanly with:

```
Discard cancelled. <install>/<name>-context.proposed/ is untouched.
```

## The removal

On consent:

```bash
rm -rf "<install>/<name>-context.proposed/"
```

Exit message:

```
Removed <install>/<name>-context.proposed/. Live <name>-context/ is untouched.
```

## Idempotent paths

When the proposed dir does not exist at the resolved path (e.g., a stale invocation after an earlier discard, or a slug typo that resolves nowhere), surface:

```
No proposed staging dir at <install>/<name>-context.proposed/. Nothing to discard.
```

Exit zero (not an error condition — discarding nothing is a no-op).

When bare invocation finds zero `*-context.proposed/` directories under `<install>`, same shape:

```
No proposed staging dirs found under <install>. Nothing to discard.
```

Exit zero.

## What this skill does NOT do

- It does not touch the live contextualizer.
- It does not preserve a backup or move the proposed dir to a trash location — `rm -rf` is the operation. If the user wants to keep the `REVIEW.md` audit trail from a discarded proposal, they should copy it out themselves before invoking `discard`.
- It does not unstage upstream-source clones from `~/.cache/skill-engine/`. The cache is independent of the proposed dir; `/skill-engine:clean-cache` is the cache-management surface.
- It does not require sign-off in `REVIEW.md`. Discarding a proposal is the cheapest path out and should not be gated on the user having gone through the predict-then-compare loop.
