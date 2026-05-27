---
name: Extension points — model APIs, sandboxes, approvers, storage, hooks
source_id: ukgovernmentbeis-inspect-ai
---

# Extensions

Inspect exposes five extension surfaces. Four of them (model APIs, sandboxes, approvers, hooks) register through a **single** setuptools entry-point group named `inspect_ai`; the fifth (filesystems) piggybacks on the standard `fsspec.specs` group instead. The convention is to point the entry point at a `_registry.py` module inside your package — Inspect imports it at startup, which runs the `@modelapi` / `@sandboxenv` / `@approver` / `@hooks` decorators and populates the registry. No Inspect-side configuration is required to discover an installed extension.

| Extension | Base class / decorator | Entry-point group |
|---|---|---|
| Model API | `ModelAPI` + `@modelapi(name=...)` | `inspect_ai` |
| Sandbox runtime | `SandboxEnvironment` + `@sandboxenv(name=...)` | `inspect_ai` |
| Approver | callable returning `Approval` + `@approver` | `inspect_ai` |
| Hooks | `Hooks` subclass + `@hooks(name=..., description=...)` | `inspect_ai` |
| Storage (fsspec filesystem) | fsspec `AbstractFileSystem` subclass | `fsspec.specs` |

The canonical `pyproject.toml` snippet for the first four (single entry pointing at a registry module that imports everything you want registered) is:

```toml
[project.entry-points.inspect_ai]
evaltools = "evaltools._registry"
```

## Model API extensions

Two-file pattern, with a lazy-import indirection so the heavy provider SDK only loads when actually used:

```python
# custom.py
from inspect_ai.model import ModelAPI, GenerateConfig, ModelOutput
from inspect_ai.tool import ToolChoice, ToolInfo
from inspect_ai.model._chat_message import ChatMessage

class CustomModelAPI(ModelAPI):
    def __init__(self, model_name, base_url=None, api_key=None,
                 api_key_vars=[], config=GenerateConfig(), **model_args):
        super().__init__(model_name, base_url, api_key, api_key_vars, config)
        # initialize client...

    async def generate(self, input: list[ChatMessage], tools: list[ToolInfo],
                       tool_choice: ToolChoice, config: GenerateConfig) -> ModelOutput:
        ...
```

```python
# providers.py
from inspect_ai.model import modelapi

@modelapi(name="custom")
def custom():
    from .custom import CustomModelAPI    # lazy import
    return CustomModelAPI
```

After `pip install`, `--model custom/<model-name>` resolves; `<model-name>` is passed through as the `model_name` argument. `generate()` may optionally return `tuple[ModelOutput, ModelCall]` so the raw request/response is recorded in the sample transcript. Several optional properties on `ModelAPI` control default max tokens/connections, rate-limit error detection, and whether consecutive user/assistant messages should be collapsed.

The framework's own provider modules use exactly this pattern — see `src/inspect_ai/model/_providers/providers.py` (https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/model/_providers/providers.py) for the canonical reference implementation across ~25 providers.

## Sandbox extensions

`SandboxEnvironment` is heavier than the other ABCs because it owns container lifecycle. Required class methods cover task/sample init and cleanup; required instance methods cover process exec and file I/O; plus several optional class methods declare Docker compatibility and concurrency hints.

```python
# podman.py
class PodmanSandboxEnvironment(SandboxEnvironment):
    @classmethod
    def config_files(cls) -> list[str]: ...
    @classmethod
    def is_docker_compatible(cls) -> bool: return True
    @classmethod
    def default_concurrency(cls) -> int | None: ...
    @classmethod
    async def task_init(cls, task_name, config) -> None: ...
    @classmethod
    async def sample_init(cls, task_name, config, metadata) -> dict[str, SandboxEnvironment]: ...
    @classmethod
    async def sample_cleanup(cls, task_name, config, environments, interrupted) -> None: ...
    @classmethod
    async def task_cleanup(cls, task_name, config, cleanup) -> None: ...
    @classmethod
    async def cli_cleanup(cls, id: str | None) -> None: ...
    # plus instance methods: exec, read_file, write_file, connection, ...

# providers.py
@sandboxenv(name="podman")
def podman():
    from .podman import PodmanSandboxEnvironment
    return PodmanSandboxEnvironment
```

