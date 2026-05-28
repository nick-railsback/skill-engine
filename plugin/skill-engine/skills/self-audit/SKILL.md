---
name: self-audit
description: Audit a contextualizer for drift (read-only).
---

# Self-audit

Run the eight drift checks against the contextualizer's current state: stale
date, broken URL, long-untouched reference, catalog-vs-content disagreement,
cross-reference-vs-content disagreement, review-state staleness,
paragraph→permalink density, grounded-citation rate. Read-only by default; after the findings table
prints, offers an opt-in propose → validate → approve gate for the three
deterministic checks (stale dates, catalog-row drift, review-state
staleness). The other five checks remain advisory — they print a one-line
recommendation each and the human acts manually.

## Contextualizer root

Engine workflows operate inside a contextualizer installed as a project
skill at one of three install levels:

- **User-level:** `~/.claude/skills/<slug>-context/`
- **Local-user-level:** `~/.claude/local/skills/<slug>-context/` (when in use)
- **Project-level:** `<repo>/.claude/skills/<slug>-context/`

Every path below — `research/...`, `references/...`, `verify.sh` —
resolves relative to whichever directory matches. Before reading
anything, locate the root by searching all three install levels in
order:

```bash
ctx_roots=$(
  for root in "$HOME/.claude/skills" "$HOME/.claude/local/skills" "$PWD/.claude/skills"; do
    [ -d "$root" ] || continue
    find "$root" -mindepth 1 -maxdepth 1 -type d -name '*-context' 2>/dev/null
  done
)
n=$(printf '%s\n' "$ctx_roots" | grep -c .)
if [ "$n" -eq 0 ]; then
  echo "No contextualizer found under any of ~/.claude/skills/, ~/.claude/local/skills/, or .claude/skills/. Run /skill-engine:engine-bootstrap first."
  exit 1
elif [ "$n" -gt 1 ]; then
  echo "Multiple contextualizers found; specify one:"
  printf '%s\n' "$ctx_roots"
  exit 1
fi
CTX_ROOT="$ctx_roots"
```

Read every subsequent `research/foo` path as `$CTX_ROOT/research/foo`,
every `references/foo` as `$CTX_ROOT/references/foo`, and `verify.sh` as
`$CTX_ROOT/verify.sh`.

## Doctrine surface

