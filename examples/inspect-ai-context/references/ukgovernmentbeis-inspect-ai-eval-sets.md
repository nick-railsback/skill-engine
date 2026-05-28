---
name: ukgovernmentbeis-inspect-ai-eval-sets
description: "Covers `eval_set` / `inspect eval-set` for running multi-task, multi-model benchmark sweeps with automatic retry/resume mechanics, Inspect Scout scanner integration, per-sample and scoped limits (time, token, cost, message, working), early stopping, and error-handling discipline including crash recovery and cancelled-run scoring."
---

# Eval sets

`inspect eval-set` and `eval_set()` exist for the case `inspect eval` doesn't cover: running several tasks and/or models together, with automatic retries on partial failure, and the ability to re-run the same command later to pick up where work stopped. They are the right entry point for any benchmark sweep, hyperparameter explore, or long agentic run that you expect to nurse over hours or days.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd#L8-L19

```bash
inspect eval-set mmlu.py mathematics.py \
   --model openai/gpt-4o,anthropic/claude-sonnet-4-0 \
   --log-dir logs-run-42
```

```python
from inspect_ai import eval_set
success, logs = eval_set(
   tasks=["mmlu.py", "mathematics.py"],
   model=["openai/gpt-4o", "anthropic/claude-sonnet-4-0"],
   log_dir="logs-run-42",
)
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd#L22-L45

`eval_set()` returns `(bool, list[EvalLog])` where the bool indicates whether every task+model combination completed and the list holds log *headers only* — sample data isn't included, read the files (or use `list_eval_logs("logs-run-42")`) for that. `success=False` means even after all retries (10 by default) some tasks didn't finish, typically because of a provider outage or a runtime bug in eval code.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd#L160-L176

## Why `log_dir` is required (and load-bearing)

`eval-set` mandates a custom `log_dir` and the directory is the bookkeeping scope. Completed task+model combinations are tracked by their log presence, and reruns consult the same directory to decide what work is left. Once everything in the set is complete, re-running `inspect eval-set` against the same directory is a no-op. Reuse the same `log_dir` across the lifetime of a campaign; rotate it only when you start a fundamentally new sweep.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd#L151-L163

## Retry mechanics

When a task fails (model error, transient sandbox issue, etc.), eval-set logs the failure, reuses already-completed samples on the next attempt so they don't re-cost, preserves partial sample progress across retries, and after a subsequent successful retry cleans up the failed log so only the successful one remains in `log_dir`.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_eval/evalset.py#L103-L116

Retry knobs (and their defaults):

- `--retry-attempts` — max retry attempts (default 10).
- `--retry-immediate` / `--no-retry-immediate` — immediate retry as tasks fail is the default; `--no-retry-immediate` reverts to legacy batch-retry where the suite waits for everything to finish before retrying failures.
- `--retry-wait` — base wait between batch retries, grown exponentially (30, 60, 120, 240, …). Ignored under `--retry-immediate`.
- `--retry-connections` — multiplicative reduction in max connections per retry (default 1.0 = no reduction). Useful for dodging rate-limit storms in batch mode. Ignored under `--retry-immediate`.
- `--no-retry-cleanup` — keep failed log files around after a successful retry instead of cleaning them up.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd#L106-L118

The common pattern: eval-set fails partway through a 12-hour run; the operator inspects logs, fixes the issue (e.g., key rotation), and re-runs the same command. Work resumes from the last successful checkpoint.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd#L47-L51

## Concurrency

`eval_set()` runs multiple tasks in parallel, using `max(10, len(models))` as the default `max_tasks`. The scheduler actively balances active tasks across models to minimize contention on any one provider. Override with `max_tasks=8` (or `--max-tasks` on the CLI) when you want to hand-tune throughput.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd#L61-L74

## Amending a running set

You can change the command between runs and add work:

```bash
inspect eval-set mmlu.py mathematics.py \
   --model openai/gpt-5,openai/gpt-4o,anthropic/claude-sonnet-4-0 \
   --epochs 3 \
   --log-dir logs-run-42
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd#L51-L59

Add a model, increase epochs, add a task — re-issue with the same `--log-dir` and the new combinations get scheduled while completed ones are left alone.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd#L51-L60

## Dynamic tasks

Tasks can be passed as constructed objects rather than file paths, but the function that produces them must itself be `@task`-decorated and must accept ordinary serialisable Python types (`str`, `int`, `list`, …) — never custom objects. Inspect captures the call arguments to distinguish "the same" task across runs and pair it with its log files for retry, so a custom class with an unstable `repr` breaks resume.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd#L77-L104

