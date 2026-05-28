# LangChain docs (companion repo)

[langchain-ai/docs](https://github.com/langchain-ai/docs/tree/a623fd54dca3b37d00e004ea6feda5ec338eab67) is the source repository for **[docs.langchain.com](https://docs.langchain.com)** — the unified docs site for LangChain (Python and JS), LangGraph, LangSmith, and LangChain Labs (Deep Agents, Open SWE, Open Agent Platform). The `langchain-ai/langchain` monorepo carries no in-tree prose docs (only README and CLAUDE.md files); everything user-facing lives here.

This repo is **not** the source of [reference.langchain.com](https://reference.langchain.com/python/) — that's the auto-generated API reference site, built from docstrings in each respective package's repo and deployed by separate infra. If a question is "where is the docstring for `create_agent`?", the answer is in [`libs/langchain_v1/langchain/agents/factory.py`](https://github.com/langchain-ai/langchain/blob/7bb4130c7d460f14ec6391805cb47bf01637b5c5/libs/langchain_v1/langchain/agents/factory.py) in the `langchain` repo, not here. If the question is "where is the prose tutorial on building an agent?", the answer is here.

## Repo layout

The docs are a Mintlify site (navigation and site config in [`src/docs.json`](https://github.com/langchain-ai/docs/blob/a623fd54dca3b37d00e004ea6feda5ec338eab67/src/docs.json)), with hand-authored `.mdx` source under `src/` and a build pipeline that generates the deployable site under `build/` (which you should never edit directly):

```
docs/
├── src/                        # All hand-authored content (edit here)
│   ├── docs.json               # Mintlify navigation + site config
│   ├── index.mdx               # Home page
│   ├── style.css               # Custom CSS
│   ├── langsmith/              # LangSmith product docs
│   ├── oss/                    # Open-source docs
│   │   ├── langchain/          #   LangChain framework
│   │   ├── langgraph/          #   LangGraph framework
│   │   ├── deepagents/         #   Deep Agents
│   │   ├── python/             #   Python-specific (integrations, migrations, releases)
│   │   ├── javascript/         #   TS-specific (integrations, migrations, releases)
│   │   ├── integrations/       #   Shared integration content
│   │   ├── concepts/           #   Conceptual overviews
│   │   ├── contributing/       #   Contribution guides
│   │   └── reference/          #   Reference-tab entry pages (link out to reference.langchain.com)
│   ├── snippets/               # Reusable MDX snippets
│   └── images/                 # Documentation images
├── pipeline/                   # Python build system & preprocessors
├── packages.yml                # Source-of-truth registry of every LangChain package
└── build/                      # Build output — DO NOT EDIT
```

The [`src/oss/`](https://github.com/langchain-ai/docs/tree/a623fd54dca3b37d00e004ea6feda5ec338eab67/src/oss) tree is most relevant to LangChain developers. It splits by product (`langchain/`, `langgraph/`, `deepagents/`) and by language (`python/`, `javascript/`). Pages mix Python and JS examples using `:::python` / `:::js` fences that the pipeline expands into separate per-language pages at build time.

## What lives in this repo (and what doesn't)

**Lives here:**

- All conceptual docs, tutorials, how-to pages, and quickstarts for `langchain`, `langgraph`, `deepagents`, and LangSmith.
- The integration index — every partner package gets a page under `src/oss/python/integrations/<component>/<provider>.mdx` (or `.../javascript/...`).
- Runnable code samples under [`src/code-samples/`](https://github.com/langchain-ai/docs/tree/a623fd54dca3b37d00e004ea6feda5ec338eab67/src/code-samples) (Python + TypeScript) for `deepagents`, `langchain`, and `langsmith`. These are tested by `make test-code-samples` and referenced from the prose pages by `<CodeSample>` includes.
- Anthropic-style skill manifests under [`src/.mintlify/skills/`](https://github.com/langchain-ai/docs/tree/a623fd54dca3b37d00e004ea6feda5ec338eab67/src/.mintlify/skills) for `deep-agents`, `langchain`, `langgraph`, and `langsmith` — each a `SKILL.md` Mintlify ships so agents using the docs site can opportunistically pick up the right framework.
- The package registry: [`packages.yml`](https://github.com/langchain-ai/docs/blob/a623fd54dca3b37d00e004ea6feda5ec338eab67/packages.yml) — covered separately below.
- The contributing guides at [`src/oss/contributing/`](https://github.com/langchain-ai/docs/tree/a623fd54dca3b37d00e004ea6feda5ec338eab67/src/oss/contributing).
- Release notes and changelogs for both Python (`changelog-py.mdx`) and JS (`changelog-js.mdx`) per product.
- Release-policy and versioning policy at [`src/oss/release-policy.mdx`](https://github.com/langchain-ai/docs/blob/a623fd54dca3b37d00e004ea6feda5ec338eab67/src/oss/release-policy.mdx) and [`versioning.mdx`](https://github.com/langchain-ai/docs/blob/a623fd54dca3b37d00e004ea6feda5ec338eab67/src/oss/versioning.mdx).

**Does NOT live here:**

- Auto-generated API reference (`@[ChatOpenAI]`-style class docs, full method signatures). That's [reference.langchain.com](https://reference.langchain.com/python/) — built outside this repo. Issues with reference docs use [a different issue template](https://github.com/langchain-ai/docs/issues/new?template=04-reference-docs.yml) so the maintainers can route them.
- Source code. Code lives in each project's repo; this repo just documents it.

## `packages.yml` — the package registry

The single most useful file in this repo for non-doc consumers is [`packages.yml`](https://github.com/langchain-ai/docs/blob/a623fd54dca3b37d00e004ea6feda5ec338eab67/packages.yml). It's the source-of-truth registry of every LangChain Python package — the in-tree ones from the `langchain` monorepo, every partner integration package across every owning repo, and external packages with corresponding pages on the docs site. Each entry carries:

- `name` — the PyPI package name.
- `repo` — the owning GitHub repo (e.g., `langchain-ai/langchain`, `langchain-ai/langchain-google`, `langchain-ai/langchain-aws`).
- `path` — the path within that repo (e.g., `libs/partners/anthropic`).
- `js` — the corresponding npm package name, if any.
- `downloads` — monthly download count, refreshed weekly by [`scripts/packages_yml_get_downloads.py`](https://github.com/langchain-ai/docs/blob/a623fd54dca3b37d00e004ea6feda5ec338eab67/scripts/) from pepy.tech.
- `provider_page` — override for the provider's docs page location.

If you ever need to answer "what packages exist?", "which repo owns this package?", or "how popular is this integration relative to that one?", `packages.yml` is the authoritative answer. The published partner table on [docs.langchain.com](https://docs.langchain.com/oss/python/integrations/providers) and the integration index pages are generated from this file.

## Local development

The contributing flow is documented in [`README.md`](https://github.com/langchain-ai/docs/blob/a623fd54dca3b37d00e004ea6feda5ec338eab67/README.md):

```bash
git clone https://github.com/langchain-ai/docs.git
cd docs
make install
make dev          # Mintlify dev server with watch + hot reload
```

Plus a `docs` CLI (`uv run docs`, registered as the `pipeline.cli:main` entry point — so `uv run pipeline <subcommand>` also works) with subcommands like `docs migrate <path>` (MkDocs/Docusaurus → Mintlify), `docs mv <old> <new>` (move a file and update cross-references), and `docs build`.

## Conventions for AI-assisted edits

The repo's [`CLAUDE.md`](https://github.com/langchain-ai/docs/blob/a623fd54dca3b37d00e004ea6feda5ec338eab67/CLAUDE.md) (mirrored to `AGENTS.md`) is unusually load-bearing if you're editing docs:

- **Never edit `build/`.** It's regenerated; edit `src/`.
- **Never use markdown in frontmatter `description`** — breaks SEO.
- **Always update `src/docs.json`** when adding new pages, or they won't appear in nav.
- **Use Tabler icons only**, never FontAwesome.
- **No nested double quotes** in MDX component attributes.
- **Sentence-case headings** starting with an active verb ("Add a tool", not "Adding a tool").
- **No model aliases** — use full identifiers (e.g., `claude-sonnet-4-6`, not "Claude Sonnet").
- **`@[ClassName]` link map** auto-links the first mention of an SDK class to its reference docs (defined in [`pipeline/preprocessors/link_map.py`](https://github.com/langchain-ai/docs/blob/a623fd54dca3b37d00e004ea6feda5ec338eab67/pipeline/preprocessors/link_map.py)). Use it on first mention only.
- **`make lint_prose`** runs Vale and is required pre-commit. CI blocks on style violations like em-dashes with surrounding spaces (` — ` → `—`).

## Common gotchas

- **`docs.langchain.com` vs. `reference.langchain.com`.** Conceptual / tutorial / how-to → this repo. API reference (signatures, docstrings) → not this repo, see the project's source.
- **Mintlify `.venv` parsing errors.** Running `mint broken-links` from the project root scans `.venv/` and chokes on Python license files. Use `make broken-links-with-anchors` (which builds first then runs the link checker on `build/`), or `cd build && mint broken-links`.
- **Notebooks are discouraged.** `.ipynb` files are converted to Markdown at build time but the repo policy is "PRs adding notebooks will likely be rejected unless asked." Prefer plain `.mdx`.
- **`@[ClassName]` requires the class to be in `link_map.py`.** A new class not yet registered there will render as plain text. Add it to the map when introducing new public surface.
- **The "Open source" navigation has Python and TypeScript dropdowns.** Same tab names per dropdown but different group structures for some tabs (especially Integrations and Learn). When adding pages, find the right product → tab → group in `src/docs.json` first.

## Documentation pointers

- [docs.langchain.com](https://docs.langchain.com) — published site.
- [reference.langchain.com/python](https://reference.langchain.com/python/) — Python API reference (built elsewhere).
- [reference.langchain.com/javascript](https://reference.langchain.com/javascript/) — JS/TS API reference (built elsewhere).
- [chat.langchain.com](https://chat.langchain.com) — RAG bot trained on these docs.
- [Mintlify docs](https://mintlify.com/docs) — for syntax of components like `<Tabs>`, `<Steps>`, `<Note>` used throughout.
