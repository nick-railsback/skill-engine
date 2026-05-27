---
name: Solvers — elicitation strategies, chains, and the TaskState transform
source_id: ukgovernmentbeis-inspect-ai
---

# Solvers

A solver is `async def solve(state: TaskState, generate: Generate) -> TaskState`. It mutates and returns a `TaskState` that carries `messages`, `output`, `tools`, `tool_choice`, `metadata`, `store`, `scores`, and a `completed` flag. Solvers wrap that callable in an `@solver` decorator so they get a registry entry, parameter recording for reproducibility, and the option to short-circuit a chain when `state.completed` is set.

Solvers play two roles: they are **components** (small pieces chained together) and they are **composite plans** (a `@solver` function that internally calls `chain(...)` of other solvers). The same primitive serves both — a chain is just a solver. A `Task` accepts either a single solver or a list of solvers as its `solver=` argument.

## Built-in components

All exported from `inspect_ai.solver` (see the package `__init__.py` for the full list):

- `generate()` — the default solver. Equivalent to `return await generate(state)`. Calls the model with current `state.messages`, appends the assistant message, and sets `state.output`.
- `system_message(message, **params)` — prepend a `role="system"` message (placed after any pre-existing system messages). Substitutes variables from sample `metadata`, `store`, and `params`.
- `user_message(message, **params)` / `assistant_message(message, **params)` — append a user or assistant message with the same templating behavior.
- `prompt_template(template, **params)` — format `state.user_prompt.text` through a template that may reference `{prompt}` plus any sample `metadata` keys and custom `params`.
- `chain_of_thought()` — standard CoT template with `{prompt}` substitution; instructs the model to put its final answer on a line by itself for easier scoring.
- `self_critique(critique_template=None, completion_template=None, model=None)` — calls a (possibly different) model to critique `state.output.completion`, replays the critique as a user message, then re-calls `generate`.
- `multiple_choice(*, template=None, cot=False, multiple_correct=False)` — formats `state.choices` as A/B/C/D and elicits a letter answer. Calls `generate()` internally — do not chain a separate `generate()` after it. Pair with the `choice()` scorer. `Sample.target` must be a capital letter (or a list of letters when `multiple_correct=True`); `Sample.choices` must omit the leading letter labels.
- `use_tools(*tools, tool_choice=...)` — populate `state.tools` and `state.tool_choice` so subsequent `generate()` calls expose those tools to the model.
- `basic_agent(...)`, `human_agent(...)`, `bridge(...)` — agent-shaped solvers; prefer the newer `inspect_ai.agent.Agent` interface (see `ukgovernmentbeis-inspect-ai-agents.md`).

## Chains

```python
from inspect_ai.solver import chain, generate, system_message, prompt_template, self_critique

theory = chain(
    system_message("system.txt"),
    prompt_template("prompt.txt"),
    generate(),
    self_critique(),
)
```

Pass `theory` to `Task(solver=theory)` or pass the list directly: `Task(solver=[system_message(...), prompt_template(...), generate(), self_critique()])` — both forms are equivalent.

## Composite solvers — `@solver`

Wrap a chain in a function decorated with `@solver` for reuse and parameter recording:

```python
@solver
def critique(system_prompt="system.txt", user_prompt="prompt.txt"):
    return chain(
        system_message(system_prompt),
        prompt_template(user_prompt),
        generate(),
        self_critique(),
    )
```

The decorator registers the solver and records the kwargs so reruns from a log can re-create the solver exactly. Argument values should be JSON-serializable for log fidelity, and the decorator also makes the solver addressable by name from config files (e.g. YAML eval specs).

## Custom solvers — writing your own

When built-ins don't compose into the elicitation you need, write the async function directly. A `@solver` is a factory that returns the `solve` coroutine:

```python
@solver
def my_solver(retries: int = 3):
    async def solve(state: TaskState, generate: Generate) -> TaskState:
        for _ in range(retries):
            state = await generate(state)
            if "answer" in state.output.completion.lower():
                return state
        state.completed = True
        return state
    return solve
```

The `generate` argument is bound to the task's model, tools, and config — call it rather than reaching for `get_model()` if you want the standard plumbing. Use `get_model()` (or `get_model("provider/name")`) when you specifically need a *different* model, e.g. a separate critique model. Always `await` model calls so the solver participates in Inspect's concurrency scheduling.

## TaskState

`TaskState` is the data structure every solver mutates. The fields solvers most commonly read or write:

- `messages: list[ChatMessage]` — canonical conversation; appended to by `generate()` and manipulated by prompt-engineering solvers.
- `user_prompt: ChatMessageUser` — convenience accessor for the first user message (skips system messages).
- `output: ModelOutput` — last model response; set by `generate()`.
- `input` / `input_text` — the *original* `Sample` input, preserved even if other solvers rewrite `messages`.
- `tools: list[Tool]` and `tool_choice: ToolChoice` — typically set by `use_tools(...)` but may be edited directly.
- `metadata: dict` and `store` — per-sample metadata and a mutable cross-solver dict for coordination.
- `choices: list[str] | None` — multiple-choice options.
- `sample_id`, `epoch`, `model` — contextual identifiers.
- `target: Target` and `scores: dict[str, Score]` — used when a solver wants to score in-line (combined with the task's regular scorers).
- `completed: bool` — set to `True` to short-circuit remaining solvers in the chain. Also flipped automatically when `message_limit`, `token_limit`, or other sample limits are hit.

## Intermediate scoring

A solver can invoke the task's scorers mid-chain to branch on a score:

```python
from inspect_ai.scorer import score

async def solve(state, generate):
    scores = await score(state)  # returns list[Score]
    return state
```

## Solver vs. agent

Solvers and agents both transform conversation state, but agents (`inspect_ai.agent.Agent`) use a narrower interface and are designed to be reused across roles: as a top-level solver, as a tool exposed to another agent, or as a sub-task in a multi-agent system. If a chain only fits one task, write a solver. If you want it to plug into multiple harnesses, write an agent. See `ukgovernmentbeis-inspect-ai-agents.md`.

## See also

- `ukgovernmentbeis-inspect-ai-tools.md` — `use_tools(...)` and tool-calling loops.
- `ukgovernmentbeis-inspect-ai-agents.md` — when to graduate from solvers to agents.
- `ukgovernmentbeis-inspect-ai-models-and-providers.md` — the `Model` and `GenerateConfig` that `generate()` calls under the hood.

## Source

- Solvers guide: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/solvers.qmd
- Solver package (exports, `chain`, `@solver`, `TaskState`): https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/solver
- `Solver` / `Generate` / `generate()` / `@solver`: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/solver/_solver.py
- `TaskState`: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/solver/_task_state.py
- `chain`: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/solver/_chain.py
- Prompt solvers (`system_message`, `user_message`, `assistant_message`, `prompt_template`, `chain_of_thought`): https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/solver/_prompt.py
- `self_critique`: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/solver/_critique.py
- `multiple_choice` / `MultipleChoiceTemplate`: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/solver/_multiple_choice.py
- `use_tools`: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/solver/_use_tools.py
- Pinned SHA: `033745ddbc05431c38b015a4b8f2236e956ee9ea`
