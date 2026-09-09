# Cache seeding

The consent-gated local cache offers for git-managed and web-doc sources — the only network operations bootstrap performs absent `--probe` — plus the manual-materialization fallback.

## Step 3.5 — Offer to seed local cache

Two flags govern this step for every git-managed source in one
gesture, checked before any per-source iteration begins:

- **`--clone-all`** runs the consented-clone path below for every
  git-managed source, no prompt — except a source `--probe` flagged
  unreachable, which this step skips even under `--clone-all`.
- **`--clone-none`** skips the cache seed for every git-managed
  source, no prompt, no clone attempt.
- With neither flag, the per-source `[y/N]` prompt below fires
  exactly as it does today — cloning remains the only network
  operation this step performs absent `--probe`, which runs its own
  reachability check earlier, at intake.

<!-- doctrine:clone-consent-guard:start -->
```bash
clone_all=0
clone_none=0
for arg in "$@"; do
  case "$arg" in
    --clone-all) clone_all=1 ;;
    --clone-none) clone_none=1 ;;
  esac
done
if [ "$clone_all" -eq 1 ] && [ "$clone_none" -eq 1 ]; then
  echo "skill-engine: --clone-all and --clone-none cannot both be set; choose one." >&2
  exit 1
fi
exit 0
```
<!-- doctrine:clone-consent-guard:end -->

If both flags are given together, the guard above halts before any
clone or prompt runs, with an error naming both flags.

After stamping completes, iterate over the intaken sources filtered to
`kind: git-managed`. Under `--clone-all`, first drop any source
`--probe` flagged unreachable from that iteration entirely — no clone
attempt for it — before running the consented-clone path on the rest;
this exclusion is specific to `--clone-all`'s blanket consent, and does
not change the per-source prompt (no flags) or `--clone-none` below.
For each remaining such source, prompt the user **once**:

```
Pre-clone <source_id> from <url> into ~/.cache/skill-engine/git-managed/?
This speeds up later DISCOVER runs. Skip if unsure. [y/N]
```

Accept `y` or `yes` (case-insensitive, leading/trailing whitespace
trimmed) as consent. Treat `N`, blank input, or anything else as
decline; do not re-prompt.

On consent, clone via `cache-git.sh` — the shipped helper that owns every
cache-mutating git invocation, so an atomic-rename idiom (a failed or
interrupted clone never leaves a half-written cache directory at the
canonical path), the unsafe-`source_id` guard, and the `SKILL_ENGINE_CACHE_ROOT`
override live in one place instead of once per recipe:

```bash
"$CLAUDE_PLUGIN_ROOT/bin/cache-git.sh" clone "<source_id>" "<url>"
```

On a refused `source_id` (not a safe path component — kebab-case only) or
an empty `git ls-remote` (unreachable repo, flaky network), `cache-git.sh`
prints a one-line diagnostic to stderr and exits non-zero; skip THIS
source's cache seed and continue to the next one — do not abort a
multi-source intake over one bad source. On success, the clone lands at
`${SKILL_ENGINE_CACHE_ROOT:-$HOME/.cache/skill-engine}/git-managed/<source_id>-<sha>/`
— DISCOVER's pre-flight checks for `.git/` inside the directory before
treating it as a warm cache (see
[`08-discover-pipeline.md`](../../../docs/08-discover-pipeline.md)).

Substitute `<url>` and `<source_id>` from the source entry. On success,
emit one line naming the resulting path:

```
Cloned <source_id> → ~/.cache/skill-engine/git-managed/<source_id>-<sha>/
```

On clone failure (network error, auth failure, missing repo, `git
ls-remote` returning empty), the `rm -rf "$tmpdir"` branch above removes
any partial state, then emit one line and **continue to the next
source**:

```
Couldn't clone <source_id>; you can retry manually — see "Source materialization" below.
```

Do not abort bootstrap on a cache failure: the contextualizer is fully
usable without a cache, and a multi-source intake should not lose later
sources because of one bad clone.

