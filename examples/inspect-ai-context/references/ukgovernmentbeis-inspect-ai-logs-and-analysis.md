---
name: Eval logs, the log viewer, and the dataframe analysis API
source_id: ukgovernmentbeis-inspect-ai
---

# Eval logs

Every `inspect eval` and `eval()` call writes one log per task. The log is the canonical artifact for reproducibility, debugging, and downstream analysis. Default location is `./logs/` — override via `--log-dir`, `INSPECT_LOG_DIR` (in shell or `.env`), or `eval(log_dir=...)`. Relative `INSPECT_LOG_DIR` paths in a `.env` resolve relative to the `.env` file, not the CWD.

## Log format: `.eval` vs `.json`

Two on-disk formats — both round-trip through the same Python API:

- `.eval` (default since v0.3.46) — binary, zstd-compressed, deduplicated; supports incremental sample access. Typically ~1/8 the size of `.json` and stays fast in Inspect View regardless of file size.
- `.json` — plain JSON; readable in any text editor but slow in the viewer above ~50MB.

Set the default with `INSPECT_LOG_FORMAT=eval` (in `.env`) or `--log-format=eval` per run. As of v0.3.206, log storage gained two big optimizations: cross-event message deduplication and zstd compression — together they yield ~10:1 size reduction on typical agentic benchmarks (SWE-Bench, Cybench) and much more on long-horizon tasks (addresses O(N^2) growth). Convert older logs with `inspect log convert old/ --to eval --output-dir new/ --stream 10` (the `--stream` cap bounds in-memory samples during conversion). If you use Inspect Scout, ensure v0.4.22 or later to read the condensed format.

## `EvalLog` object

`EvalLog` is the canonical in-memory shape returned by `eval()` and `read_eval_log()`. Top-level fields:

- `version` (`int`, currently 2), `status` (`"started"`, `"success"`, `"error"`).
- `eval` (`EvalSpec`) — task, model, creation time, run config.
- `plan` (`EvalPlan`) — solvers + generation config.
- `results` (`EvalResults`) — aggregate scorer metrics.
- `stats` (`EvalStats`) — token usage, timing.
- `error` (`EvalError`) — traceback when `status == "error"`.
- `samples` (`list[EvalSample]`) — per-sample input, output, target, scores, events.
- `reductions` (`list[EvalSampleReduction]`) — multi-epoch sample reductions.
- `tags`, `metadata` — current values (eval-time merged with post-eval edits).
- `log_updates` (`list[LogUpdate]`) — append-only edit history with provenance.
- `location` — fsspec URI (`file://`, `s3://`, `az://`, etc.) the log was read from or will be written to.

Always check `log.status == "success"` before analysing results.

## Reading and writing logs

```python
from inspect_ai.log import (
    read_eval_log, write_eval_log, list_eval_logs,
    read_eval_log_sample, read_eval_log_samples,
    read_eval_log_sample_summaries, resolve_sample_attachments,
)

log = read_eval_log("logs/run.eval", header_only=True)   # skip samples
sample = read_eval_log_sample("logs/run.eval", id=42)    # one sample
for sample in read_eval_log_samples("logs/run.eval"):    # streaming generator
    ...
```

Key functions:

- `list_eval_logs(log_dir, recursive=True, filter=...)` — enumerate logs, optionally filtered by a predicate over `EvalLog` headers (e.g. `lambda log: log.status == "success"`).
- `read_eval_log(path, header_only=False, resolve_attachments=False)` — header-only reads skip the samples array (orders of magnitude faster on multi-GB logs).
- `read_eval_log_sample_summaries(path)` — returns `EvalSampleSummary` per sample (thinned: images dropped from `input`, metadata limited to scalars truncated at 1k, scores reduced to `value`). Use this to filter before drilling into full samples.
- `read_eval_log_samples(path, all_samples_required=False)` — generator; pass `all_samples_required=False` to iterate samples from non-success logs.
- `write_eval_log(log)` — writes back to `log.location` if no path is given; supports `if_match_etag` for S3 conditional writes.
- `resolve_sample_attachments(sample)` — inflate de-duplicated images/large content. Typically only needed when iterating `sample.events` or reading base64 images out of `input`/`messages`.