```python
@task
def create_task(dataset: str):
  return Task(dataset=csv_dataset(dataset))

eval_set([create_task("mmlu.csv"), create_task("maths.csv")], model=[...], log_dir="logs-run-42")
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd#L80-L95

You can pass a `solver` to an `@task` function provided that solver was itself produced by an `@solver`-decorated function.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd#L104-L104

## Task enumeration

Pass file paths, `file.py@task_name` selectors, or directories — directories are recursively scanned for `@task` definitions. Two recursion rules to remember: files/directories starting with `.` or `_` are skipped, and directories named `env`, `venv`, and `tests` are skipped. `inspect list tasks security --json -F light=true` enumerates and filters, and `inspect list tasks security | xargs inspect eval-set --log-dir logs-security-42` is the canonical pipe-to-run.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd#L265-L312

Task attributes used as filters must be constant literals (`@task(light=True)`), not function calls (`@task(light=light_enabled("ctf"))`) — the lister parses code without executing it.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd#L313-L326

## Scanners on eval-set

`--scanner` (or `ScannerConfig`) runs [Inspect Scout](https://meridianlabs-ai.github.io/inspect_scout/) scanners over each task's logs as part of the run. Scanners look for things that pass/fail metrics hide — refusals, evaluation awareness, environment misconfiguration, runtime errors, reward hacking. They differ from scorers in two important ways: they typically return findings only on transcripts where they detect something (so output is sparse), and findings are written to `<log_dir>/scans/` separately from the eval log so scanner results across many evals can be reviewed together.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/scanners.qmd#L1-L25

Three integration points:

- **Online**: pass `scanner=[refusal(), eval_awareness()]` to `eval()`/`eval_set()`; transcripts are scanned as samples complete. Use `ScannerConfig(scanners=[...], model="anthropic/claude-opus-4-7")` to run the scanners with a different (typically cheaper or stronger-judge) model than the one under evaluation. CLI equivalents are `--scanner` (file, `file.py@func`, registry ref, or YAML/JSON config) and `--scan-model` (or env `SCOUT_SCAN_MODEL`).
- **Offline**: `scout scan my_scanners.py -T ./logs --model openai/gpt-5` runs the same scanners over an existing log directory; results land in the same `./logs/scans/` so online and offline compose.
- **Scanners as scorers**: drop a scanner into a `Task(scorer=[match(), reward_hacking()])` list and its `Result` is converted to a `Score` and aggregated by the metrics attached via `@scanner(metrics=...)`. Output then lands in the eval log's scores, not in `scans/`.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/scanners.qmd#L27-L123

Authoring is via `@scanner` + `llm_scanner(question=..., answer="boolean")` for LLM-judged checks, or `grep_scanner(["password", "secret", "token"])` for plain text patterns. `messages=` on the decorator (`'all'`, `'assistant'`, `'user'`, or a list) controls which roles the scanner sees.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/scanners.qmd#L125-L158

`ScannerConfig` definition lives in:

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_eval/task/scan.py#L53-L115

## Setting limits

Sample limits don't error — they trigger an early exit and the partial `TaskState` is scored (almost always as incorrect). Settable on `Task`, `eval`, or `eval_set`:

- `message_limit` — total messages in the conversation (not just new ones the agent appended).
- `token_limit` — total tokens used over the *whole sample*. Distinct from generation-side `max_tokens`, which caps a single model call.
- `time_limit` — wallclock seconds per sample; backed by `anyio` cancellation scopes so the block is cancelled at the next `await`.
- `working_limit` — time spent "working" excluding waits (e.g., excluding sleep, retries, polling); checked periodically, e.g., from `generate()` and after each `Solver` runs.
- `cost_limit` — dollar limit per sample. Requires `set_model_cost()` or `--model-cost-config pricing.yaml` for every model in the run, otherwise an error is raised at setup.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/setting-limits.qmd#L16-L50

`with token_limit(10_000):`, `with time_limit(15*60):`, `with apply_limits([token_limit(1000), message_limit(10)], catch_errors=True) as scope:` apply limits to arbitrary scoped blocks; `LimitExceededError` is what fires when one is exceeded. Stacked `token_limit` and `cost_limit` context managers all charge against simultaneously; `message_limit` only checks the innermost active limit. Use `suspend_token_limit()` to fully disable both recording *and* checking for a block (`with token_limit(None):` only suppresses the innermost check). Query state with `sample_limits().time.remaining` or by keeping a reference to the limit and reading `limit.usage`.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/setting-limits.qmd#L221-L397

Limit function definitions in source:

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_limit.py#L26-L504

A common ergonomic pairing: pair `time_limit=15*60` on the task with `bash(timeout=3*60)` on tools, so a single runaway tool call can't burn the whole sample budget.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/setting-limits.qmd#L22-L48

## Error handling discipline

Errors fall in two buckets. **Runtime errors** (Python exception in a solver, API blip, sandbox failure) produce a log with status `"error"` that retains all completed samples and can be retried. **Crash recovery** (OOM, segfault, `kill -9`, power loss) leaves a log with status `"started"`; Inspect's sample buffer database (retained 3 days) is used to recover unflushed samples on the next `eval_set()` or `eval_retry()` automatically, or manually via `inspect log recover path/to/crashed.eval` (add `--overwrite` to replace, or `--output` to write elsewhere).

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/handling-errors.qmd#L8-L20

Tune the tolerance with `fail_on_error`:

- `True` (default) — fail eval immediately on any sample error.
- `False` — never fail eval on sample errors.
- `0.1` — fail if more than 10% of samples error (proportion).
- `5` — fail if more than 5 samples error (count).

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/handling-errors.qmd#L46-L55

Set this to a small float like `0.05` for production runs so a few flaky samples don't kill an overnight job; use `--no-fail-on-error` for dev only when you want immediate noise. Set `retry_on_error=1` (or `--retry-on-error=3`) to retry individual sample errors before they count against `fail_on_error`; original errors are preserved in the sample's `error_retries` field. Watch for distribution shift: if a bug only triggers on certain inputs, those inputs get retried more often and silently get a higher success rate — do post-hoc analysis on retried vs. non-retried results.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/handling-errors.qmd#L65-L88

`score_on_error=True` (CLI: `--score-on-error`) scores errored samples on whatever partial `TaskState` was reached, useful when "the model crashed mid-run" is itself meaningful signal. It composes with `retry_on_error` (only the final attempt is scored) and still counts errors toward `fail_on_error`. Your scorer must tolerate a partial state (no model output, truncated history), otherwise the sample ends up with an error and no score.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/handling-errors.qmd#L91-L119

## Cancelled runs

Cancelled runs (Ctrl-C, time limit, etc.) are scored with partial results aggregated rather than discarded. The eval log records the cancellation; downstream analyzers should check `log.status` before treating metrics as final.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/handling-errors.qmd#L122-L165

## Early stopping

Implement the `EarlyStopping` protocol (four async methods: `start_task`, `schedule_sample`, `complete_sample`, `complete_task`) and pass it as `Task(early_stopping=MyEarlyStopping(), epochs=5)` to skip samples or epochs based on prior results — useful for adaptive testing, "stop after k consistent epochs", or focusing budget on samples near the model's capability boundary. `schedule_sample()` returns an `EarlyStop(id, epoch, reason, metadata)` to skip; the log records an `EarlyStoppingSummary` listing every skipped sample so the behaviour is auditable post-hoc.

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/early-stopping.qmd#L1-L35

`EarlyStopping` protocol definition:

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_early_stopping.py#L42-L95

## Publishing

`--bundle-dir <path>` (plus `--bundle-overwrite`) writes a standalone copy of the log viewer for the set, deployable to any static host (GitHub Pages, S3, Netlify).

https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd#L138-L149

## See also

- `ukgovernmentbeis-inspect-ai-tasks.md` — task definition that an eval-set runs.
- `ukgovernmentbeis-inspect-ai-logs-and-analysis.md` — log file structure that eval-set populates.
- `ukgovernmentbeis-inspect-ai-cli-and-config.md` — `INSPECT_EVAL_*` env vars that apply equally to eval-sets.

## Source

- `docs/eval-sets.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-sets.qmd
- `docs/scanners.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/scanners.qmd
- `docs/setting-limits.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/setting-limits.qmd
- `docs/early-stopping.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/early-stopping.qmd
- `docs/handling-errors.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/handling-errors.qmd
- `src/inspect_ai/_eval/evalset.py` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_eval/evalset.py
- `src/inspect_ai/_eval/task/scan.py` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_eval/task/scan.py
- `src/inspect_ai/util/_limit.py` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_limit.py
- `src/inspect_ai/util/_early_stopping.py` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_early_stopping.py
- Repo SHA: `033745ddbc05431c38b015a4b8f2236e956ee9ea`
