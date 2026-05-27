---
name: Scorers and metrics — judging outputs, aggregating samples
source_id: ukgovernmentbeis-inspect-ai
---

# Scorers

A scorer reads the final `TaskState` plus the `Target` from the sample, returns a `Score` (`value`, optional `answer`, `explanation`, `metadata`), and declares one or more `metrics` that aggregate per-sample scores into the eval-level summary. Built-in scoring shapes fall into four buckets:

1. **Exact / heuristic text matchers** — extract an answer and compare.
2. **Statistical text similarity** — `f1`, etc.
3. **Model-graded** — another model judges output against rubric text.
4. **Custom rubric** — anything you write (`@scorer`).

## Built-in scorers

| Function | Behavior |
|---|---|
| `includes()` | Target appears anywhere in output. Case-insensitive by default (`ignore_case=True`). |
| `match()` | Target appears at the **end** (default) or **beginning** of output. Ignores case, whitespace, punctuation by default. `numeric=True` mode handles unicode minus, fractions, fullwidth digits, scientific notation. With `location="exact"`, no slack. |
| `pattern(regex)` | Extract the answer with a regex group, then compare to target. |
| `answer(scope)` | Extracts the text following `ANSWER:` — scope `letter`, `word`, or `line`. |
| `exact()` | Normalized exact-string comparison against any of the targets. |
| `f1()` | F1 score between answer and target word sets (harmonic mean of precision/recall). |
| `model_graded_qa()` | Another model judges whether output answers the question per `target` guidance. Customizable template. |
| `model_graded_fact()` | Narrower variant: does output assert the fact in `target`? Used when output is too complex for `match()`. |
| `choice()` | Pairs with the `multiple_choice()` solver; scores by capital-letter match. |
| `math()` | Extracts answers (incl. `\boxed{}` LaTeX), normalizes, and uses **SymPy** to check mathematical equivalence. Requires `pip install sympy`. |
| `perplexity()` | Per-token NLL over all prompt tokens. Requires `prompt_logprobs` in `GenerateConfig` (supported by `vllm` / SageMaker-vLLM only). |
| `target_perplexity()` | NLL over trailing target tokens only (ARC-C, MMLU, HumanEval-style). |

All built-ins ship with `accuracy()` and `stderr()` as their default metrics.

## Score values

`Score.value` is conventionally one of the constants `CORRECT` (`"C"`), `INCORRECT` (`"I"`), `PARTIAL` (`"P"`), `NOANSWER` (`"N"`), or a float in `[0, 1]`. The default `value_to_float()` converter used by `accuracy()` etc. maps those constants to `1.0`, `0.0`, `0.5`, `0.0` respectively, and also accepts numeric strings and common boolean strings (`"yes"`/`"no"`, `"true"`/`"false"`). Custom string vocabularies need a custom converter: `accuracy(to_float=value_to_float(correct="pass", incorrect="fail"))`.

`Value` is a union: `str | int | float | bool`, a sequence of those, or a `dict[str, ...]` for multi-value scorers (see below).

### Unscored samples

When a scorer cannot produce a value (grader timeout, refusal, error) but you still want to record context, return `Score.unscored(answer=..., explanation=..., metadata=...)`. These are skipped by aggregate metrics and epoch reducers and counted toward `EvalScore.unscored_samples` rather than included as zeros.

## Model-graded scorers

`model_graded_qa()` signature (abridged):

```python
@scorer(metrics=[accuracy(), stderr()])
def model_graded_qa(
    template: str | None = None,
    instructions: str | None = None,
    grade_pattern: str | None = None,
    include_history: bool | Callable[[TaskState], str] = False,
    partial_credit: bool = False,
    model: list[str | Model] | str | Model | None = None,
    model_role: str | None = "grader",
) -> Scorer: ...
```

Default `instructions` ask the grader to emit `GRADE: C` or `GRADE: I`, extracted via the default `grade_pattern`. **Model selection precedence**: explicit `model` arg → bound `model_role` (default `"grader"`, set via `eval(..., model_roles={"grader": ...})` or `--model-role grader=...`) → the model under evaluation. Passing `model=[...]` runs each grader independently and takes the **majority vote**.

Templates receive these variables: `{question}` (from `Sample.input` / `state.input_text`), `{answer}` (model output), `{criterion}` (from `Sample.target`), `{instructions}`. Any `Sample.metadata` keys that don't collide are also injected. If you don't set a per-sample `target`, `{criterion}` is empty — bake the rubric into the template instead (typical for sycophancy / refusal / toxicity evals).

`model_graded_fact()` behaves identically with a fact-oriented template.

For production grading, pin the grader independently of the model under test, e.g. `model="anthropic/claude-opus-4-7"` or via `model_role`.

## Metrics

Each built-in scorer declares default metrics — usually `accuracy()` + `stderr()`. Built-ins importable from `inspect_ai.scorer`:

| Metric | Purpose |
|---|---|
| `accuracy()` | Proportion correct (with optional partial-credit handling). |
| `mean()` | Mean of all scores. |
| `var()`, `std()` | Sample variance / standard deviation. |
| `stderr()` | Standard error of the mean (CLT-based). Supports `stderr(cluster="metadata_key")` for clustered standard errors. |
| `bootstrap_stderr()` | Bootstrapped std of the mean (1000 samples by default; tune via `num_samples`). |

Inspect prefers analytic `stderr()` over `bootstrap_stderr()` for built-ins — both estimate the same quantity at typical eval sizes, and CLT is cheap.

