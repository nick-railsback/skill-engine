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
GitHub permalink within 5 lines (above, below, or inside the paragraph).
The permalink shape is `https://github.com/<owner>/<repo>/blob/<40-hex-sha>/<path>` —
stable version tags like `v1.2.3` are accepted equivalently; unpinned
`blob/main/...` URLs do not satisfy the requirement. SELF-AUDIT Check 7
enforces ≥80% paragraph→permalink coverage corpus-wide; emit references
with substantially higher per-file coverage so the corpus aggregate has
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
that reflects exactly what `apply` would produce:

```bash
merged=$(mktemp -d)
cp -R "$CTX_ROOT"/.      "$merged"/   # live baseline
cp -R "$CTX_PROPOSED"/.  "$merged"/   # overlay this run's added/modified (incl. any verify.sh re-stamp)
# Apply the manifest's removals to the merged view so the bijection reflects them:
#   for each entry with status == "removed": rm -f "$merged/<path>"
rm -rf "$merged/.review"              # the audit trail is not part of the audited tree
CTX_ROOT="$merged" "$merged/verify.sh"; rc=$?
rm -rf "$merged"
```

Confirm `verify.sh` exits 0 against the merged tree, then write
`$CTX_PROPOSED/.review/manifest.json` per the schema and stamping
convention documented in § Staging directory. A non-zero `verify.sh`
exit aborts the proposed-dir write with a diagnostic; the user never
sees a `REVIEW.md` for a broken proposal. The merged tree is ephemeral —
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
   disk.`).
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