Key lifecycle rules from `docs/extensions.qmd`:

- `task_init` / `task_cleanup` run once per unique sandbox config across an `eval()` run (shared when multiple tasks have identical configs — a performance optimization).
- `sample_init` returns a dict of sandbox-name → environment; the "default" sandbox **must** be the first key in that dict.
- `sample_cleanup` receives an `interrupted` flag so it can vary behavior when the user hit Ctrl+C mid-sample.
- `task_cleanup` is the safety net for resources `sample_cleanup` couldn't reach; when `cleanup=False` (i.e. `--no-sandbox-cleanup`) it should print container IDs plus instructions for manual teardown.
- `cli_cleanup` backs `inspect sandbox cleanup <provider> [<id>]` — must handle both "all" and single-id forms.
- If `config_files()` lists `compose.yaml`, `is_docker_compatible()` defaults to `True`. Docker-compatible providers may receive a `Dockerfile` path, a `compose.yaml` path, or a `ComposeConfig` instance as `config`; use `is_dockerfile`, `is_compose_yaml`, `parse_compose_yaml`, and `ComposeConfig` from `inspect_ai.util` to discriminate.
- `exec_remote()` is implemented in the base class — do not override. It supports a `user` option that uses `setuid` from the root tools server.

Custom config types may derive from Pydantic's `BaseModel` and must be hashable (`frozen=True`); they're then passed via `SandboxEnvironmentSpec("podman", PodmanSandboxEnvironmentConfig(...))`. Implement `config_deserialize()` if you want such configs to survive a round trip through the eval log.

The reference implementations are `LocalSandboxEnvironment` (https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_sandbox/local.py) and `DockerSandboxEnvironment` (https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_sandbox/docker).

## Approver extensions

An `Approver` is a callable that reviews a tool call and returns an `Approval` with a `decision` of approve / modify / reject / escalate / terminate. Use cases: human-in-the-loop UIs, pattern-based safety policies, log-only approvers that record but don't block.

```python
# approvers.py
from inspect_ai.approval import Approval, ApprovalDecision, Approver, approver
from inspect_ai.tool import ToolCall, ToolCallView
from inspect_ai.model import ChatMessage

@approver
def auto_approver(decision: ApprovalDecision = "approve") -> Approver:
    async def approve(message: str, call: ToolCall, view: ToolCallView,
                      history: list[ChatMessage]) -> Approval:
        return Approval(decision=decision, explanation="Automatic decision.")
    return approve
```

Once the package is installed and registered (via the standard `inspect_ai` entry point pointing at a `_registry.py` that imports `auto_approver`), an approval policy YAML can reference it by `<package>/<approver-name>`:

```yaml
# approval.yaml
approvers:
  - name: evaltools/auto_approver
    tools: "harmless*"
    decision: approve
```

## Storage extensions (fsspec)

Datasets, prompt templates, and eval logs all flow through fsspec. Built-in support: local, S3 (via `s3fs`, bundled), plus anything else fsspec already ships (GCS, Azure Blob, Azure Data Lake, DVC, etc.). For a fully custom backend, implement an fsspec `AbstractFileSystem` and register it under the standard fsspec group:

```toml
[project.entry-points."fsspec.specs"]
myfs = "evaltools:MyFs"
```

Inspect-only filesystems can implement just the subset of fsspec Inspect actually calls: `sep`, `open`, `makedirs`, `info`, `created`, `exists`, `ls`, `walk`, `unstrip_protocol`, `invalidate_cache`. Once installed, `myfs://...` paths work everywhere — `resource()`, `csv_dataset()`, `json_dataset()`, `list_eval_logs()`, `read_eval_log()`, `write_eval_log()`, `retryable_eval_logs()`.

