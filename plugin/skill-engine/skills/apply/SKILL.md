---
name: apply
description: Promote a reviewed proposal into the live contextualizer.
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

## Promotion

When the gates pass, promote the proposed tree to the live tree file by file. The unit of promotion is one entry from the manifest.

1. **Create the live root if missing.** First-run apply (the live `<name>-context/` does not exist yet) creates `<install>/<name>-context/` and any subdirectories the manifest entries imply (`research/`, `references/`, `.review/`).

2. **For each manifest entry**, dispatch by `status`. Each `added`/`modified`/`removed` entry is processed **resume-safely** (see the idempotency note below) so a retry after a partial failure does not error on work already done:

   | Status | Action |
   |---|---|
   | `added` | If `<proposed>/<path>` is gone but `<live>/<path>` already exists with sha == `sha_after`, this entry was promoted on a prior pass — skip it. Otherwise `mv <proposed>/<path> <live>/<path>` (create parent directories as needed). |
   | `modified` | Same resume check as `added` (already-promoted → skip). Otherwise `mv <proposed>/<path> <live>/<path>` (overwrites the live file). |
   | `removed` | `rm -f <live>/<path>` (already idempotent — a missing target is a no-op; the proposed tree does not contain this file, so the manifest is the only record). |
   | `unchanged` | No-op. The file was not copied into the proposed tree (copy-on-write); the live file stays as-is. |

   Each `mv` is atomic on a single filesystem. The overall apply is not transactional across files — a failure mid-promotion leaves both trees in a mixed state. This is intentional and acceptable: the manifest is the audit trail, and a partial failure can be diagnosed by comparing what landed against what the manifest declared. Do not attempt to roll back.

   **Idempotent retry.** Because each entry begins with the resume check above, re-running `/skill-engine:apply <name>` after a partial failure is safe: entries whose source already moved into a matching live file are skipped, and the apply resumes at the first entry not yet promoted. The retry is a resume, not a fresh replay — it does not error on the already-moved files. (The audit-trail move and proposed-dir removal in Steps 3–4 only run once every entry is resolved, so they are reached only on the pass that completes the promotion.)

   When the failing path is under `.claude/skills/**` and the cause is a rejected write — a permission `deny` or a non-zero / `EPERM` exit under a restricted sandbox — surface the sandbox-block diagnostic per [`04-delivery.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/04-delivery.md) § "When a `.claude/skills/**` write is blocked" rather than a bare path-and-exit: name the exact path, the scoped `sandbox.filesystem.allowWrite` (or remove-`deny`) remedy, the literal failed command (the `mv`/`rm -f`/`mkdir -p` that errored), and the retry (`/skill-engine:apply <name>`). For any other failure, surface the path that errored and exit.

3. **Move `REVIEW.md` to the live `.review/` directory.** After all manifest entries are processed:

   ```bash
   mkdir -p "$live/.review"
   mv "$proposed/.review/REVIEW.md" "$live/.review/REVIEW.md"
   mv "$proposed/.review/manifest.json" "$live/.review/manifest.json"
   ```

   The audit trail (the full filled-in `REVIEW.md` plus the manifest that drove this promotion) is preserved in the live tree.

4. **Remove the empty proposed directory.** After the audit trail moves, the proposed tree should contain no remaining files — every `added`/`modified` was moved out, `removed` files were never staged, and `unchanged` files were never copied in. The audit-trail move in Step 3 emptied `<proposed>/.review/` but left the now-empty directory behind, so remove it first, then the proposed root:

   ```bash
   # Remove every now-empty directory bottom-up (the emptied .review/, plus
   # any references/ or research/ left empty after the mv's), then the root.
   # -delete implies -depth, so children are removed before parents.
   find "$proposed" -mindepth 1 -depth -type d -empty -delete
   rmdir "$proposed"
   ```

   Use `rmdir`-style removal that errors on non-empty (do not `rm -rf` the proposed tree blindly — a non-empty proposed dir after promotion signals a manifest/filesystem disagreement the maintainer should see). The `find … -empty` pass only removes empty directories, so a leftover *file* keeps its parent non-empty and the final `rmdir "$proposed"` then fails — surface the leftover paths and exit non-zero rather than forcing the removal.

## Write review-state.json

After the manifest-driven promotion completes (Step 2 of § Promotion) and **before** the audit-trail move (Step 3), `apply` persists the Step-3 sign-off state to a per-skill ledger at `<live>/research/review-state.json`. The ledger is engine state about the promotion event, not reviewable proposal content — it is written directly to the live tree, never staged through the proposed dir. Sequencing the ledger write before the audit-trail move means a crash mid-flow leaves the user's attestation more durably persisted than the audit trail.

**Schema.** The file has exactly three keys:

```json
{
  "schema_version": 1,
  "review_state": "reviewed",
  "reviewed_at": "2026-05-21T14:32:00Z"
}
```

- `schema_version` — integer, currently `1`.
- `review_state` — one of `"reviewed"`, `"provisional"`, `"stale"`. (`reject` does not appear: a rejected proposal never reaches the live tree.) `schema_version: 1` does not pin the enum closed; future engine versions may add states, and current-version readers treat unknown values as if the ledger were absent.
- `reviewed_at` — ISO-8601 UTC timestamp pinned to regex `^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$` (T-separator required, literal `Z` suffix, no fractional seconds).

**Write.** Compute `review_state` from the single Step-3 box ticked in `REVIEW.md` (already parsed by Pre-promotion gate 4 — either `"reviewed"` or `"provisional"`). Compute `reviewed_at` from `date -u +"%Y-%m-%dT%H:%M:%SZ"`. Write the file as a fresh overwrite, not a merge. Let `$live` denote the live contextualizer root resolved earlier in this flow, and `$review_state` denote the single ticked Step-3 value:

```bash
mkdir -p "$live/research"
reviewed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -n \
  --arg state "$review_state" \
  --arg at "$reviewed_at" \
  '{schema_version: 1, review_state: $state, reviewed_at: $at}' \
  > "$live/research/review-state.json"
```

Re-applying the same proposal twice (the user runs `apply` then immediately re-runs without intervening edits — degenerate but reachable) produces two `reviewed_at` timestamps differing by seconds. This is intentional: `reviewed_at` is the canonical "when did the user last attest" timestamp.

The proposed tree must NOT contain `research/review-state.json` — DISCOVER and REFRESH do not write it into `<proposed>/`, and the manifest does not enumerate it. If a stale `<proposed>/research/review-state.json` is found (left over from a hand-edit or an earlier engine version), silently ignore it; the file written above is computed from the Step-3 tick at promotion time, not copied from the proposed tree.

## Reconcile the provisional preamble

After writing `review-state.json` and still **before** the audit-trail move, `apply` reconciles a `provisional` preamble block in the live `<live>/SKILL.md`. The preamble is the engine's runtime trust signal to the using-agent: when the contextualizer was last promoted in `provisional` mode, a blockquote sits between the frontmatter and the navigator's first H1 warning the using-agent that the review was incomplete. When the contextualizer was promoted in `reviewed` mode, no such block exists.

**Delimiter format (load-bearing).** The preamble is delimited by exact HTML comments on lines of their own:

```
<!-- BEGIN provisional-preamble (managed by skill-engine; do not hand-edit) -->
<!-- END provisional-preamble -->
```

The delimiter strings must be byte-for-byte the literals above. `apply` finds and removes a stale preamble on subsequent runs by matching these exact delimiters; a hand-edit that alters the delimiter format will cause `apply` to fail to remove the preamble cleanly.

**Block body.** Between the delimiters, the preamble carries exactly one blockquote line. A single blank line separates the END delimiter from the first H1 line below it:

```markdown
<!-- BEGIN provisional-preamble (managed by skill-engine; do not hand-edit) -->
> **Heads up:** This contextualizer was last reviewed in *provisional* mode — the maintainer ran `/skill-engine:apply` to promote it but flagged the review as incomplete. Treat its claims as plausible but unverified; verify load-bearing claims by following the nearest permalink. Re-run `/skill-engine:refresh` and re-apply with `reviewed` to clear this notice.
<!-- END provisional-preamble -->

# <whatever the navigator's first H1 actually says>
```

**Position.** The block sits immediately after the closing `---` of the navigator frontmatter and immediately before the **first H1** in the body (the first line matching the regex `^# `, regardless of its body text). Real stamped navigators carry varied H1 text — `# Library Context Navigator`, `# Context navigator (multi-source)`, `# LangChain context navigator`, `# skill-engine context navigator` — so the insertion logic MUST match on `^# `, not on the contract doc's template wording.

**Four reconciliation cases.** On every successful promotion, after the live SKILL.md is in place, `apply` reads the file once and dispatches:

| Ticked Step-3 state | Preamble present? | Action |
|---|---|---|
| `provisional` | no | Insert the preamble block immediately before the first `^# ` line. |
| `provisional` | yes | No-op (idempotent). |
| `reviewed` | yes | Remove the entire span from `<!-- BEGIN provisional-preamble … -->` through `<!-- END provisional-preamble -->` inclusive, plus the single trailing blank line that was inserted with the block. |
| `reviewed` | no | No-op. |

**Implementation note.** The four cases are detected by grepping for the literal BEGIN delimiter; the insertion and removal use `awk` (or `sed` with care) against the literal delimiter strings — do not regex-match the blockquote body itself, since the body is engine-managed and matching it would defeat the engine-managed property.

Reconciliation against `review-state.json` and against the SKILL.md preamble runs every time `apply` promotes, regardless of the prior live state. The preamble's presence (or absence) in SKILL.md is the runtime signal; the ledger's `review_state` value is the persisted attestation. The two stay in sync because `apply` is the sole writer of both.

After the ledger write and preamble reconciliation complete, control returns to § Promotion Step 3 (the audit-trail move) and Step 4 (proposed-dir removal).

## Exit message

On successful promotion:

```
Applied <name>-context.proposed/ → <name>-context/.
<A> added, <M> modified, <K> removed, <U> unchanged.
Sign-off persisted as <review_state> at <install>/<name>-context/research/review-state.json.
Audit trail (REVIEW.md + manifest.json) preserved at <install>/<name>-context/.review/. Commit or .gitignore at your discretion.
```

## What this skill does NOT do

- It does not run `verify.sh` post-promotion. The proposed tree's `verify.sh` already passed before DISCOVER or REFRESH wrote its manifest (per `discover/SKILL.md` § Staging directory), so the live tree inherits that property by file move. A separate post-apply verify is redundant work.
- It does not write `review-state.json` to the proposed tree. The ledger is engine state about the promotion event, not part of the reviewable proposal — DISCOVER and REFRESH must not stage it, and the manifest must not enumerate it.
- It does not `git add` or `git commit` the live tree. The user decides what to commit and when. The engine's "no git mutations" doctrine binds (see [`05-invariants.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/05-invariants.md) on git mutations, enforced by doctrine.sh check 4).
- It does not auto-promote on sign-off. The user runs `apply` explicitly; sign-off in `REVIEW.md` is necessary but not sufficient.
- It does not preserve a backup of the pre-apply live tree. If a `modified` overwrites a file the user wishes they had kept, recovery is via `git` (whatever the user's repo history holds) — not via the engine.