## CLI log commands

```bash
inspect log list [--json] [--status success|error] [--retryable]
inspect log dump <uri>                       # plain JSON, handles .eval and remote URIs
inspect log convert src --to eval --output-dir dst [--overwrite] [--stream N]
inspect log export-config <file> [--output run.yaml] [--format yaml|json]
inspect log schema                           # JSON schema for the log format
```

Always prefer `inspect log dump` over reading log URIs directly — it normalises `.eval`/`.json` to JSON text and uses your configured fsspec credentials for S3, GCS, Azure. `inspect log export-config` closes the round-trip `eval → log → export-config → eval` by emitting a YAML/JSON that `inspect eval --run-config` can rerun. Note: log JSON may contain `NaN`/`Inf`, which Python handles but browsers/Node do not — use a JSON5 parser for JS consumers.

## Log editing (scores, tags, metadata)

Score and metadata edits are first-class and audited:

```python
from inspect_ai.log import read_eval_log, write_eval_log, edit_score, edit_eval_log
from inspect_ai.scorer import ScoreEdit, ProvenanceData
from inspect_ai.log import TagsEdit, MetadataEdit

log = read_eval_log("my_eval.eval")
edit_score(log, sample_id=log.samples[0].id, score_name="accuracy",
           edit=ScoreEdit(value=0.95, explanation="grader bug",
                          provenance=ProvenanceData(author="me", reason="...")))
log = edit_eval_log(log, [
    TagsEdit(tags_add=["qa_passed"], tags_remove=["needs_qa"]),
    MetadataEdit(metadata_set={"reviewer": "alice"}, metadata_remove=["draft_notes"]),
], ProvenanceData(author="alice", reason="QA complete"))
write_eval_log(log)
```

`edit_score()` recomputes aggregate metrics by default — pass `recompute_metrics=False` for batches, then call `recompute_metrics(log)` once. Every score keeps its full history at `sample.scores[name].history`. Edit-time `tags`/`metadata` live on `log.tags`/`log.metadata`; eval-time originals stay on `log.eval.tags`/`log.eval.metadata`; the full edit trail lands in `log.log_updates`. A `ScoreEditEvent` is appended to the sample's event log on every score edit.

## Remote storage

S3 (`s3://`), Azure (`az://`, `abfs://`, `abfss://`), GCS, and anything fsspec supports work as `--log-dir` or `INSPECT_LOG_DIR`. For Azure install `adlfs>=2025.8.0`; on Azure compute prefer managed identity (`DefaultAzureCredential`) and explicitly set `AZURE_STORAGE_ANON=false` (an unset value is interpreted as anonymous and silently bypasses your credentials). Fallback credentials are tried in order: SAS token > account key > connection string.

## Log file names

Default pattern is `{timestamp}_{task}_{id}`. `{timestamp}` is required (drives filesystem ordering); the rest is customisable via `INSPECT_EVAL_LOG_FILE_PATTERN` over `task`, `model`, `id`.

## Other log behaviour worth knowing

- Images log as base64 inside the log by default — fine for `.eval`, can bloat `.json`. Disable with `--no-log-images` or `INSPECT_EVAL_LOG_IMAGES`.
- Raw model API requests/responses are logged for the first few calls per model plus all errors. `--log-model-api` logs all; `--no-log-model-api` logs errors only.
- Refusals always show in the bottom-right task counter; `--log-refusals` additionally emits warnings into the log.

# The log viewer — `inspect view`

`inspect view` starts a local web UI that auto-discovers logs in `--log-dir` (default `./logs`). Bind to 127.0.0.1:7575 by default; use `--port` for a second instance, and `--host 0.0.0.0` to expose over SSH. You only need to run it once per session — it picks up new logs and live updates as evaluations run.

VS Code users should install the "Inspect AI" extension for integrated viewing. The viewer drills into per-sample message transcripts, scoring details, metadata, and the **Info** panel (dataset, solver, scorer, git revision, model token usage). Filter by score with the Scores picker; toggle sample-vs-epoch ordering with the Sort picker (sample order is invaluable for diagnosing per-sample variance across epochs).

## Live viewing

