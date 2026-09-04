# Proposal edge cases, reference formatting, and the post-run summary

The two named companion-proposal edge cases, the Markdown and citation-density conventions for emitted references, and the full post-run summary and merged-tree verification procedure.

**Named exception: different-language ports.** Same-domain,
different-language ports (e.g., a JS port of a Python project) are
candidates — do not skip them. Surface them in **Proposed
companions** with `recommend: reject` and the following rationale,
verbatim: "Different-language port — typically belongs in its own
contextualizer because the navigator's `description` field drives
invocation; if mixed in, queries about the ported language fire the
wrong skill. Recommend rejecting unless your navigator serves
polyglot authors." The user makes the call.

**Docs repos and higher-level packages layered on the core are not
language ports.** Propose them by default. Their content is distinct
signal from the source code — docs repos carry tutorial and concept
scaffolding; layered packages carry their own API surface — and the
user is the right one to decide whether they warrant a reference.

**Named terminal outcome: minimal essence.** A registered, correctly
covered source that legitimately warrants zero — or fewer than three —
references is a valid terminal outcome of a run, not a failure to
propose. Some sources are small, single-purpose, or already exhausted
by the navigator's own prose; forcing catalog rows out of them dilutes
the catalog. This outcome is distinct from Skip-reasoning, which stays
reserved for clear non-fits: a minimal-essence source is in domain and
covered — there is simply little of it. State the outcome in the
Coverage report using the justification shape defined in § Post-run
summary component 1 below; the stamped `verify.sh`'s catalog-density
heuristic WARNs on any ≥20-file source with fewer than 3 catalog rows
and directs the reviewer to exactly that justification.

## Markdown style for emitted references

