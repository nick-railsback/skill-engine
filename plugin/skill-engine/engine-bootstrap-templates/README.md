# engine-bootstrap-templates

This directory holds the templates the `engine-bootstrap` workflow stamps into a fresh contextualizer skeleton, plus the contextualizer-side `verify.sh`. The directory is part of the engine plugin install; the templates land in the user's `.claude/skills/<slug>-context/` at scaffold time.

## Two-tier verify discipline

The repository ships **two `verify.sh` programs** in different directories. They cover non-overlapping audit surfaces and are intentionally separate:

| File | Audience | Surface |
|---|---|---|
| [`plugin/skill-engine/engine-bootstrap-templates/verify.sh`](./verify.sh) | **Contextualizer authoring** | 9 named checks against a stamped `.claude/skills/<slug>-context/` directory (frontmatter, soft-wrap, catalog bijection, SHA-pinned permalinks, optional SKILL.json trijection, etc.) |
| [`templates/verify.sh`](https://github.com/nick-railsback/skill-engine/blob/main/templates/verify.sh) | **Engine authoring** | 27 named checks against the engine-authoring repo root (chapter shape, navigator-template invariants, source-paths schema, persona-leak gates, monorepo invariants, etc.) |

The contextualizer-side check counts 1–9; the engine-authoring-side check counts 1–27. The two surfaces are independent — a future change to one is **not** auto-mirrored to the other. The `skill-json-trijection` check appears in both (Check 9 contextualizer-side / Check 27 engine-authoring-side); the predicate is the same, the numbering differs because the audit surfaces are independent.

## What lives here

| File | Purpose |
|---|---|
| `navigator.md.template` | Single-source-root navigator skeleton (one `## Catalog` block, one `## Cross-reference map`) |
| `navigator-multi-domain.md.template` | Multi-source-root navigator skeleton (per-source `## Catalog: <slug>` blocks, `## Cross-source map`) |
| `maintenance-agent.md.template` | The engine's maintenance-agent system prompt — what the model reads when activated |
| `monorepo-config.json.template` | Slice-config skeleton for monorepo adapters ([07-monorepo-adapter.md](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/07-monorepo-adapter.md)) |
| `verify.sh` | Contextualizer-side audit (9 named checks) |

## Editing convention

The workshop sources at `templates/navigator.md.template` and `templates/navigator-multi-domain.md.template` are the canonical editing copies; the bundled copies here are kept byte-equal to them. A future story will add a `verify.sh` named check that fails on drift; until then, drift is checked manually when changes land.

The contextualizer-side `verify.sh` and `maintenance-agent.md.template` live only here — there is no separate workshop copy to keep in sync.