Live view follows samples and events as they happen. For multi-user setups where logs are on shared storage (S3, NFS), pass `--log-shared` to `inspect eval` so live log events get mirrored to the shared filesystem (default sync interval 10s; override with `--log-shared 30`). Without `--log-shared` the live event DB stays local and only the evaluator's machine can stream it.

## Bundling and publishing

`inspect view bundle --log-dir logs --output-dir logs-www [--overwrite]` (or `bundle_log_dir()` from Python) produces a self-contained static directory (`index.html`, `assets/`, `logs/`, `robots.txt`) deployable to GitHub Pages, S3, Netlify. The viewer uses HTTP range requests — Python's stdlib `http.server` does not support them, use a real static server. Link to a specific log with `?log_file=<path>`. Bundling to `hf/<org>/<space>` publishes to HuggingFace Spaces (private by default; pass `fs_options={"private": False}` via Python). Set a default output dir with `INSPECT_VIEW_BUNDLE_OUTPUT_DIR`.

## Python logging integration

Inspect installs a `logging` handler so standard `logger = logging.getLogger(__name__); logger.info(...)` calls land both above the task display and inside the sample transcript. Default thresholds: `warning` to console, `info` to transcript. Override with `--log-level`, `--log-level-transcript`, or env vars `INSPECT_LOG_LEVEL`/`INSPECT_LOG_LEVEL_TRANSCRIPT`. Mirror Python logger output to a file with `INSPECT_PY_LOGGER_FILE` (level via `INSPECT_PY_LOGGER_LEVEL`); pick console format with `INSPECT_PY_LOGGER_FORMAT=rich|plain|json` (use `plain`/`json` for CI / log aggregators).

# Log dataframes — `inspect_ai.analysis`

`inspect_ai.analysis` flattens log hierarchies into Pandas dataframes. Four entry points, each adding one level of granularity:

| Function | Granularity |
|----------|-------------|
| `evals_df(logs)` | one row per log (task, model, scores, config) |
| `samples_df(logs)` | one row per sample (input, scores, metadata, error) |
| `messages_df(logs, filter=...)` | one row per chat message |
| `events_df(logs, columns=..., filter=...)` | one row per transcript event |

`eval_id` / `sample_id` / `event_id` are automatic primary keys, plus a `log` column with the source URI — joins between dataframes are straightforward (e.g. DuckDB: `con.register('evals', evals_df("logs")); con.register('samples', samples_df("logs"))`).

## Column groups

Column selection is composable. Pre-built groups:

- Eval-level: `EvalInfo`, `EvalTask`, `EvalModel`, `EvalDataset`, `EvalConfig`, `EvalResults`, `EvalScores`. Default `EvalColumns` combines all (~50 columns).
- Sample-level: `SampleSummary` (default; fast — reads `EvalSampleSummary` headers only), `SampleScores` (adds answer/metadata/explanation), `SampleMessages` (concatenates messages, requires full sample read).
- Message-level: `MessageContent`, `MessageToolCalls`, `MessageColumns` (= both).
- Event-level: `EventInfo`, `EventTiming`, `ModelEventColumns`, `ToolEventColumns` — no default; you compose them yourself.

Mix groups freely: `samples_df("logs", columns=EvalInfo + EvalModel + SampleSummary)` joins per-sample rows with parent eval columns.

## Filtering and performance

- `list_eval_logs("logs", filter=lambda log: log.status == "success")` filters at the file level; pass the list straight to `evals_df`/`samples_df`.
- `messages_df("logs", filter=["assistant"])` — filter by role or predicate.
- `events_df("logs", columns=EventTiming + ModelEventColumns, filter=lambda e: e.event == "model")` — filter by event type.
- Pass `parallel=True` (capped at 8 workers via `ProcessPoolExecutor`, or pass an explicit int) on `samples_df`/`messages_df`/`events_df` for full-sample reads over large directories. `evals_df` has no `parallel` option — its header reads are too cheap to parallelise.
- For `samples_df`, stick with `SampleSummary` columns when possible — they read only headers. `SampleMessages`, `events_df`, full-sample fields trigger heavyweight reads.
- `strict=False` returns `(df, errors)` instead of raising on missing fields.

## Column definitions

`Column` subclasses (`EvalColumn`, `SampleColumn`, `MessageColumn`, `EventColumn`) map JSON paths to dataframe cells:

