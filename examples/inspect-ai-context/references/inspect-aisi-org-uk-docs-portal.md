---
name: inspect.aisi.org.uk — the rendered docs portal
source_id: inspect-aisi-org-uk
---

# What lives at inspect.aisi.org.uk

This is the Quarto-rendered companion to the `docs/` directory in the `UKGovernmentBEIS/inspect_ai` repository. **Most user-guide pages are 1:1 renders of `docs/*.qmd` files** (concepts, tutorial, examples) — for those, the `ukgovernmentbeis-inspect-ai-*` references in this contextualizer are the source-of-truth read. The portal carries two categories of content that **only exist here**, and that is the reason this reference (and its two siblings) exist:

1. **Auto-generated Python API reference** — under `/reference/inspect_ai.*.html`, one page per public module: `inspect_ai`, `inspect_ai.agent`, `inspect_ai.analysis`, `inspect_ai.approval`, `inspect_ai.dataset`, `inspect_ai.event`, `inspect_ai.hooks`, `inspect_ai.log`, `inspect_ai.model`, `inspect_ai.scorer`, `inspect_ai.solver`, `inspect_ai.tool`, `inspect_ai.util`. These are the canonical class/function reference — exact signatures, parameters, return types, generated from source. See `inspect-aisi-org-uk-api-reference.md` for the catalog and per-module summaries.
2. **CLI reference** — under `/reference/inspect_<cmd>.html`, one page per `inspect` subcommand: `inspect eval`, `inspect eval-set`, `inspect eval-retry`, `inspect view`, `inspect log`, `inspect list`, `inspect score`, `inspect info`, `inspect cache`, `inspect sandbox`, `inspect trace`. Each documents every flag. See `inspect-aisi-org-uk-cli-reference.md` for the catalog and per-subcommand summaries.

## Top-level navigation

| Section | Path | What's there |
|---|---|---|
| User Guide | `/` and most `*.html` siblings | Tutorial, options, log viewer, components (tasks, datasets, solvers, scorers, scanners), models, agents, tools, analysis, advanced topics (eval-sets, errors, limits, parallelism, etc.). Renders of `docs/*.qmd`. |
| Reference | `/reference/index.html` | API reference (per-module) + CLI reference (per-subcommand). **Unique to the portal.** |
| Extensions | `/extensions/index.html` | Lists third-party Inspect extensions: Inspect SWE, Inspect Viz, Inspect Scout, additional model providers, etc. |
| Evals | `/evals/index.html` | Catalog of 200+ pre-built evaluations ready to run on any model. Renders from `docs/evals/`. |

## When to consult the portal vs. the repo

- **Reading concepts, examples, prose** — either works. The repo's `docs/*.qmd` is the source of truth and is what the `ukgovernmentbeis-inspect-ai-*` references in this contextualizer cite.
- **Looking up an exact function signature, class field, or CLI flag** — go to the portal (or the corresponding sibling reference here). The `/reference/` pages have what isn't in the repo prose docs.
- **Finding a pre-built benchmark to run** — `/evals/index.html` is the entry point. Each eval has its own page with run instructions and a link to its source location in the `meridianlabs-ai/inspect_evals` repo.

## URL stability and versioning

The portal redirects retired URLs (e.g., `eval-suites.html` → `eval-sets.html`). The `/reference/` pages re-render on every release, so signatures may shift between releases in ways the user-guide prose doesn't. When documenting API specifics for a particular Inspect version, pin to that version explicitly rather than relying on the live portal.

## Crawl provenance

The 72-page sitemap at `https://inspect.aisi.org.uk/sitemap.xml` was fetched on 2026-05-19. The 25 `/reference/` pages that constitute the portal's unique value are snapshotted locally at `~/.cache/skill-engine/web-doc/inspect-aisi-org-uk-2026-05-19/` with `_crawl-manifest.json` containing the URL → file map and per-page content hashes. The remaining 47 user-guide pages mirror `docs/*.qmd` in the git-managed source (SHA `7dde014e`) and were intentionally not re-snapshotted — read those via the `ukgovernmentbeis-inspect-ai-*` references instead.

## See also

- `inspect-aisi-org-uk-api-reference.md` — the 13 Python API module pages, what each module exports.
- `inspect-aisi-org-uk-cli-reference.md` — the 11 `inspect` subcommands, what flags each accepts.
- `ukgovernmentbeis-inspect-ai-overview.md` — the conceptual orientation that the user-guide portal renders.
- `ukgovernmentbeis-inspect-ai-cli-and-config.md` — pair with the CLI catalog when looking up a specific flag's behavior in context.

## Source

Source: https://inspect.aisi.org.uk/sitemap.xml (72 pages)
Source: https://inspect.aisi.org.uk/reference/index.html
Content-hash: 10254cdf
As-of: 2026-05-19
Sitemap-fetched-on: 2026-05-19
