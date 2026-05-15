# 12-Evaluation

**Question locked:** How does a maintainer prove their navigator routes correctly rather than just claim it?

This chapter ships the measurement primitive the engine has been missing. Without it, the navigator's [description](02-artifact-contract.md#description-quality-is-part-of-the-contract) — the field every consuming agent matches against — is tuned by feel. Tuning by feel produces drift: a wording change made on Tuesday to fix one failure mode silently regresses three others by Friday. The drift is invisible until a maintainer sits down to debug a routing complaint and realises they have no signal for the change they made last week.

**Short answer:** every contextualizer carries a small set of `evals/evals.json` queries co-located with its navigator skill; a harness runs each query three times against the navigator and records pass/fail per run; a renderer aggregates the runs, stratifies by persona, and reports deltas between two invocations. The eval set is split 70/30 train/test once and never regenerated. The framework is bash + JSON + a single-file HTML viewer, plus the agent CLI you are already running the navigator through (the engine's runtime — not a third-party dependency on top of it).

## When to read this chapter

Read this chapter when:

* You have a navigator and one or more reference files in `references/`, and you want a way to detect routing regressions before a downstream consumer notices.
* You are about to edit the navigator description and want to know whether the edit improved or worsened routing, not just whether it "looks better."
* You are reviewing a proposed description change in a pull request and want a measurable artefact to back the decision.

You can ship a navigator without evals; the engine does not gate on their presence. But once a navigator has more than a handful of references — or once two people are editing the description independently — the lack of a measurable signal becomes the constraint.

## What evals stress-test

The eval framework's tightest semantic dependency is the description-quality contract in [02-artifact-contract.md](02-artifact-contract.md#description-quality-is-part-of-the-contract). Two failure modes the description guards against — *too vague* (the agent never invokes the skill) and *too broad* (the agent invokes on irrelevant queries) — are exactly what an eval set surfaces empirically. The companion guidance in [02-artifact-contract.md](02-artifact-contract.md#description--when-never-what) — that the description must answer the agent's *"is this query mine?"* question, not the human's *"what does this skill cover?"* question — is the property an eval set proves or disproves.

The eval set asks: given a representative query a real consumer might send, did the navigator route it to the reference the maintainer expected? A pass means the description's WHEN-condition matched; a fail means it did not. The test surface is the description's discrimination power, not the catalog's bijection count or any of the structural invariants that `verify.sh` already covers.

## The eval set: location and schema

### File location

The eval set lives at `evals/` **co-located with the navigator skill** — sibling to `SKILL.md`, not at the project root. A contextualizer's tree:

```
<area-domain>-context/
├── SKILL.md
├── references/
│   ├── <area-domain>-<topic-1>.md
│   └── <area-domain>-<topic-2>.md
└── evals/
    ├── evals.json
    └── results-20260509T141200Z.json
```

Co-location is the convention because the eval set is part of the navigator's contract, not the workspace's. Two sibling navigators in the same workspace can carry independent eval sets without colliding.

### Schema shape

`evals/evals.json` is a single JSON document with a top-level `schema_version` field and an `entries` array:

The example below assumes a contextualizer named `auth-context` with reference files `references/auth-mfa.md` and `references/auth-sso.md`; the entries are shown in the substituted form a maintainer ships, not the placeholder form.

```json
{
  "schema_version": 1,
  "entries": [
    {
      "query": "How do we handle MFA recovery when a user loses their phone?",
      "expected": "auth-mfa",
      "notes": "Recovery flow is in the MFA reference; provisioning touches it via lifecycle but is not the primary route.",
      "tags": ["mfa", "recovery"],
      "persona": "domain-expert"
    },
    {
      "query": "Can a user log in without a password?",
      "expected": "auth-sso",
      "notes": "Passwordless lives under SSO; non-technical phrasing exercises whether the description discriminates on intent rather than jargon.",
      "tags": ["sso", "passwordless"],
      "persona": "non-technical"
    }
  ]
}
```

**Required fields** on every entry:

* `query` — the prompt the navigator will be tested against. Phrase it the way a real consumer would phrase it, not the way the maintainer would phrase it after years of jargon exposure.
* `expected` — the routing outcome the eval asserts: which reference the navigator should pull, or which catalog row should fire. Use the reference filename without the `.md` extension (e.g., `auth-mfa`).
* `notes` — a free-form explanation of why this query represents a meaningful audience signal. The notes are for the human reviewing aggregate results, not for the harness; an entry without notes will run, but the next maintainer will not know why it was authored.

**Optional fields:**

* `tags` — free-form labels for filtering at aggregation time (e.g., aggregate pass rate by topic area, or by feature flag rollout cohort).
* `persona` — the audience persona the query represents. See [the multi-persona axis](#the-multi-persona-axis) below.

### Schema versioning

The top-level `schema_version` field is **a JSON integer ≥ 1**. The renderer enforces this strictly:

* `1` (integer) — accepted as v1.
* `"1"` (string), `1.0` (float), `null`, or boolean — rejected with the offending type named in the error.
* `0` or any negative integer — rejected as unknown-version.
* Field absent — defaulted to v1. Absent is the only path to a silent default; type-coercion is never silent.

This strictness is deliberate. The schema is the contract between the entries on disk and the renderer that interprets them; a silent string-to-integer coercion would mask the day a `schema_version: "2"` entry quietly fell through to v1 logic and produced misleading aggregates.

### Migration contract for future schema bumps

A future story may add, remove, or rename fields — including persona values. When that happens:

1. The change MUST bump `schema_version` to `2`.
2. The change MUST ship a one-step migration helper that rewrites a v1 file to a v2 file, including any default-value insertions.
3. The renderer MUST accept either v1 or v2 during the migration window, dispatching on the version field.

Files lacking the field default to v1 (back-compat with any pre-versioning eval set authored against a draft of this chapter). Once the migration window closes, the v1 path is removed in a subsequent MAJOR engine release per [10-version-evolution.md](10-version-evolution.md).

## The multi-persona axis

A navigator's description has to route correctly for queries phrased by a domain expert *and* by someone who has never heard of the domain before. A description tuned only against domain-expert phrasings — the maintainer's natural register — passes its own evals and fails real users.

The framework addresses this with a `persona` enum on every eval entry. Three values in v1:

| Persona | What it captures |
|---|---|
| `domain-expert` | The query uses domain jargon naturally. The author of the eval is fluent in the same vocabulary as the navigator's reference files. This is the persona most maintainers default to when authoring evals, so it is also the persona most likely to overstate routing quality. |
| `domain-naive-technical` | The query is technically literate but unfamiliar with this specific domain — a senior engineer from a sibling team who knows software but not your service. Phrased in general technical terms ("authentication", "session expiry") rather than your domain's terms ("token rotation", "refresh-token sliding window"). |
| `non-technical` | The query is phrased the way a product manager, a support engineer, or an end-user would phrase it. No jargon. Often a one-sentence question. Stress-tests whether the description discriminates on intent rather than vocabulary match. |

Author the eval set with all three personas represented in roughly equal proportion. A heavy `domain-expert` bias is the default failure mode.

The renderer stratifies aggregation by persona AND overall: per-persona pass rates surface which audiences the navigator routes well for, and which it does not.

## Methodology

### The 70/30 train/test split

When the eval set has more than ten entries, hold out a random 30% as a **test set** and use the remaining 70% as the **train set**. The split is one-time at eval-set creation; it is not regenerated per run.

The split lives in **two separate files**: `evals/evals-train.json` and `evals/evals-test.json`. Physical segregation is the discipline — a `test_set` field or a tag would put test entries in the same buffer the maintainer is editing, and the entries become impossible not to see while iterating on the description. Two files make over-fitting take work; one file with a flag makes it the path of least resistance.

The harness takes the eval-set path as its first argument. Run the train set with `bash evals/run-eval.sh evals/evals-train.json` (often, while iterating); run the test set with `bash evals/run-eval.sh evals/evals-test.json` (rarely, at description-stability checkpoints).

* The **train set** is what the maintainer iterates against. Edit the navigator description, run the train set, observe the pass-rate delta, repeat.
* The **test set** is *never* used to optimize the description. Run it occasionally — after a substantial description revision, before a release — to check whether the gains observed against the train set generalise.

If the test-set pass rate diverges from the train-set pass rate over time, the description has been over-fit to the train set's specific phrasings. The fix is the same as in any other train/test split: stop tuning against feedback you have already exhausted, and add new entries — drawn from real consumer queries, not invented — to refresh both sets.

For eval sets under ten entries, the split is not worth the bookkeeping; keep a single `evals/evals.json` (the harness's default), iterate against the full set, and accept that the signal is noisier.

### Three runs per query

Every entry runs **three times per evaluation invocation**. The harness records pass/fail per run; the renderer reports both per-run results and the majority-vote outcome.

Why three runs and not one: language-model routing is not deterministic at the matching layer. A description that fires correctly two runs out of three is a different signal from one that fires three out of three. Single-run evaluation hides that distinction.

A query that flips between pass and fail across the three runs is a **flickering** entry. The renderer surfaces it with a flicker flag rather than letting it average into a silent middle. Flickering is itself a signal: it usually points at a description that almost-but-not-quite discriminates, and the fix is description editing rather than retrying.

### Aggregation contract

When comparing two evaluation invocations — typically a "before" and an "after" around a description edit — the renderer reports per-query deltas:

* **Regressions** — entries that passed in the before run and failed in the after.
* **Gains** — entries that failed in the before run and now pass.
* **Flicker stabilisations** — entries that flickered in the before run and are now stable (in either direction).
* **New flicker** — entries that were stable in the before run and now flicker.

Aggregation is the contract surface: the maintainer reads aggregated deltas and decides whether the description edit was a net improvement, a regression, or a wash. The eval JSON itself is the atomic unit; the maintainer does not stare at individual run records.

The renderer is **deterministic**: the same `results-*.json` file produces identical output bytes on rerun. No timestamps in the output, no random ordering. Determinism is what makes the diff between two renderer runs a meaningful artefact to paste into a pull request.

## The three templates

Three drop-in templates ship with the plugin under `plugin/skill-engine/engine-bootstrap-templates/eval/` (or browse them at <https://github.com/nick-railsback/skill-engine/tree/main/plugin/skill-engine/engine-bootstrap-templates/eval>). A scaffolded contextualizer copies them into its own tree and fills in the placeholders.

| Template | Role |
|---|---|
| `run-eval.sh.template` | The harness. POSIX bash, zero third-party dependencies. Reads `evals/evals.json`, iterates every entry running each query three times against the navigator, writes per-run records to `evals/results-<timestamp>.json`. |
| `eval-viewer.html.template` | The browser viewer. Single-file HTML5: inline CSS, inline JS, no external script imports, no fetch. Loads from `file://`. The maintainer opens it and uses the input file picker to load a sibling `results-*.json`. |
| `render-eval-results.sh.template` | The renderer. POSIX bash. Reads `evals/results-*.json` and produces aggregated text output: per-query pass rates, flicker flags, persona-stratified summaries, optional delta vs. a prior run. Used by the harness for end-of-run summary, and standalone for ad-hoc rendering. |

All three templates carry the `<area-domain>` placeholder at the surfaces where the navigator-skill name appears: the harness invokes `<area-domain>-context`; the viewer's `<title>` and header text identify which navigator's results are being rendered; the renderer's output header names the navigator. Replace the placeholder when you copy the templates into your contextualizer.

The two bash templates ship with the executable bit set. The HTML template does not need it.

## The workflow in practice

A maintainer's day-to-day with the framework is short:

1. **Author** ten-to-thirty `evals.json` entries representative of how real consumers phrase queries against the navigator. Get the persona mix right; do not author them all in the maintainer's natural register.
2. **Split** once: pick a random 30% and write them to `evals/evals-test.json`; the remaining 70% live in `evals/evals-train.json`. (For sets under ten entries, skip the split and keep the single `evals/evals.json`.)
3. **Iterate** against the train set. Edit the description, run `bash evals/run-eval.sh evals/evals-train.json`, render the deltas, decide whether the edit was a net improvement.
4. **Test** occasionally. Run `bash evals/run-eval.sh evals/evals-test.json` after a substantial revision; if its pass rate has diverged from the train set's, the description has been over-fit and the eval set needs new entries.
5. **Track** trends across releases. The renderer's aggregated output is plain text; paste it into a pull request, archive it next to the release notes, diff it against the prior release's output.

The framework does not run on a schedule. There is no CI step, no daemon, no auto-trigger — manual cadence is load-bearing in the engine, and the eval framework respects it. The maintainer runs evals when they want a measurement, not on every commit.

## What this chapter does not cover

The framework's scope is deliberately narrow. Things it does not do:

* **Evaluate reference content quality.** Evals stress-test routing — did the navigator point at the right reference? — not whether the reference itself is correct, complete, or up-to-date. The freshness story is in [03-engine.md](03-engine.md) and [08-discover-pipeline.md](08-discover-pipeline.md).
* **Score absolute description quality.** Evals are relative. A 90% pass rate is meaningful only against a prior measurement, not as a standalone judgement. The framework reports deltas, not letter grades.
* **Replace human review.** A passing eval set does not authorise a description change to land without review. The renderer's output is an input to review, not a substitute.
* **Ship a fixed eval set.** Each contextualizer authors its own. The framework ships the schema, the methodology, and the templates; the entries themselves belong to the navigator.
