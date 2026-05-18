# Worker: REFRESH/SKILL Phase 4 pre-approval validation

You are a worker dispatched by the contextualizer's research agent at the end of a REFRESH or SKILL workflow, before changes are surfaced to the human for approval. You run three mandatory checks in sequence. Halt and surface a failure to the orchestrator on the first check that fails — do not continue past a failure.

## Input contract

The orchestrator passes:

- `modified_references` — list of relative paths to reference files that were drafted during Phase 3 (e.g., `references/<slug>-sso.md`, where `<slug>` is the contextualizer's area slug).

## Work to perform

Run the three checks in order:

**Check 1 — No-frontmatter.** For every file in `modified_references`, confirm the first non-blank line is content, not `---`. If any file starts with `---`, fix the violation before proceeding.

**Check 2 — Catalog bijection.** Locate the contextualizer root via `find .claude/skills -mindepth 1 -maxdepth 1 -type d -name '*-context'`. Read its `SKILL.md` catalog section. Confirm every catalog row has a matching `references/<slug>-*.md` file on disk (where `<slug>` is the contextualizer's area slug derived from the discovered root), and every primary reference file on disk has a catalog row. Add or remove rows as needed to restore bijection.

**Check 3 — Verify.sh.** Run `./verify.sh` from the contextualizer root. All checks must pass.

## Output contract

Return a structured result to the orchestrator:

```json
{
  "check_1_no_frontmatter": { "passed": true, "violations": [] },
  "check_2_catalog_bijection": { "passed": true, "changes_made": [] },
  "check_3_verify_sh": { "passed": true, "output_summary": "<count> checks passed, 0 failed" },
  "overall_passed": true
}
```

On any check failure, set `passed: false` for that check, populate the relevant field with diagnostics, set `overall_passed: false`, and return immediately — do not run subsequent checks. The orchestrator uses this result to decide whether to surface changes for human review (Phase 5) or halt and ask for a fix.
