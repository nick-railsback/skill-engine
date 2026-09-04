# Check 7 — paragraph→permalink density

What the density metric measures, its threshold and aggregation rule, and its exact output format.

## Check 7 — paragraph→permalink density

Check 7 measures structural-honesty density on the references corpus:
the fraction of prose paragraphs that carry a SHA-pinned (or stable-tag-
pinned) permalink, in the source forge's grammar, within 5 lines. The
check is scoped to `$CTX_ROOT/references/**/*.md` only — the navigator
(`$CTX_ROOT/SKILL.md`) is a router and is intentionally out of scope, the
same way the `verify.sh` SHA-pin invariant carves out navigator prose.
Companion files under `references/` participate on equal footing with
primaries. Density is a git-source metric, derived from the
contextualizer's registered sources; web-doc / multi-source verifiability
is out of scope for this gate. The methodology — what the metric
measures, what it deliberately does not measure, and the live numbers
across the bundled `examples/` — is documented in
[chapter 13](../../../docs/13-coverage-testing.md).

**Threshold.** ≥80% corpus-wide coverage required to PASS. The threshold
was sourced from the measurement that motivated the check: 46.9%
corpus-wide coverage across the MCP contextualizer's references, with a
7%–87% by-file range. 80% leaves a ≤20% remainder that is reviewable in a
single read and makes the structural-honesty disclaimer — *"where a
paragraph lacks a nearby permalink, treat the claim as unverified"* —
mechanically true, not aspirational.

**What counts.**

- *Prose paragraph:* a maximal run of consecutive non-blank lines that
  is not a heading, fenced code block, table row/separator, bullet or
  numbered list item (including indented continuations), blockquote,
  HTML comment, or leading frontmatter block.
- *Permalink:* a SHA-pinned (or, on github.com, stable-tag-pinned) URL
  in the source forge's grammar — see the five grammars enumerated in
  [`02-artifact-contract.md`](../../../docs/02-artifact-contract.md#sha-pinned-permalinks-the-canonical-form).
- *Within ≤5 lines:* at least one in-scope permalink appears in any line
  in the range `[paragraph_start - 5, paragraph_end + 5]` in the same
  file. Above, below, or inside the paragraph all count.

**Aggregation.** The threshold is corpus-wide: total covered paragraphs
divided by total in-scope paragraphs across all `references/**/*.md`
files. Per-file numbers are computed and surfaced for diagnostic purposes
only — the corpus-wide aggregate is the pass/fail gate.

**N/A cases.** Check 7 emits `[N/A]` and exits 0 when the references
directory is absent or empty (fresh bootstrap, no DISCOVER emission yet),
or when the corpus contains fewer than 5 total in-scope paragraphs (the
ratio is not meaningful below that floor).

**Output format.** Single-line header for PASS / N/A / FAIL:

```
[PASS] permalink-density: corpus coverage 87.3% (268/307 paragraphs) ≥80% threshold
[N/A]  permalink-density: no references emitted yet
[N/A]  permalink-density: only 3 paragraphs in scope (need ≥5 for a meaningful ratio)
[FAIL] permalink-density: corpus coverage 64.2% (197/307 paragraphs) below 80% threshold
```

On FAIL, the header is followed by one indented line per reference file
with sub-80% per-file coverage (sorted ascending by per-file coverage),
and one further-indented line per uncovered paragraph naming its start
line and a 60-character prefix of its first line:

```
  references/foo-bar.md: 12.5% (1/8 paragraphs covered)
    L23:  This widget integrates with the upstream subsystem to provide
    L47:  Refunds follow a state machine — initiated, pending, settled
```

**How it runs.** Check 7 invokes the bundled Python lint. `--threshold` is
omitted so the bar comes from the single source of truth
(`DEFAULT_COVERAGE_THRESHOLD` in `permalink_density.py`); pass it explicitly
only to override:

```bash
python3 "$CLAUDE_PLUGIN_ROOT/tests/permalink_density.py" \
  "$CTX_ROOT/references"
```

The lint writes its findings to stdout in the format above and exits 0
(PASS / N/A) or 1 (FAIL). SELF-AUDIT reads the exit code + stdout and
rolls the result into its findings table as a Check 7 row.

**No auto-fix.** Check 7 is judgment-required, not auto-fixable. There
is no mechanical mutation that adds a meaningful permalink to a
paragraph — the right citation depends on what the paragraph asserts,
and the act of citing IS the curation work the contextualizer author
does. Surfacing the offending paragraphs is the entire fix prompt; the
author follows the recommendations file-by-file and re-runs SELF-AUDIT
until coverage clears the threshold.
