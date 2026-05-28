# 13-Coverage-testing

**Question locked:** How does a contextualizer prove that its prose is verifiable against upstream sources, and that the model answering with it cites those sources rather than paraphrasing them?

This chapter documents the two grounding instruments the engine ships: a corpus-side density check (paragraph→permalink coverage) and an answering-side citation check (grounded-citation rate). Together they ask whether the references *contain* anchors near load-bearing prose, and whether the model *emits* an anchor when it answers. Both are wired into SELF-AUDIT as Checks 7 and 8 respectively.

**Short answer:** Check 7 is a Python lint, free and bash-local, that walks `references/**/*.md` and asks whether each prose paragraph has a SHA-pinned (or stable-tag-pinned) GitHub permalink within five lines. The threshold is ≥80% corpus-wide. Check 8 is an opt-in Anthropic API runner that replays each `needs_reference` prompt in `research/eval-prompts.json` against the contextualizer and grades whether the model both opened a reference *and* emitted a SHA-pinned permalink in its final response text. Threshold ≥80% by default. The grader is verified keyless and deterministically; the live rate is per-contextualizer and downstream.

## Scope and delineation from chapter 12

[Chapter 12](./12-evaluation.md) covers *navigator routing* — does the navigator's description match the queries it is supposed to handle, and not the queries it is supposed to ignore? The eval set lives at `evals/evals.json` and stresses the description's discrimination power. The pass/fail question is **does the right reference get routed to this query**.

This chapter covers *grounding and coverage* — once routing has succeeded and a reference is in play, is the reference's prose anchored to upstream, and does the model emit that anchor in its answer? The two instruments live at `plugin/skill-engine/tests/permalink_density.py` (Check 7) and `plugin/skill-engine/tests/grounded_rate.py` (Check 8). The pass/fail question is **are the references themselves verifiable, and does the model say so**.

Different files, different question. Read 12 to debug routing; read 13 to debug verifiability.

## When to read this chapter

Read this chapter when:

* You are looking at a SELF-AUDIT Check 7 or Check 8 row and want to know what the number means.
* You are evaluating whether the engine's "structural honesty" claim is mechanically backed or aspirational.
* You are forking a contextualizer and want to run the grounded-citation eval against your own prompt corpus.
* You are reviewing this repo as portfolio surface and want to see what the measurement discipline is, including what it deliberately does not measure.

## Check 7 — paragraph→permalink density (corpus side)

### The rule

A prose paragraph is *covered* when at least one SHA-pinned (40-hex-char commit) or stable-tag-pinned (`v<X>[.<Y>[.<Z>]]`) GitHub permalink appears anywhere in the range `[paragraph_start − 5, paragraph_end + 5]` in the same file. Heading lines, fenced code blocks, table rows, list items (and their indented continuations), blockquotes, HTML comments, and leading YAML frontmatter are excluded from the paragraph aggregation — the metric measures *prose*, not structural markup. The aggregation is corpus-wide: total covered paragraphs divided by total in-scope paragraphs across all `references/**/*.md` files. The pass threshold is **≥80%**.

### Live measurements (as of 2026-05-28)

Measured against the three bundled `examples/` contextualizers at the v0.3.0 emission, the lint reports:

| Contextualizer | Coverage | Paragraphs |
|---|---:|---:|
| `modelcontextprotocol-python-sdk-context` | **100.0%** | 174 / 174 |
| `inspect-ai-context` | **97.6%** | 534 / 547 |
| `langchain-context` | **92.6%** | 187 / 202 |

All three clear the bar. These are live measurements against the shipping corpora, not targets. The figures are pinned to the date in this heading — if the bundled `examples/<slug>/references/` corpora change after that date, the figures here may drift. Reproduce with `python3 plugin/skill-engine/tests/permalink_density.py examples/<slug>/references`.

### Threshold scoping (the documented limitation)

**GitHub-permalink density is a git-source metric; web-doc / multi-source verifiability is out of scope for this gate.** The lint is flat and source-blind: it walks `references/**/*.md` and counts paragraphs against the same threshold regardless of where those paragraphs originated. The flatness is deliberate — a check that read a self-authored `source-paths.json` field to decide whether to grade you would be gradeable on your own answer key.

`inspect-ai-context` is the multi-source case in the bundled corpus. Its registered sources include the `UKGovernmentBEIS/inspect_ai` git repo *and* the `inspect.aisi.org.uk/` documentation portal, which is web-doc. Web-doc prose has no GitHub permalink to sit near — the metric cannot credit it directly. That `inspect-ai-context` nonetheless clears 97.6% reflects an emission discipline rather than the metric becoming more permissive: every web-doc-side module section in `inspect-aisi-org-uk-api-reference.md` is authored with a SHA-pinned GitHub permalink into the source repo immediately adjacent. A future contextualizer with a pure web-doc source set, and no upstream code repo to cross-reference, could not be credited by this check at all. The ceiling is real; the bundled corpus clears it because its authors put permalinks where the metric would look for them.

## Check 8 — grounded-citation rate (answering side)

### The grader, verified

Check 7 measures what the references *contain*. Check 8 measures what the model *says* when it answers. For each `needs_reference` prompt in `research/eval-prompts.json`, the runner invokes the contextualizer's `SKILL.md` as system prompt against Claude Haiku 4.5 with a single `read_reference` tool, and grades whether the model both (a) opened ≥1 reference and (b) emitted a SHA-pinned or tag-pinned GitHub permalink in its final response text. The permalink regex is imported from the Check 7 lint so the two checks share one source of truth.

