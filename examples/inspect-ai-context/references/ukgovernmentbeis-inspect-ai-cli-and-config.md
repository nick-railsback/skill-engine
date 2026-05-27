---
name: CLI, options, environment variables, and .env files
source_id: ukgovernmentbeis-inspect-ai
---

# The `inspect` CLI

Subcommands registered in `_cli/main.py` (Click group, auto-envvar prefix `INSPECT`):

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

Reference docs for every subcommand live under `/reference/inspect_*.html` on the docs site.

## `inspect acp` (Agent Client Protocol)

Two modes from one entry point (`_cli/acp.py`):

- Bare `inspect acp` launches Inspect's native Textual TUI client.
- `inspect acp --stdio` runs a transparent stdio↔socket bridge that editors (Zed etc.) spawn as a subprocess and drive over newline-delimited JSON-RPC.

Targeting flags (shared by both modes):

| Flag | Behavior |
|---|---|
| `--eval-id` | Pick a specific eval from the local discovery directory. |
| `--server` | Direct ACP server address (`host:port` or UNIX socket path), bypassing discovery. Mutually exclusive with `--eval-id`. Use for remote attach. |
| `--task-id`, `--sample-id`, `--epoch` | Direct-attach filters. In TUI mode any combination narrows the picker. In `--stdio` mode all three must be set together (or none) to uniquely identify one session for the bridge. |

The matching server-side flag is `--acp-server` on `inspect eval` / `inspect eval-set` (see below).

## Configuration precedence

For any given option, the resolution order (later wins):

1. Built-in default.
2. `Task(...)` argument.
3. Environment variable (`INSPECT_EVAL_*`, plus provider-specific vars).
4. `.env` file in the working directory or any ancestor.
5. `--run-config <file>` value (YAML/JSON with the full run config).
6. CLI flag.
7. Explicit `eval(...)` kwarg.

When `--run-config` is set, env-sourced CLI values (`INSPECT_EVAL_*`) defer to the file so the file remains the single source of truth for that run; explicit CLI flags still win on top.

For a campaign, the right shape is: project defaults in `.env`, per-run tweaks on the CLI, never hard-code things in the `Task` definition unless they're truly intrinsic to the task.

## `.env` files

Inspect reads `.env` automatically from the cwd, walking up parent directories (handled by `init_dotenv()` in `_cli/main.py`). Use it for:

- Provider keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`, etc.).
- Default model: `INSPECT_EVAL_MODEL=anthropic/claude-sonnet-4-0`.
- Log location and verbosity: `INSPECT_LOG_DIR=./logs`, `INSPECT_LOG_LEVEL=warning`.
- Concurrency: `INSPECT_EVAL_MAX_CONNECTIONS=20`, `INSPECT_EVAL_MAX_RETRIES=5`.

Relative paths in `.env` (e.g., `INSPECT_LOG_DIR=./logs`) resolve relative to the `.env` file's location, not the cwd — so running from a subdirectory still writes to the project-anchored logs dir.

**Never check `.env` into git.** Provide an `.env.example` with keys-only.

## CLI ↔ env var ↔ kwarg mapping

Most CLI flags map by prefix and kebab-case. The full mapping table is in `options.qmd`; representative entries:

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

For arbitrary provider-specific model arguments, the `-M key=value` flag passes through:

```bash
inspect eval arc.py --model openai/gpt-4o-mini -M responses_api=true
```

## ACP server flag on eval / eval-set

`--acp-server` exposes a running eval to ACP clients (the `inspect acp` TUI, editor bridges, remote attach). It's a flexible flag-or-value option:

| Form | Effect |
|---|---|
| `--acp-server` (bare) | Bind a default AF_UNIX socket; clients discover it via the local discovery directory. |
| `--acp-server=4444` | Bind TCP loopback on the given port. |
| `--acp-server=0.0.0.0:4444` | Bind TCP on a specific interface (use for remote attach). |
| `--acp-server=/path/to.sock` | Bind a custom UNIX socket path. |

Env var: `INSPECT_EVAL_ACP_SERVER`. Available on both `inspect eval` and `inspect eval-set`.

## Run configuration files

`--run-config <file>` loads task/model/model-roles/generate-config/solver/eval-config from a single YAML or JSON file. Explicit CLI flags override values from the file; env-sourced values defer to it.

Cannot be combined with `--generate-config`, `--task-config`, or `--solver-config` (these overlap with sections of the run config). Only supported on `inspect eval`, not `inspect eval-set`.

Pair with `inspect log export-config <log>` to extract the config of an existing run and replay it deterministically.

## Task parameters

Pass per-task parameters with `-T key=value`. The task function's kwargs receive them with appropriate type coercion (str, int, float, bool, list via comma-split).

```bash
inspect eval arithmetic.py -T operator=* -T max_digits=4
```

These get recorded in the eval log so the parameter set is part of the reproducibility artifact.

## Limiting / filtering samples

| Flag | Behavior |
|---|---|
| `--limit N` or `--limit 10-20` | First N samples or a range. |
| `--sample-id 1,3,7` | Specific sample ids. |
| `--sample-shuffle` (bare) | Shuffle with a random seed. |
| `--sample-shuffle=<int>` | Shuffle with a deterministic seed. |

## Logging verbosity

| Env var | Effect |
|---|---|
| `INSPECT_LOG_LEVEL` | `debug` / `trace` / `http` / `info` / `warning` / `error` / `critical`. |
| `INSPECT_LOG_LEVEL_TRANSCRIPT` | Logger level for the eval-log transcript (defaults to `info`). |
| `INSPECT_PY_LOGGER_FORMAT` | `rich` / `plain` / `json` — last two are non-TTY-friendly single-line outputs, useful in CI. |

## See also

- `ukgovernmentbeis-inspect-ai-tasks.md` — `-T` task parameter handling.
- `ukgovernmentbeis-inspect-ai-eval-sets.md` — `--log-dir` discipline for resumable runs.
- `ukgovernmentbeis-inspect-ai-models-and-providers.md` — provider-specific env vars and `-M` model args.

## Source

- `docs/options.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/options.qmd
- `docs/vscode.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/vscode.qmd
- `src/inspect_ai/_cli/` — https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli
- `src/inspect_ai/_cli/main.py` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/main.py
- `src/inspect_ai/_cli/eval.py` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py
- `src/inspect_ai/_cli/acp.py` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/acp.py
- Repo SHA: `033745ddbc05431c38b015a4b8f2236e956ee9ea`
