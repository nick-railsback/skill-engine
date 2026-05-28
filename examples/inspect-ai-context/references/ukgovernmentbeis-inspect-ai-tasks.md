---
name: ukgovernmentbeis-inspect-ai-tasks
description: "Covers the Task class and @task decorator as Inspect's fundamental evaluation unit — bundling dataset, solver, scorer, and all optional configuration (epochs, sandbox, approval, limits, checkpointing, early stopping). Read this when constructing or parameterizing tasks, applying task_with() overrides, understanding the four-layer configuration precedence, exposing solver parameters, or packaging tasks for distribution."
---

# Tasks

A `Task` is the fundamental unit of an Inspect evaluation. It bundles a dataset, a solver (or chain of solvers), and a scorer (or list of scorers), plus optional configuration for sandboxing, approval, retries, epochs, generation settings, and per-sample limits. Tasks are returned from a `@task`-decorated zero-or-more-argument function so they can be parameterized, registered, and re-instantiated cheaply.

Source: [`docs/tasks.qmd` L6–L76](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/tasks.qmd#L6-L76)

```python
from inspect_ai import Task, task
from inspect_ai.dataset import json_dataset
from inspect_ai.scorer import model_graded_fact
from inspect_ai.solver import chain_of_thought, generate

@task
def security_guide():
    return Task(
        dataset=json_dataset("security_guide.json"),
        solver=[chain_of_thought(), generate()],
        scorer=model_graded_fact(),
    )
```

The `@task` decorator registers the wrapped function under the Inspect registry, captures its parameter list, records its source file/run directory for local modules, and stamps every returned `Task` instance with that registry info so it can be reconstructed for reruns.

Source: [`src/inspect_ai/_eval/registry.py` L88–L171](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_eval/registry.py#L88-L171)

## Task options that matter

Source: [`src/inspect_ai/_eval/task/task.py` L61–L240](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_eval/task/task.py#L61-L240)

| Option | What it does | When to reach for it |
|---|---|---|
| `epochs` | Repeat each sample N times; an `Epochs(epochs, reducer)` value can also bind a reducer (e.g. `"mean"`, `"pass_at_k"`). | Stochastic generation; reliability metrics; best-of-N scoring. |
| `setup` | Solver(s) that run before the main solver and are *not* substituted when `--solver` overrides the main solver. | Per-sample fixture writes, dynamic prompt engineering against `metadata`, sandbox initialization. |
| `cleanup` | `async` callable receiving the final `TaskState`; runs on success *and* exception. | Teardown of external resources, releasing leases. |
| `sandbox` | Sandbox runtime spec — a string (`"docker"`), a `SandboxEnvironmentSpec`, or a `(type, config_path)` tuple. | Any task that executes untrusted code or needs a per-sample filesystem. |
| `approval` | `ApprovalPolicy` list, `ApprovalPolicyConfig`, or a path to a YAML policy file. | Human-in-the-loop or policy-gated tool execution. |
| `metrics` | Override the scorer's default metrics. | When you want `accuracy` + `bootstrap_std` instead of the scorer's defaults, or per-scorer metric dicts. |
| `model` / `model_roles` | Pin a default model and/or named roles (e.g. `"grader"`) at task scope. | Rare for `model` — usually `eval(...)` / `--model` wins; common for `model_roles` so a task ships a sensible default grader. |
| `config` | `GenerateConfig` defaults (temperature, max_tokens, reasoning, ...). | Task-intrinsic generation settings; CLI/`eval()` overrides win. |
| `fail_on_error` | `bool` or `float` threshold (fraction of samples allowed to fail). | Tune brittleness for production eval-sets. |
| `continue_on_fail`, `score_on_error` | Continue past per-sample errors; score even when the sample errored. | Long agentic runs where partial credit is informative. |
| `message_limit`, `token_limit`, `time_limit`, `working_limit`, `cost_limit` | Per-sample budgets (`working_limit` excludes idle/retry time). | Cap agentic loops and runaway tool use. |
| `early_stopping` | `EarlyStopping` policy that halts the task once a confidence threshold is reached. | Save spend when results are already statistically decisive. |
| `checkpoint` | `CheckpointConfig` for resumable task state. | Long-running agent tasks where you want crash recovery. |
| `display_name`, `name`, `version`, `metadata`, `tags`, `viewer` | Log-attribution fields surfaced in `EvalLog`. | Distinguish task variants in the log viewer and dashboards. |

The full constructor signature lives in [`src/inspect_ai/_eval/task/task.py` L61–L240](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_eval/task/task.py#L61-L240); the prose tour is in [`docs/tasks.qmd` L38–L76](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/tasks.qmd#L38-L76).

## Override precedence

Inspect resolves task configuration through four layers, lowest to highest: (1) the `Task(...)` defaults baked into the `@task` function, (2) `task_with(...)` programmatic overrides, (3) environment variables / `.env` (`INSPECT_EVAL_*`, with hyphens converted to underscores), (4) `eval()` keyword args and the equivalent `inspect eval` CLI flags. Each later layer wins.

Source: [`docs/task-configuration.qmd` L23–L168](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/task-configuration.qmd#L23-L168)

Some parameters — `dataset`, `setup`, `scorer`, `cleanup`, `metrics` — have *no* CLI or `eval()` knob and can only be changed via `task_with()`. The complete override-reference matrix is in [`docs/task-configuration.qmd` L169–L268](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/task-configuration.qmd#L169-L268).

## Parameterized tasks

`@task` functions can accept arguments to make one task definition cover a family of evals. Inspect picks up the kwargs from CLI via `-T name=value` and records them in the eval log so reruns are reproducible.

Source: [`docs/tasks.qmd` L77–L131](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/tasks.qmd#L77-L131)

```python
@task
def arithmetic(operator: str = "+", max_digits: int = 3):
    return Task(...)
```

```bash
inspect eval arithmetic.py -T operator=* -T max_digits=4
```

For bundles of parameters, point at a YAML/JSON file with `--task-config=config.yaml`, or use `--run-config` when you also want model/generation/solver settings in the same file (see [`docs/task-configuration.qmd` L334–L401](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/task-configuration.qmd#L334-L401)). Avoid duplicating framework knobs (`temperature`, `max_tokens`) as task parameters — Inspect's built-in flags override the task's `GenerateConfig` and stay reproducible without you re-plumbing them.

## Task reuse — `task_with()`

When you want to derive a new task from an existing one with tweaks (different scorer, different epochs, different sandbox compose file), avoid re-defining: `task_with(original_task, scorer=...)` returns the same `Task` instance with the listed overrides applied. It is the only documented path for substituting `dataset`, `setup`, `cleanup`, `scorer`, or `metrics` at runtime.

Source: [`src/inspect_ai/_eval/task/task.py` L242–L433](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_eval/task/task.py#L242-L433)

The function uses a `NOT_GIVEN` sentinel for defaults rather than `None`, so passing `None` explicitly *clears* a value the base task set. `task_with()` mutates **in place** — to produce multiple variants, instantiate the base task once per variant.

Source: [`docs/task-configuration.qmd` L75–L112](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/task-configuration.qmd#L75-L112)

```python
# Correct — two independent tasks
task_a = task_with(simpleqa(), solver=agent_a())
task_b = task_with(simpleqa(), solver=agent_b())

# Wrong — both end up with agent_b's solver
base = simpleqa()
task_a = task_with(base, solver=agent_a())
task_b = task_with(base, solver=agent_b())
```

## Solver-flexible tasks

By default a task ships with its own solver, and `--solver` will substitute it. To make the solver an explicit knob (e.g. for solver bake-offs), expose a `solver` parameter and pick a sensible default inside the body.

Source: [`docs/tasks.qmd` L132–L252](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/tasks.qmd#L132-L252)

```python
@task
def ctf(solver: Solver | None = None):
    if solver is None:
        solver = ctf_tool_loop()
    return Task(
        dataset=read_dataset(),
        setup=ctf_prompt(),   # always runs, even when --solver replaces `solver`
        solver=solver,
        sandbox="docker",
        scorer=includes(),
    )
```

Then `inspect eval ctf.py --solver=ctf_agent -S attempts=5` runs an alternate solver, with `-S` passing kwargs to *the solver* the way `-T` passes them to the task. The `setup` solver always runs even when the main solver is replaced, making it the right place for prompt scaffolding that must be consistent across solver variants.

Source: [`docs/tasks.qmd` L221–L252](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/tasks.qmd#L221-L252)

## Packaging

Tasks distributed as Python packages register through the `inspect_ai` setuptools entry-point group. Conventionally, expose a `_registry.py` that imports each task you want discoverable.

Source: [`docs/tasks.qmd` L333–L455](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/tasks.qmd#L333-L455)

```python
# evals/evals/_registry.py
from .tasks import mytask
```

```toml
# pyproject.toml
[project.entry-points.inspect_ai]
evals = "evals._registry"
```

Users can then run `inspect eval evals/mytask`. The same mechanism is what makes `inspect eval inspect_evals/gaia` work. Hugging Face datasets can also carry an `eval.yaml` that produces tasks via `inspect eval hf/<org>/<dataset>`; multi-task datasets use a `:` suffix (e.g. `hf/OpenEvals/MuSR/musr:murder_mysteries`).

Source: [`docs/tasks.qmd` L386–L453](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/tasks.qmd#L386-L453)

## Exploratory vs. production

For exploratory work, scripts with a few `@task`-decorated functions plus `itertools.product` over parameters fed into `eval_set([...])` are the idiomatic pattern — pass a list of models alongside to fan out the matrix.

Source: [`docs/tasks.qmd` L456–L489](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/tasks.qmd#L456-L489)

For production eval campaigns, use `eval_set` with a stable `log_dir`; this is what makes retries idempotent and partial work resumable — see `ukgovernmentbeis-inspect-ai-eval-sets.md`.

## See also

- `ukgovernmentbeis-inspect-ai-datasets.md`, `ukgovernmentbeis-inspect-ai-solvers.md`, `ukgovernmentbeis-inspect-ai-scorers.md` — the three Task components.
- `ukgovernmentbeis-inspect-ai-eval-sets.md` — production multi-task workflow.
- `ukgovernmentbeis-inspect-ai-cli-and-config.md` — full precedence rules between task / `task_with` / env / CLI.

## Source

- `docs/tasks.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/tasks.qmd
- `docs/task-configuration.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/task-configuration.qmd
- `src/inspect_ai/_eval/task/task.py` (`Task` constructor, `task_with`) — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_eval/task/task.py
- `src/inspect_ai/_eval/registry.py` (`@task` decorator) — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_eval/registry.py
- Pinned SHA: `033745ddbc05431c38b015a4b8f2236e956ee9ea`
