---
name: Inspect AI overview, installation, and the "hello world" eval
source_id: ukgovernmentbeis-inspect-ai
---

# What Inspect is

Inspect is an open-source Python framework for large-language-model evaluations, developed by the **UK AI Security Institute** and **Meridian Labs**. It targets frontier-model evals: coding, agentic tasks, reasoning, knowledge, behavior, and multimodal understanding. The framework's value proposition is composable primitives (`Dataset`, `Solver`, `Scorer`) wired together by a `Task`, plus rich infrastructure for tool calling, sandboxing, agent scaffolds, parallel execution, and log analysis. It ships with 200+ pre-built evaluations and a web log viewer ("Inspect View"), and supports running arbitrary external agents (Claude Code, Codex CLI, Gemini CLI) as well as MCP tools.

## Mental model

An evaluation is a `Task` composed of three things plus optional config:

- **Dataset** — produces `Sample` objects with `input` and (optionally) `target`, `choices`, `metadata`, `files`, `sandbox`.
- **Solver(s)** — transforms a `TaskState`; runs the model, applies prompts, chains tools, can be a full agent. Multiple solvers compose into a list (chain).
- **Scorer(s)** — examines the final state, returns a score per sample, aggregated by one or more `metrics`.

The same model API (`inspect_ai.model`) is reused everywhere a model is needed: by the solver under test, by model-graded scorers, by agents internally. Providers are pluggable.

## Install and run "hello world"

```bash
pip install inspect-ai
pip install openai
export OPENAI_API_KEY=...
```

```python
# arc.py
from inspect_ai import Task, task
from inspect_ai.dataset import Sample
from inspect_ai.scorer import exact
from inspect_ai.solver import generate

@task
def hello_world():
    return Task(
        dataset=[Sample(input="Just reply with Hello World", target="Hello World")],
        solver=[generate()],
        scorer=exact(),
    )
```

Run with `inspect eval arc.py --model openai/gpt-4o-mini`. The `--model` argument is provider-prefixed (`openai/`, `anthropic/`, `google/`, `grok/`, `mistral/`, `bedrock/`, `azure/`, `together/`, `groq/`, `cloudflare/`, `goodfire/`, `vllm/`, `hf/`, `ollama/`, `llama-cpp-python/`, `transformerlens/`, `nnterp/`, …) — see [`docs/providers.qmd`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/providers.qmd) for the full list and per-provider options.

Setting `INSPECT_EVAL_MODEL` (e.g. in a `.env` file) lets you omit `--model` on every run. The VS Code extension and the standalone log viewer (`inspect view`) are recommended for any non-trivial work; by default logs land in `./logs` under the working directory.

## Where to go next

- New to Inspect → walk through [`docs/tutorial.qmd`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/tutorial.qmd) (Hello World → Security Guide → HellaSwag → GSM8K → Mathematics → Tool Use → InterCode CTF). It's the canonical onboarding path.
- Want to *run* benchmarks, not build them → the `evals/` listing on the docs site has 200+ ready-made evals at <https://inspect.aisi.org.uk/evals/>.
- Building agentic evals → start at `docs/agents.qmd`, then drill into `react-agent.qmd`, `multi-agent.qmd`, or `agent-bridge.qmd` (for OpenAI Agents SDK / LangChain / Pydantic AI interop).
- Need to extend (new model provider, sandbox runtime, storage backend) → see [`docs/extensions.qmd`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/extensions.qmd).
- Coding agents specifically → upstream publishes a structured index at <https://inspect.aisi.org.uk/llms.txt>, the user guide concatenated as Markdown at `llms-guide.txt`, and the full API+CLI bundle at `llms-full.txt`.

## Sub-package surface area

Re-exports from `inspect_ai` itself (see [`src/inspect_ai/__init__.py`](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/__init__.py)): `eval`, `eval_async`, `eval_retry`, `eval_retry_async`, `eval_set`, `list_tasks`, `score`, `score_async`, `edit_score`, `recompute_metrics`, `Epochs`, `Scanners`, `ScannerConfig`, `Task`, `Tasks`, `TaskInfo`, `task`, `task_with`, `view`.

Other top-level imports users routinely touch:

- `inspect_ai.dataset` — `Sample`, `csv_dataset`, `json_dataset`, `hf_dataset`, `example_dataset`, `FieldSpec`
- `inspect_ai.solver` — `Solver`, `solver`, `chain`, `generate`, `system_message`, `prompt_template`, `chain_of_thought`, `self_critique`, `use_tools`, `multiple_choice`, `TaskState`
- `inspect_ai.scorer` — `Scorer`, `scorer`, `match`, `exact`, `includes`, `pattern`, `answer`, `f1`, `model_graded_qa`, `model_graded_fact`, `choice`, `accuracy`, `mean`, `stderr`, `pass_k`, `AnswerPattern`, `Score`, `Target`, `CORRECT`, `INCORRECT`
- `inspect_ai.model` — `Model`, `get_model`, `ChatMessage*`, `GenerateConfig`, `ModelOutput`
- `inspect_ai.tool` — `tool`, `Tool`, `ToolError`, plus built-in tools (`bash`, `python`, `text_editor`, `web_search`, `web_browser`, `computer`)
- `inspect_ai.agent` — `Agent`, `agent`, `AgentState`, `react`
- `inspect_ai.log` — `EvalLog`, `read_eval_log`, `write_eval_log`, `log_file_info`
- `inspect_ai.analysis` — `evals_df`, `samples_df`, `messages_df` (pandas-based)
- `inspect_ai.hooks` — extension hook registration
- `inspect_ai.util` — `sandbox()`, `subtask`, store, concurrency utilities

## Install and dev workflow notes

`pyproject.toml` ([source](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/pyproject.toml)) declares the package as `inspect_ai`, requires Python ≥ 3.10, and exposes a single console script: `inspect = "inspect_ai._cli.main:main"`. Dependencies are split across `requirements.txt`, `requirements-dev.txt`, `requirements-doc.txt`, and `requirements-dist.txt` and surfaced as the `[dev]`, `[doc]`, and `[dist]` extras.

For contributors:

```bash
git clone https://github.com/UKGovernmentBEIS/inspect_ai.git
cd inspect_ai
pip install -e ".[dev]"
# or, with uv:
uv sync --extra dev
```

`make hooks` installs pre-commit hooks; `make check` and `make test` run lint/format and tests. Under uv prefix with `uv run` (e.g. `uv run make check`). The web UI lives in a submodule at `src/inspect_ai/_view/ts-mono/` and is only needed by frontend contributors. Docs build via `pip install -e ".[doc]"` then `quarto render` / `quarto preview` from `docs/`.

## See also

- `ukgovernmentbeis-inspect-ai-tasks.md` — Task internals and lifecycle.
- `ukgovernmentbeis-inspect-ai-cli-and-config.md` — `inspect eval` flags, `.env`, `INSPECT_EVAL_*` env vars.
- `inspect-aisi-org-uk-docs-portal.md` — the rendered docs portal at inspect.aisi.org.uk.

## Source

- `README.md` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/README.md
- `docs/index.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/index.qmd
- `docs/tutorial.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/tutorial.qmd
- `pyproject.toml` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/pyproject.toml
- `src/inspect_ai/__init__.py` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/__init__.py
- Repo SHA: `033745ddbc05431c38b015a4b8f2236e956ee9ea` (as of 2026-05-26)