The complete SELF-AUDIT protocol — what the eight drift checks do, what they
emit, how the reviewer acts on findings — lives in chapter [`03-engine.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/03-engine.md)
under `## SELF-AUDIT (drift audit)` and the `## Workflow: SELF-AUDIT` section
of [`maintenance-agent.md.template`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/engine-bootstrap-templates/maintenance-agent.md.template).

## Cadence

Every two to four weeks. Pair with `discover` on the same day for a quarterly
rhythm.

## Invariants

SELF-AUDIT is **read-only by default**. It surfaces findings and exits unless
the human explicitly opts in to applying the deterministic fixes among them
(see "Optional fix flow" below). Two HARD-GATEs remain in force at all times:
no write without explicit human approval, and pre-approval validation must
pass via `worker-verify`. Neither gate has an override.

When no human-approval gesture occurs (default path), the audit does not
auto-rewrite catalog rows, does not fetch upstream beyond a HEAD probe, and
does not modify `research/.research-state.json`.

Every audit run records an entry per check — no silent skips. `N/A` entries
include the one-line reason the check did not apply (e.g., "all references
mtime today; no comparison window yet" or "no source URLs in scope"). The
output table format is documented in [`03-engine.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/03-engine.md) under SELF-AUDIT
"Output format."

SELF-AUDIT scope is framing drift, not invariant compliance.
Artifact-contract questions (frontmatter rules, file naming, the four
reference invariants) are owned by `verify.sh` and should not be surfaced
as SELF-AUDIT findings even when something looks off. If the auditor
notices a contract-side question while running, it belongs in the
session-reflection's `## Template ambiguities` block, not the findings
list.

## Check 6 — review-state staleness

Check 6 surfaces the case where the contextualizer's persisted sign-off
(`research/review-state.json`, written by `/skill-engine:apply`) has aged
out of agreement with the upstream-state record carried in
`research/source-paths.json` per-source `lifecycle.last_checked` fields.
SELF-AUDIT is read-only by default; Check 6 runs the same way and only
proposes a mutation through the existing auto-fix opt-in prompt.

**Staleness heuristic.** A contextualizer's `review_state` is auto-flipped
to `"stale"` when either of the following holds:

- **Ledger present and outdated.** `research/review-state.json` exists with
  `review_state ∈ {"reviewed", "provisional"}` AND **any** in-scope
  `git-managed` source in `research/source-paths.json` has
  `lifecycle.last_checked > reviewed_at` AND `lifecycle.last_checked_sha`
  is non-null. The semantics: REFRESH only writes `last_checked` (and only
  writes `last_checked_sha`) when it successfully probed upstream; a
  `last_checked` newer than `reviewed_at` therefore signals "REFRESH
  observed upstream after the user attested" — strictly stronger than
  "time has passed." Per-source granularity is OR-reduced: any one source
  qualifying flips the whole skill to stale.
- **Ledger absent on a legacy skill.** When `research/review-state.json`
  does not exist AND the skill carries at least one in-scope `git-managed`
  source with a non-null `lifecycle.last_checked_sha`, the skill predates
  the review-state ledger and is treated as stale on the first SELF-AUDIT run that
  surfaces it. Fresh-bootstrap skills with no `last_checked_sha` yet (no
  DISCOVER/REFRESH has probed) are N/A, not stale.

SELF-AUDIT does not differentiate per-source staleness in the finding — it
surfaces the skill as one unit. The maintainer's options after a staleness
finding are (a) run REFRESH to bring the references in line with current
SHAs, then `apply` with `reviewed`, or (b) hand-edit `review-state.json`
to bump `reviewed_at` and attest that the user reviewed the implicit diff.

**Output format.** Check 6 emits a `[WARN]` line in the existing
SELF-AUDIT output format:

```
[WARN] review-state-stale: reviewed_at 2026-04-02T14:00:00Z; source <id>'s last_checked is 2026-05-15T09:31:00Z (sha def5678). Run REFRESH + apply or accept the staleness flag.
```

When no in-scope `git-managed` source carries a `last_checked_sha` (fresh
bootstrap, pre-DISCOVER), Check 6 emits one N/A entry with the standard
one-line reason: `[N/A] review-state-stale: no in-scope git-managed source has been probed yet.`

**Auto-fix class.** Check 6 is auto-fixable in the Check-1/Check-4 sense:
there is a single deterministic mutation — rewrite
`research/review-state.json` so `review_state: "stale"`, leaving
`reviewed_at` and `schema_version` unchanged. Wire it into the auto-fix
opt-in prompt alongside Checks 1 and 4.

**Idempotency (load-bearing).** The flip is one-way and self-limiting:
the "Ledger present and outdated" condition above fires *only while*
`review_state ∈ {"reviewed", "provisional"}`, so once the auto-fix writes
`"stale"` that condition no longer holds — Check 6 neither re-flags nor
re-emits the `[WARN]` on subsequent runs. `review_state == "stale"` is
itself the idempotency marker; no separate "already flagged" field is
needed. `reviewed_at` is deliberately **not** advanced by the auto-fix:
bumping it would erase the original attestation timestamp and falsely
imply a fresh review. The flag clears only when the maintainer re-attests
— a full REFRESH + `apply` (which writes a new `reviewed_at`), or a
deliberate hand-edit of `reviewed_at` — never by repeated audits. Do not
"fix" the preserved `reviewed_at` into a bump: that would re-introduce a
re-firing loop the instant `review_state` were ever reset to `reviewed`.

**Bypass of the staging gate.** The Check-6 mutation is NOT routed through
the `<slug>-context.proposed/` staging gate. SELF-AUDIT's existing
fix flow writes directly to the working tree via its sandbox-validate
→ APPROVE path, and `review-state.json` mutations follow that same
pattern. The rationale: a stale flag is engine state about the skill's
review status, not skill content; routing it through `.proposed/` +
`REVIEW.md` would invert the trust signal (the engine asking the user to
predict whether their own ledger should say stale).

## Check 7 — paragraph→permalink density

Check 7 measures structural-honesty density on the references corpus:
the fraction of prose paragraphs that carry a SHA-pinned (or stable-tag-
pinned) GitHub permalink within 5 lines. The check is scoped to
`$CTX_ROOT/references/**/*.md` only — the navigator (`$CTX_ROOT/SKILL.md`)
is a router and is intentionally out of scope, the same way the `verify.sh`
SHA-pin invariant carves out navigator prose. Companion files under
`references/` participate on equal footing with primaries. GitHub-permalink
density is a git-source metric; web-doc / multi-source verifiability is
out of scope for this gate. The methodology — what the metric measures,
what it deliberately does not measure, and the live numbers across the
bundled `examples/` — is documented in [chapter 13](../../docs/13-coverage-testing.md).

**Threshold.** ≥80% corpus-wide coverage required to PASS. The threshold
was sourced from the AI-1 measurement that motivated the check: 46.9%
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
- *Permalink:* a URL matching the canonical SHA-pinned shape
  `https://github.com/<owner>/<repo>/(blob|tree)/<40-hex-sha>/<path>`,
  or a stable-tag-pinned URL of shape
  `https://github.com/<owner>/<repo>/(blob|tree)/v<X>[.<Y>[.<Z>]]/<path>`.
  Unpinned `blob/main/...` URLs and non-GitHub URLs do not satisfy the
  density check.
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

## Check 8 — grounded-citation rate

Check 8 measures behavioral structural-honesty on the answering side:
for each `needs_reference` prompt in `$CTX_ROOT/research/eval-prompts.json`,
did the answering model both (a) open ≥1 reference via the
`read_reference` tool AND (b) include a SHA-pinned (or stable-tag-pinned)
GitHub permalink in its final response text? The check is the empirical
counterpart to Check 7's corpus-side density: Check 7 asks whether the
references *contain* permalinks near load-bearing prose; Check 8 asks
whether the model *emits* one when it answers. The grader runs keyless
and deterministically — verified against 17/17 mocked cases with no
API calls; the live rate is per-contextualizer and downstream. See [chapter 13](../../docs/13-coverage-testing.md)
for the methodology, mocked-vs-live distinction, and the live-run recipe
for a forker supplying their own `eval-prompts.json`.

**Opt-in.** Check 8 makes paid Anthropic API calls (~$0.01–$0.05 per run,
sometimes more for long prompt corpora or many references). Unlike Checks
1–7 — bash-local and free — Check 8 only runs when the maintainer sets
the `SKILL_ENGINE_RUN_EVAL` environment variable. The opt-in is per
invocation; there is no setting to default it on. When the opt-in is
absent, Check 8 emits an `[N/A]` row noting how to enable it — there is
no silent skip.

**Threshold.** ≥80% by default; override via the runner's `--threshold`
flag. Symmetric with Check 7's density threshold; same reviewability
rationale — below 80% means more than one prompt in five fails to honor
the structural-honesty policy from the navigator's Claims policy block.

**What counts as a permalink.** The same canonical SHA-pinned and
stable-tag-pinned GitHub URL shapes Check 7 uses. The two checks import
the regex from a single module so the permalink contract has one source
of truth.

**N/A behavior.** When `eval-prompts.json` is absent or carries 0
prompts, Check 8 emits `[N/A]` and exits 0 without calling the API.
Contextualizers with no eval corpus pay nothing. An absent or zero-prompt
corpus is a clean, terminal N/A — a check that does not apply, not a
finding — so the auditor records the status line and stops there, without
recommending that anyone author a corpus or otherwise framing the absence
as outstanding work. Authoring an eval corpus is the maintainer's
discretionary curation, never something SELF-AUDIT requests; a corpus that
is present but scores below threshold is the only Check 8 state that earns
a remediation line. When the file exists but its schema is invalid (e.g.,
missing `prompts` key, missing required prompt fields), Check 8 emits
`[FAIL]` rather than silently skipping — a malformed corpus would
otherwise look identical to "no corpus."

**Dependency.** Check 8 requires the `anthropic` Python SDK
(and `httpx`, which `anthropic` pulls in). The engine ships no Python
dependency manifest and intentionally does not pin the SDK: Check 8 is
opt-in dev tooling that runs against whatever current `anthropic` the
user already has, so the install line floats by design (the version-pin
lint's documented carve-out — see `.semgrep/README.md`
§ `skill-content-unpinned-pip-install`). Install once per workstation:
`pip install anthropic` <!-- nosemgrep: skill-content-unpinned-pip-install -->
On `ImportError`, Check 8 exits 3 (distinct from FAIL exit 1 and
runner-failure exit 2) and prints an install hint.

**Tool-surface caveat.** Check 8 uses a custom `read_reference` tool
(the AI-4 harness shape), not the generic `Read` tool real Claude Code
agents see. The choice gives a cleaner signal on citation behavior given
the agent has chosen to open, at the cost of not measuring over-opening
on doesn't-need prompts. Comparing scores across a future tool-surface
change would be invalid — re-baseline rather than compare.

**No auto-fix.** Check 8 is judgment-required, not auto-fixable. A low
`grounded_rate` is remediated by curating the references corpus
(Check 7's surface), revising the navigator's Claims policy block, or
deciding the prompt corpus is unrepresentative — none of which the
engine can mutate mechanically.

**Output format.** Single-line header for PASS / N/A / FAIL (column
aligned with Check 7 — two spaces after `[N/A]`):

```
[PASS] grounded-rate: 80.0% (4/5 prompts grounded) ≥80% threshold (cost: $0.04)
[N/A]  grounded-rate: no eval prompts defined (research/eval-prompts.json absent)
[N/A]  grounded-rate: eval-prompts.json has 0 prompts
[N/A]  grounded-rate: opt-in required (set SKILL_ENGINE_RUN_EVAL=1 to include the citation-rate eval; ~$0.01–$0.05 per run)
[FAIL] grounded-rate: 40.0% (2/5 prompts grounded) below 80% threshold (cost: $0.05)
[FAIL] grounded-rate: eval-prompts.json schema invalid — missing 'prompts' key
```

On FAIL, the header is followed by one indented line per non-grounded
prompt naming the prompt id, the first failure marker
(`no-reference-opened`, `no-permalink-in-response`,
`tool-turn-cap-exceeded`, `per-prompt-timeout`, `api-error`), and a
60-char prefix of the prompt text:

```
  n02 [no-reference-opened]:  List the parameters of MCPServer.run() and their de
  n04 [no-permalink-in-response]:  What happens when an elicitation request time
```

**How it runs.** SELF-AUDIT checks the opt-in env var first; on opt-in,
invokes the bundled Python runner:

```bash
if [ -n "${SKILL_ENGINE_RUN_EVAL:-}" ]; then
  # --threshold omitted: inherits DEFAULT_THRESHOLD (sourced from
  # permalink_density.DEFAULT_COVERAGE_THRESHOLD — one bar for Checks 7 and 8).
  python3 "$CLAUDE_PLUGIN_ROOT/tests/grounded_rate.py" "$CTX_ROOT"
else
  echo "[N/A]  grounded-rate: opt-in required (set SKILL_ENGINE_RUN_EVAL=1 to include the citation-rate eval; ~\$0.01–\$0.05 per run)"
fi
```

The runner writes its findings to stdout and exits 0 (PASS or N/A), 1
(FAIL or schema invalid), 2 (runner failure — every prompt errored), or
3 (ImportError on `anthropic`). SELF-AUDIT reads the exit code and rolls
the result into its findings table as a Check 8 row.

## Optional fix flow

After the findings table, when total findings > 0, classify each finding as
auto-fixable (Checks 1, 4, and 6) or judgment-required (Checks 2, 3, 5, 7, 8).
The three auto-fixable checks have a single correct mutation:

- **Check 1 (stale `as of` dates):** refresh the date to today's UTC date.
- **Check 4 (catalog row vs frontmatter `description`):** sync the catalog
  row's one-line description to the reference frontmatter's `description:`
  field (the canonical statement).
- **Check 6 (review-state staleness):** rewrite
  `research/review-state.json` so `review_state: "stale"` (other fields
  unchanged).

When at least one auto-fixable finding exists, prompt the human (with `K = N − M`, the count of judgment-required findings):

```
Found N findings — M auto-fixable, K need judgment.

Apply auto-fixable findings now?
  y       Draft fixes for all M; show diff for APPROVE / DEFER / REJECT
  n       Exit with findings only (default)
  select  Choose which auto-fixable findings to draft
```

Empty input is `n`. On `y` or `select`, follow the REFRESH propose →
validate → approve gate documented in [`03-engine.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/03-engine.md) §"Optional fix flow":

1. Draft the edits on the sandbox copy at `/tmp/skill-engine-validate-<session-id>/`.
2. Run `worker-verify` against the sandbox (four pre-approval checks).
3. Surface the diff for explicit `APPROVE` / `DEFER` / `REJECT`.
4. On `APPROVE`, write to the working tree; log to
   `research/sessions/<session-id>.json`; append a
   `session_type: "SELF-AUDIT"` entry to `research/.engine-stats.json`.

For judgment-required findings (Checks 2, 3, 5, 7, 8), print a one-line
recommendation per finding and exit without drafting any mutation. Sample
recommendations: `references/foo.md:42 — broken URL; replace manually`,
`references/bar.md — unchanged 8mo while source advanced 73 commits; run
/skill-engine:refresh`, `cross-reference map: billing → identity — verify
routing manually`, `references/foo-bar.md — 12.5% paragraph→permalink
coverage (below 80% threshold); add SHA-pinned permalinks to the uncovered
paragraphs listed above`, `grounded_rate 40.0% (below 80% threshold) — review
the per-prompt failure markers; remediate by tightening the Claims policy block,
expanding inline permalinks in references (Check 7), or revising the prompt corpus`.

Check 6 (review-state staleness) is auto-fixable and follows the same
`y` / `n` / `select` prompt — `M` counts include Check 6 findings. The
single mutation rewrites `research/review-state.json` so
`review_state: "stale"`; other fields stay as-is.

When all findings are judgment-required (M == 0), skip the prompt and print
only the recommendation list.
