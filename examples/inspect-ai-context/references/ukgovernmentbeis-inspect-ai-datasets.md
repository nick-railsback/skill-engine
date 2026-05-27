---
name: Datasets and Samples — input contracts for evaluations
source_id: ukgovernmentbeis-inspect-ai
---

# Datasets

Inspect reads datasets from CSV, JSON, JSONL, and Hugging Face natively, and the `Dataset` protocol is open enough to wrap anything iterable that yields `Sample`s. Built-in loaders live in `src/inspect_ai/dataset/_sources/` (one module per format: `csv.py`, `json.py`, `hf.py`, `example.py`, `file.py`), and the core `Sample` / `MemoryDataset` types live in `_dataset.py`.

## The `Sample` shape

`inspect_ai.dataset.Sample` (Pydantic model) carries one evaluation instance. Field types come straight from the model definition in `_dataset.py`:

| Field | Type | Notes |
|---|---|---|
| `input` | `str` or `list[ChatMessage]` | Required. A bare string becomes a single user message; a list lets you pre-seed system/assistant messages (or include multi-modal content parts). |
| `target` | `str | list[str]` | Default `""`. Ideal output. May be a literal value (text scorers), a list (multi-target), or rubric text (model-graded scorers). For multiple-choice samples it must be the capital letter (`A`, `B`, ...) of the correct option. |
| `choices` | `list[str] | None` | Multiple-choice answer list. Pair with the `multiple_choice` solver. |
| `id` | `int | str | None` | Stable id. Absent → auto-incrementing integer starting at 1. |
| `metadata` | `dict[str, Any] | None` | Arbitrary; surfaces in logs and reducers. Access typed via `sample.metadata_as(MyPydanticModel)`. |
| `sandbox` | `SandboxEnvironmentType | None` | Per-sample sandbox override. Accepts a string (sandbox type) or a `(type, config_path)` tuple (e.g. `("docker", "compose.yaml")`). Resolved through `resolve_sandbox_environment` at construction. |
| `files` | `dict[str, str] | None` | Maps target path inside sandbox → source. Values can be a filesystem path, a URL, inline text, or an inline base64 data URL for binary. |
| `setup` | `str | None` | Path to a bash setup script (resolved relative to the dataset path) or inline script contents. Runs inside the sample's default sandbox before the solver, with a 5-minute timeout. |
| `checkpoint` | `CheckpointSampleConfig | None` | Per-sample checkpoint config; overridden by task- or eval-level `checkpoint` when set. |

Source: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/dataset/_dataset.py

## Built-in loaders

```python
from inspect_ai.dataset import csv_dataset, json_dataset, hf_dataset, example_dataset

csv_dataset("file.csv")
json_dataset("file.json")           # also reads .jsonl
hf_dataset("openai/gsm8k", split="test")
example_dataset("security_guide")   # built-in example datasets shipped with Inspect
```

`hf_dataset` retries transient Hugging Face errors (rate limits, timeouts, Hub-unreachable cache misses) with exponential backoff. Pass `retry=False` to disable. It forwards arbitrary kwargs (e.g. `cache_dir=...`, `trust=True` for repos that execute code on load) to the underlying `datasets.load_dataset()`. See https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/dataset/_sources for each loader's implementation.

S3 paths work transparently: pass `s3://bucket/key` anywhere a local path is accepted (e.g. `json_dataset("s3://my-bucket/dataset.jsonl")`). Authentication follows the AWS CLI's standard credential chain.

## Mapping arbitrary schemas → `Sample`

Loaders accept a `sample_fields` argument: either a `FieldSpec` (rename default field names to your column names; also collect extra fields into `metadata`) or a `record_to_sample` callable for arbitrary transforms.

```python
from inspect_ai.dataset import FieldSpec, Sample, json_dataset

# Option 1: FieldSpec for pure renames
dataset = json_dataset(
    "popularity.jsonl",
    FieldSpec(
        input="question",
        target="answer_matching_behavior",
        id="question_id",
        metadata=["label_confidence"],
    ),
)

# Option 2: record_to_sample for custom transforms
def record_to_sample(record):
    return Sample(
        input=f"Question: {record['q']}\n\nAnswer step by step.",
        target=record["a"],
        metadata={"category": record["cat"]},
    )

dataset = json_dataset("popularity.jsonl", record_to_sample)
```

## Custom readers

For sources Inspect doesn't natively know about, build a `MemoryDataset` (or anything iterable that yields `Sample`s) and pass it directly to `Task(dataset=...)`:

```python
from inspect_ai import Task, task
from inspect_ai.dataset import MemoryDataset, Sample
from inspect_ai.scorer import model_graded_fact
from inspect_ai.solver import generate, system_message

dataset = MemoryDataset([
    Sample(input="What cookie attributes...?", target="secure samesite and httponly"),
])

@task
def security_guide():
    return Task(dataset=dataset, solver=[system_message(SYSTEM_MESSAGE), generate()],
                scorer=model_graded_fact())
```

`MemoryDataset` is the in-memory implementation under the hood; the `Dataset` protocol just needs iteration plus `filter` / `shuffle` / slicing semantics.

## Filtering, shuffling, slicing

`dataset.filter(predicate)`, `dataset.shuffle(seed=...)`, and `dataset[0:100]` are the routine knobs. You can also shuffle on load (`json_dataset("data.jsonl", shuffle=True)`), or from the CLI:

```bash
inspect eval ctf.py --sample-id 22,23,24
inspect eval ctf.py --sample-id '*_advanced'   # glob
inspect eval ctf.py --sample-shuffle 42
```

For evaluations sensitive to ordering effects (e.g. multiple-choice), the `shuffled_choices` option on the solver side is the usual answer rather than shuffling samples globally.

## Sample files (sandbox seeding)

`files={"/shared/flag.txt": "local/path/flag.txt"}` copies a host file into the sandbox at sample start. Values can be paths, URLs (downloaded), inline string content, or inline base64 data URLs for binary content — useful for CTF-style evals where each sample plants different files.

Two routing tricks worth knowing:

- Prefix the target with a sandbox name to route into a non-default environment: `"victim:/shared/flag.txt": "flag.txt"` copies into the `victim` sandbox.
- Point the source at a directory and it copies recursively: `"/shared/resources": "resources"`.

## See also

- `ukgovernmentbeis-inspect-ai-tasks.md` — how datasets compose into a `Task`.
- `ukgovernmentbeis-inspect-ai-sandboxing.md` — `Sample.sandbox` and `Sample.files` semantics for sandboxed runs.

## Source

- `docs/datasets.qmd` — https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/docs/datasets.qmd
- `src/inspect_ai/dataset/_dataset.py` — `Sample` / `MemoryDataset` definitions: https://github.com/UKGovernmentBEIS/inspect_ai/blob/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/dataset/_dataset.py
- `src/inspect_ai/dataset/_sources/` — built-in loaders: https://github.com/UKGovernmentBEIS/inspect_ai/tree/033745ddbc05431c38b015a4b8f2236e956ee9ea/src/inspect_ai/dataset/_sources
- Repo SHA: `033745ddbc05431c38b015a4b8f2236e956ee9ea`
