---
name: ukgovernmentbeis-inspect-ai-cli-and-config
description: "Complete reference for the `inspect` CLI: every subcommand registered in `_cli/main.py`, the full configuration-precedence chain (built-in default → Task arg → env var → .env file → --run-config → CLI flag → eval() kwarg), INSPECT_* environment variables, .env file loading semantics, and the -T/-M/-S task/model/solver argument shortcuts."
---

# The `inspect` CLI

Subcommands are registered in `_cli/main.py` via `inspect.add_command(...)` calls at lines 42–54. The Click group is invoked with `auto_envvar_prefix="INSPECT"` (line 60), so every option automatically gains an `INSPECT_*` environment-variable alias. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/main.py#L42-L60

| Command | Purpose |
|---|---|
| `inspect eval` | Run one task. |
| `inspect eval-set` | Run a suite, with resume + retry. |
| `inspect eval-retry` | Re-run only the failed samples from a prior log. |
| `inspect view` | Start the log viewer web UI. |
| `inspect acp` | Connect to a running eval over the Agent Client Protocol (TUI by default; `--stdio` runs an editor bridge for Zed etc.). |
| `inspect log <subcmd>` | Read/convert/dump/export logs. Subcommands: `list`, `dump`, `headers`, `schema`, `convert`, `export-config`. |
| `inspect cache <subcmd>` | Manage local model cache. |
| `inspect sandbox <subcmd>` | Sandbox runtime utilities. |
| `inspect trace`, `inspect score`, `inspect info`, `inspect list`, `inspect download` | Tracing, post-hoc scoring, registry inspection, task listing, dataset download. |

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/main.py#L42-L54

Reference docs for every subcommand live under `/reference/inspect_*.html` on the docs site.

## `inspect acp` (Agent Client Protocol)

Two modes are implemented from a single Click group entry point in `_cli/acp.py` (lines 36–96). Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/acp.py#L36-L96

- Bare `inspect acp` launches Inspect's native Textual TUI client.
- `inspect acp --stdio` runs a transparent stdio↔socket bridge that editors (Zed etc.) spawn as a subprocess and drive over newline-delimited JSON-RPC.

Targeting flags (shared by both modes):

| Flag | Behavior |
|---|---|
| `--eval-id` | Pick a specific eval from the local discovery directory. |
| `--server` | Direct ACP server address (`host:port` or UNIX socket path), bypassing discovery. Mutually exclusive with `--eval-id`. Use for remote attach. |
| `--task-id`, `--sample-id`, `--epoch` | Direct-attach filters. In TUI mode any combination narrows the picker. In `--stdio` mode all three must be set together (or none) to uniquely identify one session for the bridge. |

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/acp.py#L43-L85

The matching server-side flag is `--acp-server` on `inspect eval` / `inspect eval-set` (see below). Its Click option declaration is at `_cli/eval.py` lines 365–379. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py#L365-L379

## Configuration precedence

For any given option, the resolution order (later wins):

1. Built-in default.
2. `Task(...)` argument.
3. Environment variable (`INSPECT_EVAL_*`, plus provider-specific vars).
4. `.env` file in the working directory or any ancestor.
5. `--run-config <file>` value (YAML/JSON with the full run config).
6. CLI flag.
7. Explicit `eval(...)` kwarg.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/options.qmd#L44-L57

When `--run-config` is set, env-sourced CLI values (`INSPECT_EVAL_*`) defer to the file so the file remains the single source of truth for that run; explicit CLI flags still win on top. This deferral logic lives in `eval_command` at lines 838–874 of `_cli/eval.py`. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py#L838-L874

For a campaign, the right shape is: project defaults in `.env`, per-run tweaks on the CLI, never hard-code things in the `Task` definition unless they're truly intrinsic to the task. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/options.qmd#L7-L15

## `.env` files

Inspect reads `.env` automatically from the cwd, walking up parent directories. This is triggered by `init_dotenv()` called inside `main()` at line 59 of `_cli/main.py`, before Click dispatches to any subcommand. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/main.py#L57-L60

Use `.env` for:

- Provider keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, etc.).
- Default model: `INSPECT_EVAL_MODEL=anthropic/claude-sonnet-4-0`.
- Log location and verbosity: `INSPECT_LOG_DIR=./logs`, `INSPECT_LOG_LEVEL=warning`.
- Concurrency: `INSPECT_EVAL_MAX_CONNECTIONS=20`, `INSPECT_EVAL_MAX_RETRIES=5`.

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/options.qmd#L17-L43

Relative paths in `.env` (e.g., `INSPECT_LOG_DIR=./logs`) resolve relative to the `.env` file's location, not the cwd — so running from a subdirectory still writes to the project-anchored logs dir. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/options.qmd#L38-L42

**Never check `.env` into git.** Provide an `.env.example` with keys-only. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/options.qmd#L40-L43

## CLI ↔ env var ↔ kwarg mapping

Most CLI flags map by prefix and kebab-case. The full mapping table is in `options.qmd`; representative entries: Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/options.qmd#L44-L57