The test runner at `plugin/skill-engine/tests/grounded-rate/run.sh` exercises the grader against **17/17 mocked cases** with zero API calls — the cases inject pre-recorded model responses (`--mock-responses`) and assert exit-code + stdout substring. The grader runs keyless and deterministically: no environment credentials, no network I/O, identical exit codes on repeat invocations. Coverage spans PASS, FAIL, schema-invalid, opt-in N/A, empty-prompts N/A, error-marker handling, and the per-prompt timeout / tool-turn-cap paths. The fixtures live at `plugin/skill-engine/tests/grounded-rate/fixtures/`.

***Grader validated (mocked, 17/17 as of 2026-05-28); live rate not yet measured in this repo.***

### What is not here, and why

There is **no committed `eval-prompts.json`** in this repo. The file is a per-contextualizer downstream artifact: committing one to the engine repo would couple the engine to a single contextualizer's prompt set, invite gaming (the grader sees the prompts), and churn whenever an example is re-snapshotted. Check 8 therefore reports `[N/A]` against this repo by design, and the rate the engine prints for the bundled `examples/` is unmeasured live. The grader being verified deterministically is the engine-side claim; what a forker's contextualizer actually scores is downstream territory.

### Live-run recipe (for a forker)

A maintainer running Check 8 against their own contextualizer supplies an Anthropic API key, writes a `research/eval-prompts.json`, and either invokes the runner directly or sets the SELF-AUDIT opt-in. Transcribed from `grounded_rate.py` and the fixtures at `tests/grounded-rate/fixtures/`:

**Opt-in env var.** SELF-AUDIT's bash entry checks `SKILL_ENGINE_RUN_EVAL` before invoking the runner. Setting it to any non-empty value (e.g. `1`) enables Check 8; unset, Check 8 emits `[N/A]` and exits 0 without calling the API. The runner script itself does not check the env var — it runs whenever invoked, so a direct `python3 grounded_rate.py …` invocation bypasses the opt-in.

**API key source.** The `--api-key-source` flag accepts two values: `keychain` (default, macOS `security find-generic-password -s anthropic-api-key`) and `env` (reads `ANTHROPIC_API_KEY`). The default is macOS-only; on Linux or Windows pass `--api-key-source env` and export `ANTHROPIC_API_KEY` in the shell. The script never logs the key.

**`eval-prompts.json` schema.** The runner validates the file as a JSON object with `schema_version: 1` and a `prompts` list. Each prompt object requires three non-whitespace string fields: `id`, `category`, `text`. The grader only acts on prompts whose `category == "needs_reference"`. Example shape, lifted from the test harness:

```json
{
  "schema_version": 1,
  "prompts": [
    {"id": "n01", "category": "needs_reference", "text": "what is Alpha's import path?"},
    {"id": "n02", "category": "needs_reference", "text": "list the v1→v2 migration steps."},
    {"id": "n03", "category": "needs_reference", "text": "signature of Gamma's interface."}
  ]
}
```

**Invocation.** Place the file at `<CTX_ROOT>/research/eval-prompts.json` and run (macOS keychain form):

```bash
SKILL_ENGINE_RUN_EVAL=1 \
  python3 plugin/skill-engine/tests/grounded_rate.py "<CTX_ROOT>" \
    --api-key-source keychain
```

Or, on Linux / Windows (env-var form):

```bash
SKILL_ENGINE_RUN_EVAL=1 ANTHROPIC_API_KEY="$YOUR_KEY" \
  python3 plugin/skill-engine/tests/grounded_rate.py "<CTX_ROOT>" \
    --api-key-source env
```

These examples omit `--threshold`; both Check 7 and Check 8 default to the same
bar (`DEFAULT_COVERAGE_THRESHOLD` in `plugin/skill-engine/tests/permalink_density.py`,
currently `0.80`). Pass `--threshold <ratio>` only to override it for a one-off run.

A `--dry-run` flag validates the prompts file and exits without calling the API. A `--results-json <path>` flag writes full per-prompt records (including each turn's tool calls and the final response text) for downstream analysis.

For the failure-mode catalogue (per-prompt timeout, tool-turn-cap exceeded, no-reference-opened, no-permalink-in-response, api-error), the SELF-AUDIT skill's Check 8 description is the canonical surface — see [`self-audit/SKILL.md` § Check 8](../skills/self-audit/SKILL.md#check-8--grounded-citation-rate).

## What this chapter does not measure

This chapter covers grounding. It does not cover:

* **Whether the prose is correct.** A paragraph with a SHA-pinned permalink to the wrong line still counts as covered. The permalink makes the claim *checkable*, not *true*. The Check 7 disclaimer — *"where a paragraph lacks a nearby permalink, treat the claim as unverified"* — names the boundary.
* **Whether the model's emitted permalink is accurate.** Check 8 grades that a SHA-pinned permalink appears in the final response. It does not fetch the URL or verify that the line range supports the claim.
* **Web-doc verifiability.** Per the threshold scoping above, paragraphs whose primary source is a documentation portal cannot be credited by Check 7's metric directly; they ride on the cross-referenced GitHub permalink that the author placed adjacent. A future verifiable-anchor matcher (e.g. accepting `web.archive.org` snapshots or `/v<X>/` stable-doc URLs) is a possible extension; the bundled corpus would gain ≤6 paragraphs of credit under such a widening, so it is not the engine's leverage point.
* **Routing.** Whether a query reaches the right reference in the first place is [chapter 12](./12-evaluation.md)'s question. Coverage and routing are orthogonal — a contextualizer can route well and ground poorly, or route badly and ground well; the two checks score the two halves independently.

The thing this chapter is not is a quality grade. The reader is invited to look at what was measured, what was deliberately not measured, and the live numbers, and reach their own conclusion.