Reference files emitted by DISCOVER use **soft wrapping**: one paragraph
per line, no hard line breaks at fixed column widths. Editors and
rendered Markdown reflow paragraphs at viewport width. Do not insert
manual line breaks within a prose paragraph to keep lines under ~80
columns — that produces mid-sentence breaks in rendered output, makes
diffs noisier, and is inconsistent with the soft-wrapping convention
used by the example contextualizer at [`examples/modelcontextprotocol-python-sdk-context/`](https://github.com/nick-railsback/skill-engine/tree/main/examples/modelcontextprotocol-python-sdk-context).

Code blocks, tables, bullet lists, and headings follow their own
conventions; this directive applies only to prose paragraphs. The
prose in this SKILL.md file itself is hard-wrapped for legacy reasons
and is NOT the style to imitate — the example contextualizer at
[`examples/modelcontextprotocol-python-sdk-context/SKILL.md`](https://github.com/nick-railsback/skill-engine/blob/main/examples/modelcontextprotocol-python-sdk-context/SKILL.md) is the style to imitate.

## Paragraph→permalink density

Every prose paragraph in an emitted reference must have a SHA-pinned
permalink, in the source forge's grammar, within 5 lines (above, below, or
inside the paragraph) — see [`02-artifact-contract.md`](../../../docs/02-artifact-contract.md#sha-pinned-permalinks-the-canonical-form)
for the five grammars the lint credits. Stable version tags like `v1.2.3`
are accepted equivalently on github.com; unpinned `blob/main/...` URLs do
not satisfy the requirement. SELF-AUDIT Check 7 enforces ≥80%
paragraph→permalink coverage corpus-wide; emit references with
substantially higher per-file coverage so the corpus aggregate has
headroom.

This makes the structural-honesty claim downstream documentation makes —
that any paragraph without a nearby permalink should be treated as
unverified — mechanically true. The cost is one extra source-repo
pointer per paragraph; the alternative is unverifiable curation.

## Post-run summary

Before rendering the summary, finalize the staging directory. The proposed
tree is a sparse copy-on-write — it omits `unchanged` files — so running
`verify.sh` directly against `$CTX_PROPOSED/` would fail presence checks
(Check 1/Check 3 on `source-paths.json` / `SKILL.md`) or N/A-skip the
catalog↔references bijection (Check 4), gating on a partial tree instead of
the real post-apply state. Instead, verify against an **ephemeral merged tree**
that reflects exactly what `apply` would produce, preceded by a collision
guard that aborts before the merge is even built (see below).

Before building the merged tree, check for a **cross-root collision**: does
the candidate `<name>-context` already exist under a *different* install
root than the one this run targets? Reuses `shared/locator-block.md`'s own
root-resolution block verbatim (extracted at run time) rather than
restating its three-root list a second time here — see that file for the
canonical roots and search order. The root this run is writing into is
excluded, so an ordinary same-root update-in-place is never flagged.

```bash
name="$(basename "$CTX_ROOT" | sed 's/-context$//')"
target_root="$(dirname "$CTX_ROOT")"

# Cross-root collision guard: pull just the `ctx_roots=$( ... )` resolution
# block out of shared/locator-block.md (bounded by its own start/end
# markers) and eval it with `name` already set above — this is the same
# three-root find/glob that block runs, reused rather than duplicated, and
# it runs before the merge below so a colliding run aborts without paying
# for an unnecessary mktemp/cp/verify.sh pass.
eval "$(awk '/^ctx_roots=\$\($/{f=1} f{print} f&&/^\)$/{exit}' "$CLAUDE_PLUGIN_ROOT/shared/locator-block.md")"
collision=""
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  [ "$(dirname "$hit")" = "$target_root" ] && continue
  collision="$hit"
done <<< "$ctx_roots"
if [ -n "$collision" ]; then
  echo "Aborting: ${name}-context already exists at $collision, a different install root than $target_root. Duplicate <name>-context navigators across install levels resolve non-deterministically — rename one or remove the other before proceeding." >&2
  exit 1
fi

merged=$(mktemp -d)
cp -R "$CTX_ROOT"/.      "$merged"/   # live baseline
cp -R "$CTX_PROPOSED"/.  "$merged"/   # overlay this run's added/modified (incl. any verify.sh re-stamp)
# Apply the manifest's removals to the merged view so the bijection reflects them:
#   for each entry with status == "removed": rm -f "$merged/<path>"
rm -rf "$merged/.review"              # the audit trail is not part of the audited tree
CTX_ROOT="$merged" "$merged/verify.sh"; rc=$?
# Report-only density lint: computed here for the Coverage report below;
# never gates. rc above (verify.sh's own exit) is the sole abort condition
# for the staging write — density_out is not consulted for it.
density_out=$(python3 "$CLAUDE_PLUGIN_ROOT/tests/permalink_density.py" "$merged/references" 2>&1) || true
rm -rf "$merged"
```

Confirm `verify.sh` exits 0 against the merged tree, then write
`$CTX_PROPOSED/.review/manifest.json` per the schema and stamping
convention documented in § Staging directory. A non-zero `verify.sh`
exit aborts the proposed-dir write with a diagnostic; the user never
sees a `REVIEW.md` for a broken proposal. The density lint above runs in
this same step, in report-only mode: its result is surfaced in the
Coverage report below and never changes whether `verify.sh`'s exit aborts
the write. The merged tree is ephemeral —
`$CTX_PROPOSED/` stays sparse, so `apply`'s "`unchanged` is a no-op" model
and its empty-proposed-tree cleanup (apply § Promotion Step 4) are
unaffected.

At end-of-run, produce a paragraph-form summary for the author with
five components (no multi-column tables, no interactive menus):

1. **Coverage report.** Explicit enumeration of what you covered:
   "I read N files. The codebase's essence is X. I wrote Y references
   covering A, B, C…" or equivalent. Cite sources by `source_id` and
   path; cite content by path+content-hash. If this run populated or
   read from a local clone cache, point at the location once at the end
   of the Coverage report (e.g., `Cached source clones at
   ~/.cache/skill-engine/git-managed/<source_id>-<sha>/; run
   /skill-engine:status to inspect, /skill-engine:clean-cache to free
   disk.`). State the paragraph→permalink density this run computed,
   e.g. `Paragraph→permalink density: 84% (report-only; SELF-AUDIT Check
   7's threshold is 80%).` Parse the percentage out of `$density_out`'s
   `[PASS]`/`[FAIL]` line above.

   When a source legitimately warrants zero — or fewer than three —
   references (the minimal-essence terminal outcome named above), the
   Coverage report is where that is justified. Shape (illustrative):

   ```
   Minimal-essence justification:
     - source: vite-plugin-inspect (source_id: vite-plugin-inspect)
       scale: 214 files at the pinned SHA
       essence: single-purpose dev-tool plugin; its public surface is
       one plugin factory and its options object, fully covered by the
       navigator plus one reference. Fewer than three catalog rows is
       the correct coverage here, not an omission.
   ```

   The stamped `verify.sh`'s catalog-density heuristic WARNs on any
   ≥20-file source carrying fewer than 3 catalog rows and tells the
   reviewer to check the post-run summary for a minimal-essence
   justification — the WARN is working as designed when this shape is
   the answer it finds.
2. **Skip-reasoning.** For files and companion sources you
   considered but excluded: "I deliberately skipped Z because… I
   considered companions P, Q and excluded them because…" Empty-skip
   case allowed — say so explicitly ("Nothing of note was skipped.").
   Reserve this bucket for clear non-fits (off-domain repos, unrelated
   forks, accidental name collisions, archived/abandoned candidates).
   If a candidate is plausibly in-domain, it belongs in **Proposed
   companions** with a rationale — even one that recommends against
   acceptance — not here. See `## Proposal threshold` above.
3. **Proposed companions.** For each companion source surfaced this
   run with `status: "proposed"` in `source-paths.json`, emit one
   line: what was proposed, a one-sentence rationale (mirror or
   summarize `discovered_via`), and the accept path — author edits
   `source-paths.json`, flips `status` to `confirmed` or `rejected`,
   then re-runs `/skill-engine:discover` to crawl accepted sources.
   Empty case allowed — say so explicitly ("No companions surfaced
   this run."). Recommend-against proposals (the canonical case is
   different-language ports per `## Proposal threshold`) belong here
   too — each carries an explicit `recommend: reject` clause in its
   rationale. Note the distinction from Skip-reasoning: any plausibly
   in-domain candidate lives here, even one you'd argue against; only
   clear non-fits go in Skip-reasoning.

   Example shape (illustrative — two entries, accept and reject):

   ```
   Proposed companions:
     - vite-plugin-react (github.com/vitejs/vite-plugin-react)
       recommend: accept
       Same-domain Vite plugin; navigator's description field
       already covers plugin-authoring queries.

     - vite-py (github.com/some-org/vite-py)
       recommend: reject
       Different-language port — typically belongs in its own
       contextualizer because the navigator's `description` field
       drives invocation; if mixed in, queries about the ported
       language fire the wrong skill. Recommend rejecting unless
       your navigator serves polyglot authors.
   ```
4. **Creative-input "rerun with hint" gesture.** End with an
   invitation: `If you'd like me to revise, tell me a hint and rerun:
   /skill-engine:discover --hint='<your hint>'` — for example,
   `--hint='you missed packages/plugin-vue'` or `--hint='include
   docs/guide/ at high priority'`. The `--hint` flag is consumed by
   the next session as additional context.

5. **Staging-dir handoff line** (always last, even for no-op runs).
   Render one line naming the proposed directory and the three
   review/apply/discard commands:

   ```
   Proposal staged at <slug>-context.proposed/. Run /skill-engine:review <slug> to inspect, /skill-engine:apply <slug> to promote, /skill-engine:discard <slug> to throw away.
   ```

   `<slug>` is the contextualizer slug without the `-context` suffix
   (e.g., for `$CTX_ROOT = ~/.claude/skills/vitejs-vite-context/`, the
   slug is `vitejs-vite`).

The summary is paragraph-form; ≤30 lines of text is typical. It is the
author's primary signal that your choices were defensible (coverage +
skip-reasoning) and that a lateral revision is one keystroke away
(creative-input gesture).
