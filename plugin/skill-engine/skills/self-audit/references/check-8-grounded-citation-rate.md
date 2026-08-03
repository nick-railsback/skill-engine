# Check 8 — grounded-citation rate

The opt-in behavioral eval: what it measures, its cost and dependency notes, N/A rules, and exact output format.

## Check 8 — grounded-citation rate

Check 8 measures behavioral structural-honesty on the answering side:
for each `needs_reference` prompt in the corpus under grade — one file
under `$CTX_ROOT/research/`, by default `eval-prompts.json` —
did the answering model both (a) open ≥1 reference via the
`read_reference` tool AND (b) include a SHA-pinned (or stable-tag-pinned)
GitHub permalink in its final response text? The check is the empirical
counterpart to Check 7's corpus-side density: Check 7 asks whether the
references *contain* permalinks near load-bearing prose; Check 8 asks
whether the model *emits* one when it answers. Each prompt is graded from
3 independent runs rather than 1: the per-prompt verdict is a majority
vote over those 3 runs, and a prompt whose 3 runs disagree is reported as
flickering rather than folded silently into the aggregate rate. The
grader runs keyless and deterministically — verified against 18/18 mocked
cases with no API calls; the live rate is per-contextualizer and
downstream. See [chapter 13](../../../docs/13-coverage-testing.md)
for the methodology, mocked-vs-live distinction, the live-run recipe
for a forker supplying their own corpus, and the optional train /
held-out split.

**Opt-in.** Check 8 makes paid Anthropic API calls (~$0.03–$0.15 per run —
3 calls per prompt — sometimes more for long prompt corpora or many
references). Unlike Checks
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

**N/A behavior.** When no corpus is present, or the corpus under grade
carries 0 prompts, Check 8 emits `[N/A]` and exits 0 without calling the API.
Contextualizers with no eval corpus pay nothing. An absent or zero-prompt
corpus is a clean, terminal N/A — a check that does not apply, not a
finding — so the auditor records the status line and stops there, without
recommending that anyone author a corpus or otherwise framing the absence
as outstanding work. Authoring an eval corpus is the maintainer's
discretionary curation, never something SELF-AUDIT requests; a corpus that
is present but scores below threshold is the only Check 8 state that earns
a remediation line. When a corpus exists but its schema is invalid (e.g.,
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

**Tool-surface caveat.** Check 8 uses a custom `read_reference` tool,
not the generic `Read` tool real Claude Code agents see. The choice gives a cleaner signal on citation behavior given
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
[PASS] grounded-rate: 80.0% (4/5 prompts grounded) ≥80% threshold (cost: $0.04) [corpus: eval-prompts.json]
[N/A]  grounded-rate: no eval prompts defined (research/eval-prompts.json absent)
[N/A]  grounded-rate: eval-prompts.json has 0 prompts
[N/A]  grounded-rate: opt-in required (set SKILL_ENGINE_RUN_EVAL=1 to include the citation-rate eval; ~$0.03–$0.15 per run)
[FAIL] grounded-rate: 40.0% (2/5 prompts grounded) below 80% threshold (cost: $0.05) [corpus: eval-prompts.json]
[FAIL] grounded-rate: eval-prompts.json schema invalid — missing 'prompts' key
```

The trailing `[corpus: <filename>]` names the corpus that produced the
rate. A contextualizer may split its corpus into a train set and a
held-out set (chapter 13, *Splitting the corpus*); a grading run scores
exactly one of them, so the rate carries the name of the set it came
from and cannot later be misattributed to the other.

On FAIL, the header is followed by one indented line per non-grounded
prompt naming the prompt id, the failure marker
(`no-reference-opened`, `no-permalink-in-response`,
`tool-turn-cap-exceeded`, `per-prompt-timeout`, `api-error`), and a
60-char prefix of the prompt text:

```
  n02 [no-reference-opened]:  List the parameters of MCPServer.run() and their de
  n04 [no-permalink-in-response]:  What happens when an elicitation request time
```

Three runs can agree a prompt failed and disagree about why — one run
opening no reference while the other two die on a rate limit is a single
FAIL vote three times over, not a flicker. That prompt's marker names
every distinct reason, prefixed `mixed:` and sorted, so a partial outage
cannot be read as a routing defect and retuned against:

```
  n03 [mixed:api-error+no-reference-opened]:  Q3: signature of Gamma's inte
```

The read is: any marker carrying `api-error`, `per-prompt-timeout`, or
`tool-turn-cap-exceeded` is a statement about the run, not about the
navigator. Rerun before concluding anything about the corpus.

A prompt whose 3 runs did not unanimously agree — some grounded, some
not — is reported distinctly, named `flicker` rather than folded into a
grading marker. The `[flicker]` line prints regardless of overall
PASS/FAIL, alongside (never instead of) the header's PASS/FAIL/N/A line:

```
  n03 [flicker]:  Q3: signature of Gamma's interface.
```

**How it runs.** SELF-AUDIT checks the opt-in env var first; on opt-in,
invokes the bundled Python runner:

```bash
if [ -n "${SKILL_ENGINE_RUN_EVAL:-}" ]; then
  # --threshold omitted: inherits DEFAULT_THRESHOLD (sourced from
  # permalink_density.DEFAULT_COVERAGE_THRESHOLD — one bar for Checks 7 and 8).
  python3 "$CLAUDE_PLUGIN_ROOT/tests/grounded_rate.py" "$CTX_ROOT"
else
  echo "[N/A]  grounded-rate: opt-in required (set SKILL_ENGINE_RUN_EVAL=1 to include the citation-rate eval; ~\$0.03–\$0.15 per run)"
fi
```

The runner writes its findings to stdout and exits 0 (PASS or N/A), 1
(FAIL or schema invalid), 2 (runner failure — every prompt errored), or
3 (ImportError on `anthropic`). SELF-AUDIT reads the exit code and rolls
the result into its findings table as a Check 8 row.