**Sparse variant.** When the source entry's `files_of_interest` field is
present and non-empty, substitute the recipe below for the block above —
the clone becomes scoped to those path patterns instead of the
unconditional shallow clone. **Every `files_of_interest` entry must stay
double-quoted** — an unquoted glob is subject to shell expansion before
git ever sees it (harmless in bash when nothing matches, a hard "no
matches found" abort under zsh), and quoting is what turns the pattern
into an inert literal string in either shell:

```bash
"$CLAUDE_PLUGIN_ROOT/bin/cache-git.sh" sparse-clone "<source_id>" "<url>" HEAD -- <files_of_interest entries...>
```

Substitute `<files_of_interest entries...>` the same way the block above
substitutes `<url>` and `<source_id>` — one double-quoted token per array
entry, space-separated. On success, emit the same one-line confirmation
the block above emits (`Cloned <source_id> → ...`).

On a `files_of_interest` entry that matches nothing in the checkout,
`cache-git.sh` prints `files_of_interest entry '<entry>' resolved no files
in checkout`, names the nearest sibling directories under that entry's
closest existing ancestor, and discards the clone: skip this source and
carry on with the next one, do not abort the bootstrap. A validation
failure needs no separate summary line — `missing=1` routes to `rm -rf`
inside the helper exactly like every other per-source failure in this file
(empty SHA, refused id).

The existence check `cache-git.sh` runs is `git -C "$tmpdir" ls-files --
"$entry"` — a tree-aware pathspec match against the post-checkout index —
rather than a raw `[ -e "$tmpdir/$probe" ]` filesystem test, because a
filename-glob entry like `docs/*.md` (the doctrine text's own
"gitignore-style patterns" wording covers this shape, not only `X/**`)
has no glob-stripped literal path to test for existence — an `-e` check
would false-reject a *valid* entry of that shape. `ls-files` is
unconditionally allowed by doctrine check 4 (unlike
`sparse-checkout`/`checkout`), so it needs no cache-scoped `-C` literal —
plain `"$tmpdir"` is fine there.

For sources whose `kind` is `external-doc`, `local-path`, or `web-doc`,
do not prompt in this step — `external-doc` and `local-path` need no
cache facilitation, and `web-doc` is seeded by Step 3.6 instead.

This is the **only** network operation `engine-bootstrap` performs, and
it runs only with explicit per-source consent. The "engine does not
crawl, fetch, or probe upstream" stance is preserved for *content*:
bootstrap reads no source content here, validates no source's
reachability, and probes no lifecycle state. It writes only to
`~/.cache/skill-engine/git-managed/<source_id>-<sha>/`, the
user-consented path.

## Step 3.6 — Offer to seed local cache for web-doc sources

For each registered source with `kind: "web-doc"`, resolve the page list
and offer to crawl now.

### 1. Detect a fetch tool

The crawl is performed by the model via the user's installed fetch
tool. Check tool availability in this order:

1. `WebFetch` (Claude built-in) — assumed present in Claude Code.
2. Any `mcp__fetch__*` tool — surfaced by the user's MCP configuration.

If NEITHER is present, **fail loud**:

```
No fetch tool detected. web-doc sources require WebFetch (Claude built-in)
or an MCP fetch server. See docs/recipes/web-doc-setup.md for setup.
Skipping web-doc seed for this bootstrap; sources remain at status: intake.
```

### 2. Resolve the page list

For each web-doc source:

- **`crawl_mode: "sitemap"`** — discover the sitemap in this order:
  1. `sitemap_url` field if set.
  2. `{url}/sitemap.xml`
  3. `{url}/sitemap_index.xml`
  4. `{url}/robots.txt` and parse any `Sitemap:` directives.

  Fetch the resolved sitemap. If it's a sitemap-index, fetch each child
  sitemap (depth-1; nested indexes are a config violation — surface as
  warning and proceed with what you have). Apply `crawl_filters.include`
  and `crawl_filters.exclude` (default `{ include: ["/**"], exclude: [] }`).
  Truncate to `crawl_budget` (default 200). Truncated pages are reported,
  not silently dropped.

- **`crawl_mode: "list"`** — use `page_list[]` directly. No discovery.

### 3. Fetch robots.txt once

Fetch `{url}/robots.txt` (User-Agent `*`). Identify any `Disallow:`
paths that overlap the resolved page list. Drop those pages. Note
`Crawl-delay:` if present (cap at 10 seconds; warn if higher).

### 4. Present the consent prompt

```
Resolved <N> pages from <sitemap_url-or-page_list> for <source_id>.
Robots disallows <M> paths (excluded from crawl).
Budget truncated <K> pages (raise crawl_budget to include them).
First 5 pages: <url1>, <url2>, <url3>, <url4>, <url5>

Crawl <N> pages now? This pre-seeds
~/.cache/skill-engine/web-doc/<source_id>-<crawl_id>/ for DISCOVER
and future REFRESH cycles. Skip if unsure. [y/N]
```

On `n`: source is registered, cache stays empty. DISCOVER will reprompt
on miss. The choice is per-source, not session-sticky.

### 5. Execute the crawl

On `y`, for each URL in the resolved list:

1. Fetch via the chosen tool.
2. Confirm response is non-empty and looks like content (>500 bytes
   after frontmatter, not a JS-rendered shell).
3. Slugify the URL path to a filename (e.g. `/docs/intro` →
   `docs-intro.md`; URL-decode and replace `/` with `-`).
4. Write the file to `~/.cache/skill-engine/web-doc/<source_id>-<crawl_id>/`
   with frontmatter:

   ```markdown
   ---
   source_url: <fetched URL>
   crawl_date: <ISO-8601 UTC, the start of this run>
   decay: <inherited from source-paths.json entry, default "30d">
   ---
   ```

5. Record the page's content_hash and any fetch errors in
   `_crawl-manifest.json`.

`crawl_id` is computed AFTER all pages are fetched:
`sha256(sorted-page-urls || concatenated-page-content-hashes)[:8]`. The
final directory is named with this `crawl_id`; the snapshot is initially
written to a `<source_id>-tmp.<PID>/` directory and atomically renamed
on success.

If a fetch fails: log to `_crawl-manifest.json`'s `failures[]` and
continue. Do not retry. Do not parallelize. Do not follow links beyond
the supplied list.

### 6. Update `source-paths.json`

After a successful crawl, update the source's lifecycle:

```json
"lifecycle": {
  "state": "reachable",
  "last_checked": "<ISO-8601 UTC>",
  "last_crawl_id": "<8-char hex>",
  "proposed_url": null
}
```

### `_crawl-manifest.json` schema

```json
{
  "source_id": "<id>",
  "crawl_id": "<8-char hex>",
  "crawl_date": "<ISO-8601 UTC>",
  "fetcher": "<WebFetch | mcp__fetch__fetch | …>",
  "sitemap_source": "<URL or 'page_list'>",
  "pages": [
    {"url": "https://...", "file": "docs-intro.md", "content_hash": "...", "bytes": 4382}
  ],
  "failures": [
    {"url": "https://...", "reason": "404", "occurred_at": "<ISO-8601 UTC>"}
  ],
  "robots_disallows": ["/admin/*", "/login"],
  "budget_truncated": 12
}
```

## Source materialization (optional local cache)

For large `kind: git-managed` sources, DISCOVER reads more efficiently
from a local clone than from remote `gh`/`git` calls. The recommended
cache location is:

```
~/.cache/skill-engine/git-managed/<source_id>-<sha>/
```

This follows the XDG cache-directory convention (`~/.cache/<tool>/`)
used by `gh`, `cargo`, and most modern CLI tooling on macOS and Linux.
`source_id` is the entry's id from `research/source-paths.json` and
`<sha>` is the upstream HEAD SHA at the time of clone.

The engine does not clone without consent. Two consent points exist —
plus `--clone-all`, which consents on behalf of every source at once
instead of one at a time:

- **Step 3.5 above** prompts once per git-managed source at bootstrap
  time and clones on `y`.
- **Step 3.6 above** prompts once per web-doc source at bootstrap to
  seed the snapshot cache.
- **DISCOVER's pre-flight** re-prompts when it detects a cache miss for
  a registered git-managed source (declined at bootstrap, deleted via
  `/skill-engine:clean-cache`, or added post-bootstrap).

If the cache directory exists when DISCOVER starts, it reads locally;
if absent and the user declines the re-prompt, DISCOVER falls back to
`gh`/`git`/WebFetch per its tool-preference rule. The user retains the
option to clone manually at any time (or to chose a different
location) — the engine's clone is a convenience, not a requirement.

The cache amortizes across REFRESH runs and survives sessions. REFRESH
garbage-collects older `<source_id>-<old-sha>/` directories when it
fetches a newer SHA for the same `source_id`; the user can also delete
the cache explicitly via `/skill-engine:clean-cache`.
