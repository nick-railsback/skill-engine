# The auto-generated CLI reference

The portal's `/reference/inspect_*.html` pages are the canonical lookup for every flag on every `inspect` subcommand. There are 11 subcommands, several with their own sub-subcommands (`inspect log list/dump/convert/schema`, `inspect view start/bundle/embed`, `inspect cache clear/path/list`, `inspect sandbox cleanup`). **Use these pages (or the per-subcommand summaries below) to answer "what flag do I pass" / "what's the default" questions; use `ukgovernmentbeis-inspect-ai-cli-and-config.md` for "how does CLI configuration compose with env vars / .env / -T / -M" questions.**

The CLI is a thin wrapper over the Python API: `inspect eval` calls `inspect_ai.eval`, `inspect log` calls helpers in `inspect_ai.log`, etc. If a CLI flag isn't documented, the underlying Python function probably exposes the same knob — cross-reference `inspect-aisi-org-uk-api-reference.md`.

## inspect eval

Run one or more tasks. The flagship subcommand and the one with the largest surface. Flag groups:
([`eval.py` L832–L875](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py#L832-L875))

- **Model**: `--model`, `--model-base-url`, `--model-config`, `-M arg=value`, `--model-role`.
- **Task / solver**: positional `[TASKS]…`, `-T arg=value`, `--task-config`, `--solver`, `-S arg=value`, `--solver-config`.
- **Scanner**: `--scanner`, `--scanner-arg`, `--scans` (dir), `--scan-name`, `-F/--scan-filter` (SQL WHERE), `--scan-model`.
- **Sampling**: `--limit` (e.g. `10` or `10-20`), `--sample-id` (comma list), `--sample-shuffle` (optional seed), `--epochs`, `--epochs-reducer`.
- **Concurrency**: `--max-connections` (default 10), `--adaptive-connections`, `--max-samples`, `--max-tasks`, `--max-subprocesses`.
- **Limits**: `--message-limit`, `--token-limit`, `--cost-limit` (dollars), `--time-limit`.
- **Error handling**: `--fail-on-error` (threshold), `--no-fail-on-error`, `--retry-on-error`.
- **Generation config**: `--temperature`, `--top-p`, `--top-k`, `--max-tokens`, `--seed`, `--stop-seqs`.
- **Logging / display**: `--log-dir` (default `./logs`), `--log-format` (`eval` or `json`), `--log-level`, `--display` (`full`/`conversation`/`rich`/`plain`/`log`/`none`), `--no-log-samples`, `--log-images`.
- **Misc**: `--approval`, `--sandbox`, `--checkpoint`, `--tags`, `--metadata`, `--debug`.

Source: https://inspect.aisi.org.uk/reference/inspect_eval.html
Content-hash: bc3032f0
As-of: 2026-05-19

## inspect eval-set

Run a *set* of tasks with built-in retry and resume. Adds to `inspect eval`'s surface: retry-attempt count (default 10), exponential wait between retries, retry-immediately vs. retry-at-end modes, adaptive connections defaults (min=4, start=20, max=100), `--max-dataset-memory` (page samples to disk above this), `--id` (custom set identifier), `--checkpoint` for resume. Pair with `ukgovernmentbeis-inspect-ai-eval-sets.md` for the conceptual treatment.
([`eval.py` L1063–L1132](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py#L1063-L1132))

Source: https://inspect.aisi.org.uk/reference/inspect_eval-set.html
Content-hash: 7c7a0fa6
As-of: 2026-05-19

## inspect eval-retry

Retry the failed samples from a previous eval-set run. Takes a log directory or set id and re-runs only the samples that errored, with the same retry/wait semantics as `inspect eval-set`.
([`eval.py` L1928–L2000](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/eval.py#L1928-L2000))

Source: https://inspect.aisi.org.uk/reference/inspect_eval-retry.html
Content-hash: fa4e2327
As-of: 2026-05-19

## inspect view

Open and share evaluation logs. Three sub-subcommands:
([`view.py` L37–L123](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/view.py#L37-L123))

- **`inspect view start`** — launch the web viewer. Flags: `--log-dir` (default `./logs`), `--host` (default `127.0.0.1`; use `0.0.0.0` for remote), `--port` (default `7575`), `--recursive` (on by default), `--log-level`.
- **`inspect view bundle`** — package logs for distribution. `--output-dir` (required), `--overwrite`.
- **`inspect view embed`** — embed a lightweight viewer inside the log directory itself for self-contained inspection.

Source: https://inspect.aisi.org.uk/reference/inspect_view.html
Content-hash: a527a488
As-of: 2026-05-19

## inspect log

Query/read/write/convert log files. Sub-subcommands:
([`log.py` L24–L254](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/log.py#L24-L254))

- **`inspect log list`** — list logs in `--log-dir`. Flags: `--status` (`started`/`success`/`cancelled`/`error`), `--absolute`, `--json`, `--no-recursive`.
- **`inspect log dump`** — print log JSON. Flags: `--header-only`, `--resolve-attachments` (`full` or `core`).
- **`inspect log convert`** — convert between formats. Required: `--to` (`eval` or `json`), `--output-dir`. Optional: `--overwrite`, `--stream` (for large logs).
- **`inspect log schema`** — print the JSON schema for log files.

Two log formats exist: `eval` (compact binary, default) and `json`.

Source: https://inspect.aisi.org.uk/reference/inspect_log.html
Content-hash: 060fd81f
As-of: 2026-05-19

## inspect list

Discover available tasks/solvers/scorers in a directory or installed packages. Useful for "what evals can I run from this repo?" questions.
([`list.py` L15–L90](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/list.py#L15-L90))

Source: https://inspect.aisi.org.uk/reference/inspect_list.html
Content-hash: 5a8027e8
As-of: 2026-05-19

## inspect score

Re-score an existing log with a different scorer without re-running the model. Takes a log file plus scorer reference, writes a new log with updated scores.
([`score.py` L35–L87](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/score.py#L35-L87))

Source: https://inspect.aisi.org.uk/reference/inspect_score.html
Content-hash: 224438ed
As-of: 2026-05-19

## inspect info

Diagnostic dump — Inspect version, Python version, detected providers, config precedence resolution. The first command to run when debugging "why isn't my model showing up" or "which `.env` is being read" issues.
([`info.py` L13–L69](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/info.py#L13-L69))

Source: https://inspect.aisi.org.uk/reference/inspect_info.html
Content-hash: f3ecff74
As-of: 2026-05-19

## inspect cache

Manage the model output cache. Sub-subcommands include `clear` (requires `--all` or one-or-more `--model=<provider/model>` flags) and `path` (print the cache directory). The cache is keyed on the prompt + generation config; see `ukgovernmentbeis-inspect-ai-cli-and-config.md` for cache-key semantics.
([`cache.py` L43–L142](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/cache.py#L43-L142))

Source: https://inspect.aisi.org.uk/reference/inspect_cache.html
Content-hash: e6abc3df
As-of: 2026-05-19

## inspect sandbox

Manage sandbox environment lifecycles outside an eval run — useful for cleanup of orphaned containers/VMs left by interrupted runs. Pair with `ukgovernmentbeis-inspect-ai-sandboxing.md`.
([`sandbox.py` L8–L30](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/sandbox.py#L8-L30))

Source: https://inspect.aisi.org.uk/reference/inspect_sandbox.html
Content-hash: 754a3987
As-of: 2026-05-19

## inspect trace

Inspect execution traces — lower-level than logs, captures the full call tree for debugging solver/agent control flow.
([`trace.py` L25–L165](https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/_cli/trace.py#L25-L165))

Source: https://inspect.aisi.org.uk/reference/inspect_trace.html
Content-hash: 9799278f
As-of: 2026-05-19

## See also

- `inspect-aisi-org-uk-docs-portal.md` — overall portal orientation.
- `inspect-aisi-org-uk-api-reference.md` — the Python-side of the reference.
- `ukgovernmentbeis-inspect-ai-cli-and-config.md` — how CLI flags, `.env`, env vars, `-T`/`-M`, and config files compose; precedence rules; idiomatic invocation patterns.
- `ukgovernmentbeis-inspect-ai-eval-sets.md`, `…-logs-and-analysis.md`, `…-sandboxing.md` — conceptual references that the corresponding subcommands realize.

## Crawl provenance

All 11 subcommand pages were snapshotted on 2026-05-19. Local cache: `~/.cache/skill-engine/web-doc/inspect-aisi-org-uk-2026-05-19/reference__inspect_*.md`. See `_crawl-manifest.json` in that directory for the full URL→file→content_hash map.
