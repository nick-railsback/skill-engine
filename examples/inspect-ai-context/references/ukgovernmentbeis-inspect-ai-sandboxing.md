# Sandboxing

By default, model tool calls execute in the same process as the evaluation. That is fine for read-only tools but dangerous when a tool runs arbitrary code (`bash()`, `python()`, `text_editor()`, `web_browser()`) or when you need per-sample filesystem state or a network topology (e.g., a CTF target host). Sandboxes provision dedicated environments — containers or VMs — that the `sandbox()` callable inside a tool routes its `exec`, `read_file`, `write_file`, and `connection` calls into. Built-in support exists for `local` (no isolation) and `docker`; everything else is a pip-installable extension.
https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/sandboxing.qmd#L6-L17

## Declaring a sandbox

Bind at three levels — precedence is `eval()` > `Task` > `Sample`, except that a `Sample`-supplied config file wins when the sandbox **type** matches the enclosing scope.
https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/sandboxing.qmd#L90-L107

```python
# Task-level: every sample uses this sandbox
Task(sandbox="docker")
Task(sandbox=("docker", "compose.yaml"))          # explicit compose path

# Sample-level override (per-sample Dockerfile/compose)
Sample(input=..., sandbox=("docker", "challenge1-compose.yaml"))

# Fully programmatic, including per-sample image selection
from inspect_ai.util import ComposeConfig, ComposeService, SandboxEnvironmentSpec
spec = SandboxEnvironmentSpec("docker", ComposeConfig(services={
    "default": ComposeService(image="python:3.12-bookworm", init=True,
                              command="tail -f /dev/null", cpus=1.0,
                              mem_limit="512m", network_mode="none")
}))
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/sandboxing.qmd#L128-L156 · https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_sandbox/environment.py#L493-L510 · https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_sandbox/compose.py#L214-L330

Each sample gets its own sandbox **instance** even when the sandbox is declared at task level, so samples never share state. If no Dockerfile or `compose.yaml` is present in the task directory, Inspect synthesizes a compose file off the standard `aisiuk/inspect-tool-support` image and (importantly) disables internet by default — supply your own compose file if you need network.
https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/sandboxing.qmd#L189-L215

## Built-in runtimes

| Type | Package | Dockerfile-compatible | Notes |
|---|---|---|---|
| `local` | built-in | n/a | No isolation. Cheap, unsafe for untrusted code. |
| `docker` | built-in | yes | Per-sample container or compose stack. |
| `k8s` | `inspect-k8s-sandbox` | yes | Kubernetes pods, CTF-grade isolation. |
| `daytona` | `inspect-sandboxes` | yes | Daytona-hosted. |
| `modal` | `inspect-sandboxes` | yes | Modal-hosted. |
| `ec2` | `inspect_ec2_sandbox` | no | AWS EC2 VMs. |
| `proxmox` | `inspect_proxmox_sandbox` | no | Proxmox VMs. |

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/sandboxing.qmd#L189-L228

All non-built-ins register through the same sandbox-environment extension API used everywhere else in Inspect.
https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_sandbox/environment.py#L92-L105

## Compose patterns

A multi-service compose lets you build CTF-style scenarios (attacker host + victim host on a private network), tool-use evals with auxiliary services (e.g., a writer container seeding a shared volume), and resource-bounded targets:
https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/sandboxing.qmd#L258-L340

```yaml
services:
  default:
    image: ctf-agent-environment
    x-local: true                  # don't try to pull from a registry
    init: true                     # respond to SIGTERM
    command: tail -f /dev/null     # keep the container alive
    cpus: 1.0
    mem_limit: 0.5gb
    network_mode: none
  victim:
    image: ctf-victim-environment
    x-local: true
    init: true
volumes:
  ctf-challenge-volume:
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/sandboxing.qmd#L258-L295

Default-service selection: a service literally named `default`, else any service with `x-default: true`, else the first service. `sandbox()` returns the default; `sandbox("victim")` returns a named one. Use `with sandbox_default("victim"):` to redirect tools that always hit the default within a block.
https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/sandboxing.qmd#L286-L302 · https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_sandbox/context.py#L382-L400

Sample metadata is interpolated via `SAMPLE_METADATA_<KEY>` — provide a default with the `${SAMPLE_METADATA_FOO-fallback}` form because compose files are also read **without** sample context (image pull at startup):
https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/sandboxing.qmd#L326-L340

```yaml
mem_limit: ${SAMPLE_METADATA_MEMORY_LIMIT-0.5gb}
```

## The `sandbox()` callable