## Hooks

A `Hooks` subclass implements any subset of typed lifecycle methods. Each event receives a single typed data object (e.g. `RunStart`, `RunEnd`, `SampleEnd`, `ApiKeyOverride`); see `src/inspect_ai/hooks/_hooks.py` (https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/hooks/_hooks.py) for the full event list and payload shapes.

```python
import wandb
from inspect_ai.hooks import Hooks, RunEnd, RunStart, SampleEnd, hooks

@hooks(name="w&b_hooks", description="Weights & Biases integration")
class WBHooks(Hooks):
    async def on_run_start(self, data: RunStart) -> None:
        wandb.init(name=data.run_id)

    async def on_run_end(self, data: RunEnd) -> None:
        wandb.finish()

    async def on_sample_end(self, data: SampleEnd) -> None:
        if data.sample.scores:
            scores = {k: v.value for k, v in data.sample.scores.items()}
            wandb.log({"sample_id": data.sample_id, "scores": scores})
```

Two operational controls worth knowing:

- **`enabled()`** — instance method on the Hooks class. Return `False` to opt out at runtime; common pattern is gating on an env var like `WANDB_API_KEY`.
- **`INSPECT_REQUIRED_HOOKS`** — env var listing hook names that must be loaded; startup fails loudly if any are missing. Useful for enforced telemetry in shared environments.

Hooks also support the same factory-of-class indirection as model providers (decorate a function that lazy-imports and returns the Hooks subclass) so a hook package doesn't transitively pull in `wandb`, `mlflow`, etc.

### API key override hook

The `override_api_key(data: ApiKeyOverride) -> str | None` method runs during model initialization and again whenever an auth error is detected. Returning a string substitutes that value for the env-var-derived API key. Intended uses: pull keys from a secrets manager at runtime, refresh tokens during long evals, or front model APIs with a reverse proxy whose credentials Inspect should never see directly.

```python
@hooks(name="api_key_fetcher", description="Fetches API key from secrets manager")
class ApiKeyFetcher(Hooks):
    def override_api_key(self, data: ApiKeyOverride) -> str | None:
        if data.value.startswith("arn:aws:secretsmanager:"):
            return fetch_aws_secret(data.value)
        return None
```

Reference hook implementations live in `examples/hooks/` upstream — `wandb_weave.py`, `mlflow_tracking.py`, `mlflow_tracing.py`.

## Why this matters

Inspect is intentionally thin in the core: the framework owns the eval lifecycle, but model providers, sandboxes, approvers, storage backends, and observability are all replaceable via sibling packages a user pip-installs. This is why the supported-provider list is so long without bloating the base install — every "built-in" provider is just a `@modelapi`-decorated factory inside `_providers/providers.py`, and the same registry mechanism is open to external packages on identical terms.

## See also

- `ukgovernmentbeis-inspect-ai-models-and-providers.md` — the built-in providers that ride this same extension API.
- `ukgovernmentbeis-inspect-ai-sandboxing.md` — sandbox runtimes that ride `@sandboxenv`.
- `ukgovernmentbeis-inspect-ai-logs-and-analysis.md` — log format that storage extensions persist.

## Source

- `docs/extensions.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/extensions.qmd
- `src/inspect_ai/model/_providers/providers.py` — canonical multi-provider extension example: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/model/_providers/providers.py
- `src/inspect_ai/hooks/` — hook system implementation: https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/hooks
- `src/inspect_ai/approval/` — approver registry and policy engine: https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/approval
- `src/inspect_ai/util/_sandbox/` — sandbox base class and built-in providers: https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_sandbox
- `src/inspect_ai/_util/registry.py` — central registry machinery shared by all extension kinds: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_util/registry.py
- Pinned SHA: `033745ddbc05431c38b015a4b8f2236e956ee9ea`