**Overriding metrics on a task**: `Task(..., scorer=choice(), metrics=[custom_metric()])` replaces the scorer's defaults entirely; re-list `accuracy(), stderr()` if you want to keep them.

**Grouping**: `grouped(accuracy(), "category")` emits one metric per distinct `Sample.metadata["category"]` value plus an `"all"` aggregate. Pass `all="groups"` to make `"all"` the mean of group metrics rather than over all samples; customize per-group names via `name_template="category_{group_name}"`.

### Custom metrics

```python
from inspect_ai.scorer import Metric, SampleScore, metric
import numpy as np

@metric
def mean() -> Metric:
    def metric(scores: list[SampleScore]) -> float:
        return np.mean([s.score.as_float() for s in scores]).item()
    return metric
```

`Score` exposes accessors like `as_float()`, `as_str()`, `as_int()`, `as_bool()` to handle the `Value` union.

## Multiple scorers / multi-value scorers

Three patterns:

1. **List of scorers on `Task`** — independent scores stored per sample: `scorer=[model_graded_qa(model="openai/gpt-4"), model_graded_qa(model="google/gemini-2.5-pro")]`.
2. **Multi-value scorer** — one `score()` returns a dict value, with a metrics dict keyed to match (globs allowed):
   ```python
   @scorer(metrics={"*": [mean(), stderr()]})
   def letter_count():
       async def score(state, target):
           a = state.output.completion
           return Score(value={"a_count": a.count("a"), "e_count": a.count("e")}, answer=a)
       return score
   ```
   Metrics may also be `[{dict-keyed-per-key}, whole_dict_metric()]` to compute both per-key and over the full dict.
3. **`multi_scorer(scorers=[...], reducer="mode")`** — run several scorers in parallel and collapse to one score via a reducer (this is how multi-model graded QA works internally).

## Reducing epochs

When `Task(epochs=Epochs(N, reducer))` is set, an epoch reducer collapses the N scores per sample to one. Built-in reducers:

| Reducer | Description |
|---|---|
| `mean` | Average of all scores. |
| `median` | Median. |
| `mode` | Most common score. |
| `max` | Maximum. |
| `pass_at_{k}` | Probability that at least one of `k` epoch attempts succeeds (arXiv 2107.03374, HumanEval-style). |
| `pass_k_{k}` | Probability that **all** `k` epoch attempts succeed (arXiv 2406.12045, τ-bench reliability). |
| `at_least_{k}` | `1` if at least `k` samples are correct, else `0`. |

Multiple reducers can be declared (`Epochs(5, ["at_least_2", "at_least_5"])`) — Inspect runs all of them and the log carries one score series per reducer; metric column names in `evals_df` include the reducer name when more than one is in play. Reducers populate `answer`/`explanation` only if equal across epochs and always carry `metadata` from the first epoch — write a custom `@score_reducer` if you need different merging.

## Writing a custom scorer

```python
from inspect_ai.scorer import (
    Score, Target, scorer, accuracy, stderr, CORRECT, INCORRECT,
)
from inspect_ai.solver import TaskState

@scorer(metrics=[accuracy(), stderr()])
def keyword_in_output(keywords: list[str]):
    async def score(state: TaskState, target: Target):
        text = state.output.completion.lower()
        hit = any(kw.lower() in text for kw in keywords)
        return Score(
            value=CORRECT if hit else INCORRECT,
            answer=state.output.completion,
            explanation=f"matched={hit}",
        )
    return score
```

`score` **must** be `async` so it participates in Inspect's scheduler (critical when calling `await grader.generate(...)` or `await sandbox().read_file(...)`). Use `get_model()` (no arg → model under eval; `get_model("google/gemini-2.5-pro")` for a specific grader; pass a `GenerateConfig` to override temperature / `max_connections`).

For sandbox-aware scoring (e.g. did the agent actually create a file?):

```python
from inspect_ai.util import sandbox

@scorer(metrics=[accuracy()])
def check_file_exists():
    async def score(state, target):
        try:
            await sandbox().read_file(target.text)
            return Score(value=1)
        except FileNotFoundError:
            return Score(value=0)
    return score
```

## Scoring workflow

- `inspect eval task.py --no-score` defers scoring entirely — useful while iterating on a scorer.
- `inspect score path/to/log.eval` re-applies the task's scorer; `--scorer match` or `--scorer path/to/file.py@classify` swaps it; pass scorer args with `-S key=value`.
- `--action append` (default) adds new scores alongside existing ones; `--action overwrite` replaces them. Append mode runs the new scorer with its own metrics — useful when the original eval's metric package isn't available.
- Python equivalent: `score(log, model_graded_qa(model=...), action="append")`. Combine with `read_eval_log` / `write_eval_log` to fan out grader comparisons.

## See also

- `ukgovernmentbeis-inspect-ai-tasks.md` — `Task(scorer=..., metrics=...)` plumbing.
- `ukgovernmentbeis-inspect-ai-eval-sets.md` — `--scanner` / `ScannerConfig` integration with eval-sets (Inspect Scout is a separate package that analyzes completed trajectories post-hoc).

## Source

- `docs/scorers.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/scorers.qmd
- `src/inspect_ai/scorer/` — https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/scorer
- `src/inspect_ai/scorer/_reducer/` — https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/scorer/_reducer
- Repo pin: `033745ddbc05431c38b015a4b8f2236e956ee9ea`