| CLI | `eval()` kwarg | Env var |
|---|---|---|
| `--model` | `model` | `INSPECT_EVAL_MODEL` |
| `--limit` | `limit` | `INSPECT_EVAL_LIMIT` |
| `--epochs` | `epochs` | `INSPECT_EVAL_EPOCHS` |
| `--temperature` | (in `GenerateConfig`) | `INSPECT_EVAL_TEMPERATURE` |
| `--max-connections` | `max_connections` | `INSPECT_EVAL_MAX_CONNECTIONS` |
| `--log-dir` | `log_dir` | `INSPECT_LOG_DIR` |
| `--sample-id` | `sample_id` | `INSPECT_EVAL_SAMPLE_ID` |
| `--sample-shuffle` | `sample_shuffle` | `INSPECT_EVAL_SAMPLE_SHUFFLE` |
| `--run-config` | `run_config` | `INSPECT_EVAL_RUN_CONFIG` |
| `--acp-server` | `acp_server` | `INSPECT_EVAL_ACP_SERVER` |

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py#L244-L400

For arbitrary provider-specific model arguments, the `-M key=value` flag passes through (defined at `eval.py` lines 257–261, `envvar="INSPECT_EVAL_MODEL_ARGS"`): Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py#L257-L261

```bash
inspect eval arc.py --model openai/gpt-4o-mini -M responses_api=true
```

## ACP server flag on eval / eval-set

`--acp-server` exposes a running eval to ACP clients (the `inspect acp` TUI, editor bridges, remote attach). It's a flexible flag-or-value option (declared at `eval.py` lines 365–379): Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py#L365-L379

| Form | Effect |
|---|---|
| `--acp-server` (bare) | Bind a default AF_UNIX socket; clients discover it via the local discovery directory. |
| `--acp-server=4444` | Bind TCP loopback on the given port. |
| `--acp-server=0.0.0.0:4444` | Bind TCP on a specific interface (use for remote attach). |
| `--acp-server=/path/to.sock` | Bind a custom UNIX socket path. |

Env var: `INSPECT_EVAL_ACP_SERVER`. Available on both `inspect eval` and `inspect eval-set`. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py#L365-L379

## Run configuration files

`--run-config <file>` loads task/model/model-roles/generate-config/solver/eval-config from a single YAML or JSON file. The `RunConfigInput` Pydantic model that parses it is defined at `eval.py` lines 1356–1457. Explicit CLI flags override values from the file; env-sourced values defer to it. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py#L1356-L1457

Cannot be combined with `--generate-config`, `--task-config`, or `--solver-config` (these overlap with sections of the run config). Only supported on `inspect eval`, not `inspect eval-set`. The mutual-exclusion check is at `eval.py` lines 1584–1591. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py#L1584-L1591

Pair with `inspect log export-config <log>` to extract the config of an existing run and replay it deterministically. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/options.qmd#L59-L63

## Task parameters

Pass per-task parameters with `-T key=value`. The Click option for `-T` is defined at `eval.py` lines 283–288 with `envvar="INSPECT_EVAL_TASK_ARGS"`; the task function's kwargs receive them with appropriate type coercion (str, int, float, bool, list via comma-split). Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py#L283-L293

```bash
inspect eval arithmetic.py -T operator=* -T max_digits=4
```

These get recorded in the eval log so the parameter set is part of the reproducibility artifact. Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/options.qmd#L108-L117

## Limiting / filtering samples

| Flag | Behavior |
|---|---|
| `--limit N` or `--limit 10-20` | First N samples or a range. |
| `--sample-id 1,3,7` | Specific sample ids. |
| `--sample-shuffle` (bare) | Shuffle with a random seed. |
| `--sample-shuffle=<int>` | Shuffle with a deterministic seed. |

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py#L381-L400

## Logging verbosity

| Env var | Effect |
|---|---|
| `INSPECT_LOG_LEVEL` | `debug` / `trace` / `http` / `info` / `warning` / `error` / `critical`. |
| `INSPECT_LOG_LEVEL_TRANSCRIPT` | Logger level for the eval-log transcript (defaults to `info`). |
| `INSPECT_PY_LOGGER_FORMAT` | `rich` / `plain` / `json` — last two are non-TTY-friendly single-line outputs, useful in CI. |

Source (log-level option): https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/common.py#L32-L47
Source (log-level-transcript option): https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py#L814-L823
Source (options.qmd table): https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/options.qmd#L156-L168

## See also

- `ukgovernmentbeis-inspect-ai-tasks.md` — `-T` task parameter handling.
- `ukgovernmentbeis-inspect-ai-eval-sets.md` — `--log-dir` discipline for resumable runs.
- `ukgovernmentbeis-inspect-ai-models-and-providers.md` — provider-specific env vars and `-M` model args.

## Source

- `docs/options.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/options.qmd
- `src/inspect_ai/_cli/` — https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli
- `src/inspect_ai/_cli/main.py` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/main.py
- `src/inspect_ai/_cli/eval.py` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py
- `src/inspect_ai/_cli/acp.py` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/acp.py
- `src/inspect_ai/_cli/common.py` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/common.py
- Repo SHA: `033745ddbc05431c38b015a4b8f2236e956ee9ea`