```python
from inspect_ai.util import sandbox

result  = await sandbox().exec(["ls", dir])             # ExecResult[str]
content = await sandbox().read_file("/path")            # str (or bytes with text=False)
await sandbox().write_file("/path", "data")             # creates parent dirs
conn    = await sandbox().connection()                  # SandboxConnection (for SSH-like login)
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_sandbox/context.py#L41-L69

Full method surface (from `SandboxEnvironment`): `exec(cmd, input=None, cwd=None, env={}, user=None, timeout=None, timeout_retry=True, concurrency=True) -> ExecResult[str]`; `exec_remote(cmd, options=None, *, stream=True)` for streaming or long-running remote processes; `read_file(file, text=True)` raising `FileNotFoundError`, `PermissionError`, `IsADirectoryError`, `UnicodeDecodeError`, `OutputLimitExceededError`; `write_file(file, contents)`; `connection(*, user=None)` (optional; raises `NotImplementedError` where unsupported). Default size caps: 100 MiB per `read_file`, 10 MiB per `exec` output (front-truncated). Tune via `INSPECT_SANDBOX_MAX_READ_FILE_SIZE` and `INSPECT_SANDBOX_MAX_EXEC_OUTPUT_SIZE`. `exec()`'s `timeout_retry` is **advisory** — implementations cap at 2 retries under 60s each; set `False` for non-idempotent commands. Documented errors are reported back to the model; undocumented errors fail the sample.
https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_sandbox/environment.py#L105-L260 · https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_sandbox/limits.py#L1-L55

## File seeding and setup

`Sample.files: dict[str, str]` copies files into the default sandbox before the solver runs; values may be inline content, a path, or a base64 data URL. Prefix the key with a service name to target a non-default sandbox (e.g., `"victim:flag.txt": "flag.txt"`). `Sample.setup` runs a bash script in the default sandbox after files are seeded — useful for installing deps or fetching challenge artifacts. See `ukgovernmentbeis-inspect-ai-datasets.md` for `Sample` field semantics.
https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/sandboxing.qmd#L169-L188

## Resource and cleanup management

Container CPU/memory caps go in compose under `cpus` / `mem_limit` (or `deploy.resources.limits` for swarm-style). Concurrency is governed by `max_sandboxes` (default `2 * os.cpu_count()` for Docker; setting it effectively caps `max_samples` to the same number) and `max_subprocesses` (default `os.cpu_count()`). Cleanup is automatic at task end; if a run is interrupted, recover with `inspect sandbox cleanup docker [container-id]`. Pass `--no-sandbox-cleanup` (CLI) or `sandbox_cleanup=False` (`eval()`) to keep containers around for `docker exec -it <id> bash -l` debugging. Diagnose stuck commands or container lifecycle issues with `inspect trace anomalies`.
https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/sandboxing.qmd#L340-L400 · https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_sandbox/environment.py#L340-L360

# Tool approval (policy gate)

Approval is a **pre-execution** filter independent of sandboxing — denials mean the tool never runs. Policies live at the eval level (`--approval`, `approval=` to `eval()`) or task level (`Task(approval=...)`); eval-level wins. A policy is an ordered chain of `ApprovalPolicy(approver, tool_glob_or_list)` entries; the first matching approver handles the call. Globs are **prefix-matched**, so `web_browser_type` also catches `web_browser_type_submit`. You can also match on arguments — `computer(action='key'` matches any `computer` call whose `action` argument begins with `key`.
https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/approval.qmd#L6-L70 · https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/approval/_policy.py#L22-L80

Five decisions: `approve`, `modify` (rewrite the call via the `modified` field), `reject` (reported to the model), `escalate` (fall through to the next approver), `terminate` (end the sample).
https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/approval/_approval.py#L1-L32

```python
from inspect_ai.approval import ApprovalPolicy, human_approver, auto_approver

approval = [
    ApprovalPolicy(human_approver(), ["web_browser_click", "web_browser_type*"]),
    ApprovalPolicy(auto_approver(), "*"),
]
eval("browser.py", approval=approval, trace=True)
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/approval.qmd#L70-L84 · https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/approval/_human/approver.py#L13-L53 · https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/approval/_auto.py#L9-L28

Equivalent YAML (loaded via `--approval approval.yaml`):

```yaml
approvers:
  - name: human
    tools: ["web_browser_click", "web_browser_type"]
  - name: auto
    tools: "*"
```

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/approval.qmd#L28-L69 · https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/approval/_policy.py#L86-L132

The `approval()` async context manager temporarily replaces policies for a code section (nesting restores correctly). `execute_tools(..., approval=...)` and `react(..., approval=...)` accept the same list for scoped overrides.
https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/approval.qmd#L113-L153

Custom approvers register via the `@approver` decorator and are published as Inspect extensions (same setuptools entry-point pattern as model providers — see `ukgovernmentbeis-inspect-ai-extensions.md`). A custom approver signature is `async def approve(message, call: ToolCall, view: ToolCallView, history: list[ChatMessage]) -> Approval`. Once registered (e.g., as `evaltools/bash_allowlist`) it slots into a chain like any built-in.
https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/approval.qmd#L154-L233 · https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/approval/_registry.py#L19-L101 · https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/approval/_approver.py#L9-L31

## Tool views

For human approval prompts, tools can supply a `ToolCallViewer` (passed to `@tool(viewer=...)`) that returns a `ToolCallView` with `context` (state snippet, e.g., web-browser page excerpt) and/or `call` (alternate rendering, e.g., a syntax-highlighted bash code block instead of a single-line string). This is purely presentational — it does not affect what gets executed.
https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/approval.qmd#L234-L275 · https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/tool/_tool_call.py#L25-L93

## See also

- `ukgovernmentbeis-inspect-ai-tools.md` — `sandbox()` callable usage inside custom tools.
- `ukgovernmentbeis-inspect-ai-datasets.md` — `Sample.sandbox`, `Sample.files`, `Sample.setup` semantics.
- `ukgovernmentbeis-inspect-ai-extensions.md` — registering new sandbox runtimes and approvers.

## Source

- `docs/sandboxing.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/sandboxing.qmd
- `docs/approval.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/approval.qmd
- `docs/_sandboxenv-interface.md` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/_sandboxenv-interface.md
- `docs/_container_limits.md` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/_container_limits.md
- `src/inspect_ai/util/_sandbox/` — https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/util/_sandbox
- `src/inspect_ai/approval/` — https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/approval
- Pinned SHA: `033745ddbc05431c38b015a4b8f2236e956ee9ea`
