# Setting up a web-doc source

`web-doc` is the source kind for documentation sites — content that
lives at a URL, not in a git repo. Examples: MkDocs, Quarto,
Docusaurus, Sphinx, GitBook, hand-rolled HTML doc sites.

## Prerequisites

You need a fetch tool the model can call:

- **WebFetch** — Claude Code built-in. Already installed.
- **An MCP fetch server** — community-built; check
  `~/.claude/mcp.json` or your project's MCP config.

If neither is present, `engine-bootstrap` will fail loud with a
pointer to this recipe.

## Adding a web-doc source

1. Run `/skill-engine:engine-bootstrap` and add an entry like:

```json
{
  "id": "inspect-aisi-docs",
  "kind": "web-doc",
  "url": "https://inspect.aisi.org.uk/",
  "crawl_mode": "sitemap",
  "status": "intake"
}
```

2. Bootstrap will discover the sitemap (probes `/sitemap.xml`, then
   `/sitemap_index.xml`, then `robots.txt` `Sitemap:` directive),
   present the resolved page list, and prompt for consent.

3. On `y`, the model crawls each page and writes a snapshot to
   `~/.cache/skill-engine/web-doc/<source_id>-<crawl_id>/`.

## Custom sitemap location

```json
{ "crawl_mode": "sitemap", "sitemap_url": "https://example.com/custom-sitemap.xml" }
```

## Explicit page list (no sitemap)

```json
{ "crawl_mode": "list",
  "page_list": [
    "https://example.com/docs/intro",
    "https://example.com/docs/guide"
  ] }
```

All URLs must share the source `url`'s origin (single-origin invariant).

## Filtering noisy sitemaps

```json
{ "crawl_filters": {
    "include": ["/docs/**"],
    "exclude": ["/docs/changelog/**", "/docs/blog/**"]
  } }
```

## Budget

`crawl_budget` defaults to 200 pages. Raise to 500 for large doc
sites; the ceiling is 5000.

## Decay

The frontmatter `decay` field controls how often REFRESH proposes a
re-crawl. Values: `30d` (30 days), `6m`, `1y`, `none` (crawl-once).
Defaults to `30d`.