```python
from inspect_ai.analysis import EvalColumn, SampleColumn

EvalColumn("run_id", path="eval.run_id", required=True)
SampleColumn("id", path="id", required=True, type=str)
SampleColumn("metadata_*", path="metadata")              # dict -> multi-column
SampleColumn("target", path="target", value=list_as_str) # transform
SampleColumn("limit_type", path="limit.type", full=True) # force full-sample read
```

Options: `name` (supports `*` wildcards for dict-to-multi-column splits), `path` (JSON Path expression — see h2non/jsonpath-ng — or a callable `(EvalLog | EvalSample | ChatMessage | Event) -> JsonValue`), `required`, `default`, `type` (coerces via YAML on str input), `value` (post-read transform). Later definitions with the same `name` override earlier ones, making it easy to tweak defaults.

Custom extraction example — the built-in `EvalScores` group uses a callable path:

```python
def scores_dict(log: EvalLog) -> JsonValue:
    if log.results is None:
        return None
    return [{score.name: {m.name: m.value for m in score.metrics.values()}}
            for score in log.results.scores]

EvalScores = [EvalColumn("score_*_*", path=scores_dict)]
```

When epochs use multiple reducers, the default score expansion disambiguates by reducer (e.g. `accuracy_mean`, `accuracy_pass_at_k`).

Note: sample summaries gained `metadata`, `model_usage`, `total_time`, `working_time`, and `retries` fields in v0.3.93 (May 2025). Round-trip older logs with `inspect log convert` to backfill them.

## Data preparation — `prepare()`

`prepare(df, [...operations])` runs a pipeline of transformations after extraction. Built-in operations live in `inspect_ai.analysis._prepare`:

- `model_info()` — adds `model_organization_name`, `model_display_name`, `model_snapshot`, `model_release_date`, `model_knowledge_cutoff_date` from a bundled registry. Bring your own metadata for unrecognised models.
- `task_info({"gpqa_diamond": "GPQA Diamond"})` — maps task names to display names.
- `log_viewer(target, {local_dir: published_url})` — adds a `log_viewer` URL column for logs you've bundled and published. Targets: `"eval"`, `"sample"`, `"event"`, `"message"`.
- `frontier()` — adds a boolean `frontier` column marking models that were top-scoring at their release date. Requires `model_info()` first.
- `score_to_float("score_includes")` — coerces score columns to float via a configurable `value_to_float`.

```python
from inspect_ai.analysis import evals_df, prepare, model_info, frontier, log_viewer

df = prepare(evals_df("logs"), [
    model_info(),
    frontier(),
    log_viewer("eval", {"logs": "https://logs.example.com"}),
])
```

# Inspect Scout (transcript scanners)

Separate package `inspect_scout` runs scanners (refusal detection, tool-call sequence checks, hallucination scanners) over completed logs. Wire it into `eval_set` via `--scanner` so scans run incrementally as new logs land. Use v0.4.22 or later if your logs use the condensed v0.3.206+ storage format.

# Inspect Viz

`inspect_viz` (Meridian Labs) is the dashboard/plotting layer built on top of the dataframe API — autogen dashboards, cross-run time series, model comparison plots. Not first-party but designed around these dataframes. See https://meridianlabs-ai.github.io/inspect_viz/.

# See also

- `ukgovernmentbeis-inspect-ai-eval-sets.md` — `log_dir` is the eval-set scope for resumable work; `eval_set` returns log headers (you must `read_eval_log()` them to edit).
- `ukgovernmentbeis-inspect-ai-scorers.md` — the `Score` shape (`value`, `answer`, `explanation`, `metadata`) that lands in `log.samples` and feeds `SampleSummary`/`SampleScores`.

# Source

- `docs/eval-logs.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/eval-logs.qmd
- `docs/log-viewer.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/log-viewer.qmd
- `docs/dataframe.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/dataframe.qmd
- `src/inspect_ai/log/` — https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/log
- `src/inspect_ai/analysis/_dataframe/` — https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/analysis/_dataframe
- `src/inspect_ai/analysis/_prepare/` — https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/analysis/_prepare
- Repo pin: `033745ddbc05431c38b015a4b8f2236e956ee9ea`
