# engine-bootstrap-templates

This directory holds the templates the `engine-bootstrap` workflow stamps into a fresh contextualizer skeleton, plus the contextualizer-side `verify.sh` and several files that are copied manually rather than stamped. The directory is part of the engine plugin install.

`engine-bootstrap` stamps four things, and they land in the user's `.claude/skills/<slug>-context/` at scaffold time: `verify.sh`, one of the two navigator templates, `source-paths.json.template` and `research-state.json.template`. Every other row below is a file you copy yourself; the ones with a user-side destination say where it goes, and are marked **not** stamped.

## What lives here

| File | Purpose |
|---|---|
| `navigator.md.template` | Single-source-root navigator skeleton (one `## Catalog` block, one `## Cross-reference map`) |
| `navigator-multi-domain.md.template` | Multi-source-root navigator skeleton (per-source `## Catalog: <slug>` blocks, `## Cross-source map`) |
| `maintenance-agent.md.template` | System prompt for the hand-rolled (non-plugin) install path documented in `docs/03-engine.md` — **not** stamped by engine-bootstrap |
| `monorepo-config.json.template` | Slice-config skeleton for monorepo adapters ([07-monorepo-adapter.md](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/07-monorepo-adapter.md)) |
| `bootstrap-monorepo-config.sh.template` | Interactive generator for the monorepo slice config |
| `source-paths.json.template` | Source-registry skeleton (`research/source-paths.json`) |
| `source-paths.schema.json` | JSON Schema for the source registry — the machine-readable transcription of the contract `verify.sh` Checks 1–2 enforce |
| `research-state.json.template` | The 25-byte setup marker (`research/.research-state.json`) |
| `REVIEW.md.template` | Predict-then-compare review worksheet staged with every proposal |
| `release-command.md.template` | User-side release skill — copied manually to `.claude/commands/release.md` per [06-release-doctrine.md](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/06-release-doctrine.md) (**not** stamped by engine-bootstrap) |
| `pre-commit.sh.template` | User-side pre-commit hook — copied manually to `.git/hooks/pre-commit` per [06-release-doctrine.md](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/06-release-doctrine.md) (**not** stamped by engine-bootstrap); runs every stamped contextualizer's `verify.sh` before each commit |
| `eval/run-eval.sh.template` | Eval harness — copied manually into a contextualizer per `docs/12-evaluation.md` (**not** stamped by engine-bootstrap); runs the contextualizer's `evals/evals.json` queries against the navigator |
| `eval/render-eval-results.sh.template` | Renders accumulated eval results into a report |
| `eval/eval-viewer.html.template` | Static HTML viewer for eval result files |
| `verify.sh` | Contextualizer-side audit run against a stamped `.claude/skills/<slug>-context/` directory (source-paths shape, navigator frontmatter, catalog↔references bijection, reference frontmatter, web-doc provenance, optional SKILL.json trijection, etc.). SHA-pinned-permalink density is **not** here — that is the separate `permalink_density.py` CI lint. |

## Editing convention

The files in this directory are the only editing copies — there is no
separate workshop or engine-authoring tree to sync against.

`verify.sh` is the one file that exists in more than one place: each
bundled example (`examples/<slug>/verify.sh`) carries a byte-identical
copy so the examples are runnable standalone. When `verify.sh` changes
here, re-copy it over every example copy in the same commit —
`doctrine.sh` check 7 (`plugin/skill-engine/tests/doctrine.sh`) fails CI
on any divergence, and REFRESH additionally SHA-256-compares the stamped
copy at runtime.
