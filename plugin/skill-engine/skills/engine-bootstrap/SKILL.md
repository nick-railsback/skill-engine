---
name: engine-bootstrap
description: Scaffold a new contextualizer from one or more source URLs or local paths.
---

# Engine bootstrap

Scaffold a new contextualizer in the current directory. Take a list of source
URLs or local paths from the user, auto-detect the metadata the engine needs,
stamp the matching template set into place, and exit with a 3-line message
naming the next workflow to run.

The user supplies sources. The engine fills in everything else.

## Installation layout

A contextualizer is stamped as a self-contained Claude Code project skill at:

```
.claude/skills/<slug>-context/
├── SKILL.md
├── verify.sh
├── research/
│   ├── source-paths.json
│   └── .research-state.json
└── references/   (created by /skill-engine:discover later)
```

`.claude/skills/<slug>-context/` is the **contextualizer root**. Every
engine workflow (`discover`, `refresh`, `status`, `self-audit`,
`new-reference`, `using-skill-engine`) resolves `research/...`,
`references/...`, and `verify.sh` relative to this root. The user invokes
slash commands from the project working directory (the parent of
`.claude/`); the workflows locate the root themselves.

## Activation guard

This skill assumes no contextualizer is installed under
`.claude/skills/*-context/` yet.

1. From the project working directory, look for an existing contextualizer:

   ```bash
   find .claude/skills -mindepth 1 -maxdepth 1 -type d -name '*-context' 2>/dev/null
   ```

   If any match is a non-empty directory, surface a one-line warning
   naming the path, list the files that would be overwritten, and pause
   for explicit confirmation before continuing. The condition is
   files-present, NOT a parseable `research/.research-state.json`: a
   corrupted state marker must not bypass this guard, because the
   directory may still hold a curated `SKILL.md` and a populated
   `research/source-paths.json` that stamping would overwrite. The
   `using-skill-engine` router sends both new and corrupt-marker
   directories here; either way, existing files pause for confirmation.

2. Otherwise, proceed.

## Step 1 — Intake

Accept one or more sources from the user. Two intake modes:

- **Positional arguments.** Any non-flag arguments passed to the skill
  invocation are sources, one per argument. `/skill-engine:engine-bootstrap
  https://github.com/vitejs/vite ~/work/myrepo` registers two sources without
  prompting. **When one or more positional arguments are supplied, do not
  enter the interactive loop** — accept all positional inputs and proceed
  directly to Step 2. The bootstrap MUST NOT issue a "paste another URL"
  follow-up after a positional invocation; the user is invoking the
  bootstrap because they already know the sources they want.
- **Interactive loop.** Fires **only** when zero positional arguments were
  supplied. Prompt the user with `Paste a URL or local path; type
  finish when done:` and read until the user types the literal word
  `finish`. The user may type `finish` before supplying any entries
  (which aborts the skill with a one-line "no sources supplied; nothing
  to scaffold" message).

The interactive loop has exactly one documented exit gesture: typing the
literal word `finish`. Earlier revisions of this spec also listed
blank-line submission and Ctrl+D (EOF) as equivalent gestures, but those
don't translate reliably to a chat-driven prompting loop — a blank chat
message ends a turn rather than ending input, and Ctrl+D has no analog
in chat. `finish` is the only reliable signal across Claude Code, Claude
Desktop, and other harnesses.

Accept all of these source-input shapes:

| Input | Recognized as |
|---|---|
| `https://github.com/<org>/<repo>` (with or without trailing `.git`) | git-managed source on GitHub |
| `git@github.com:<org>/<repo>.git` | git-managed source on GitHub (SSH form) |
| `git+ssh://...` | git-managed source (generic SSH) |
| `https://gitlab.com/<group>/<repo>`, `https://bitbucket.org/<user>/<repo>` | git-managed source (other hosts) |
| `https://<host>/<path...>` (any HTTP/HTTPS URL with no git-host signal) | web-doc source (default `crawl_mode: sitemap`) |
| Absolute local path (`/Users/...`, `~/...`, `/home/...`) | local-path source |
| Relative local path (`./foo`, `../bar`, bare `foo` referencing an existing dir) | local-path source (resolved to absolute at intake) |

**The intake step asks exactly one content question** (the URL/path input)
and **zero engine-taxonomy questions.** Do NOT ask for `kind`, `source_id`,
`id`, scope (single- vs multi-domain), or topology (single- vs multi-repo).
Those values are inferred, not solicited.

If a supplied input is ambiguous (e.g., the path looks like a URL but the
scheme is unrecognized, or a URL without a recognizable git host could be
either a git source or a doc site), ask one targeted question in
user-language — never the engine's `kind` value directly. The canonical
disambiguator:

> Is `<input>` a source-code repo or a documentation site?

Accept `repo` / `doc` (or full words) and map internally: `repo` → `kind:
git-managed`, `doc` → `kind: web-doc` (the engine never produces
`kind: external-doc` from URL intake — see *What this skill does NOT do*
below). **On any other response** (blank `<Enter>`, `local`, `quit`,
typo) re-prompt with:

> Please answer `repo` or `doc` — or enter `q` to skip just this entry and
> continue with the rest of the intake.

The `q`-to-skip-just-this-entry escape hatch is intentional: a user
pasting a batch of 10 URLs in the interactive loop should be able to drop
one ambiguous entry without aborting the whole intake. The other 9 still
land in `source-paths.json`.

### Bare GitHub org URL (special edge case)

A URL of the form `https://github.com/<org>` (no `<repo>` segment) is
neither a recognizable git source nor a docs page — it points at an org
landing page. **Don't fall through to the web-doc catch-all**; that
would silently stamp `kind: web-doc` against a URL whose sitemap and
page list the engine cannot meaningfully resolve. Instead, re-prompt:

> `<url>` looks like a GitHub org landing page, not a specific repo or
> doc. Paste the URL of a specific repo (e.g., `https://github.com/<org>/<repo>`)
> — or `q` to skip this entry.

Detection rule: any `https://github.com/…` URL whose path component has
fewer than 2 non-empty segments (i.e., `/<org>` or `/<org>/`) triggers
the re-prompt. URLs with 2+ path segments fall through to the normal
`kind: git-managed` shape.

## Step 2 — Auto-detection

For each accepted source, compute the following without prompting the user:

**`id`** — a deterministic kebab-case slug derived from the input:

| Input shape | Slug rule |
|---|---|
| `https://github.com/<org>/<repo>` | `<org>-<repo>` (lowercase; non-alphanumerics → hyphen; collapse runs) |
| `git@github.com:<org>/<repo>.git` | `<org>-<repo>` (same rule, drop `.git`) |
| `https://<host>/<path...>` (web-doc) | last meaningful path segment, lowercased; if it's a file, drop the extension. If the URL has no path segments (host-root like `https://docs.example.com/`), fall back to the host with non-alphanumerics → hyphen (e.g., `docs-example-com`). |
| Local absolute or relative path | basename of the resolved absolute path, lowercased |

On collision (two sources slug to the same id), append `-2`, `-3`, ... to the
later ones. The user does not see the slug in the prompt copy; the slug is
recorded in `research/source-paths.json` and surfaces in the exit message.

**`kind`** — inferred from input shape per the intake table above. Never
asked directly.

**Topology** — inferred from `len(sources[])` after intake completes. If the
user supplied exactly one source, the contextualizer is single-source; more
than one, multi-source. Monorepo detection (whether a single source is itself
a monorepo with multiple workspace members) is deferred to DISCOVER — not
asked here.

## Step 2.4 — Confirm branch (git-managed sources only)

For each source whose Step-2-inferred `kind` is `git-managed`, ask once
which branch to monitor. The prompt is per-source; non-git sources
(`kind: external-doc`, `kind: local-path`, `kind: web-doc`) skip this
step entirely.

**Prompt copy** (per git-managed source):

> For `<url>`:
> Monitor the repo's default branch? Press Enter or `y` to track HEAD
> (main/master/whatever the repo points at). Or type a branch name
> (e.g. `dev`, `nonprod`, `release/v2`) to monitor that branch instead. [Enter/y = default]

**Response handling:**

| Input | Result |
|---|---|
| Empty, `y`, `Y`, `yes` | Omit `branch` from this source's entry. Downstream REFRESH and DISCOVER fall back to HEAD. |
| Any string matching `^[A-Za-z0-9._/-]+$` | Record `"branch": "<name>"` on this source's entry. |
| Anything else | Re-prompt once with: ``Branch names use letters, digits, dots, underscores, slashes, hyphens. Try again, or press Enter for the default branch. (You can edit `source-paths.json` later to set a specific branch.)`` |

**Why omit-on-default rather than record an explicit default.** Existing
`source-paths.json` files without a `branch` field stay valid (the schema
is additive). If the upstream repo's default branch is later renamed,
the absent-field record stays correct — an explicit `"branch": "main"`
would silently rot. Step 2.4 makes no network call: default-branch
resolution happens lazily at REFRESH / DISCOVER time via the standard
git-CLI `HEAD` lookup, not at bootstrap. A typed non-default branch
name is recorded as-given; its existence on the upstream is validated
when REFRESH / DISCOVER first runs against the source.

**No re-confirmation later.** The branch can always be edited manually
in `source-paths.json` after bootstrap (the engine re-reads the file on
every invocation). A future revision may add a `/skill-engine:set-branch`
helper; for now manual edit is the documented path.

## Step 2.5 — Confirm the contextualizer name (always prompted)

After Step 2 derives a slug, ask the user once for the contextualizer
name. The user types only the short kebab-case name; the engine appends
`-context` for the directory name and the navigator skill name.

**Default derivation** (offered as the bracketed default in the prompt):

- 1 source → the source's `id` (e.g., `vitejs-vite`).
- 2+ sources with a common kebab-case prefix ≥ 3 chars → that prefix
  (e.g., `langchain-ai`).
- 2+ sources with no useful common prefix → no default; prompt without
  one.

**Prompt copy**:

> Name your contextualizer (kebab-case; the engine appends `-context`)
> [default: `<auto-slug>`]:

When no default is available, drop the bracketed clause:

> Name your contextualizer (kebab-case; the engine appends `-context`):

**Validation**: the response must match `^[a-z][a-z0-9-]*$`. On invalid
input (or empty input with no default), re-prompt with the same hint and
the same default. Empty input with a default present accepts the default.

The user is asked to **name their own thing**, not to type an engine
taxonomy value, so this single prompt does not violate the
no-engine-taxonomy rule. The auto-derived default is usually correct; the
prompt exists so the user can override before the directory is stamped
(renaming after the fact has to update both the directory name AND the
navigator's `name:` frontmatter, and Claude Code skill-name resolution is
name-keyed — duplicate `<name>-context` navigators across sibling
directories resolve non-deterministically).

The accepted name becomes the **`<contextualizer-slug>`** used in Step 3.

## Step 3 — Stamping

**Bootstrap writes directly to the live tree.** Unlike DISCOVER and
REFRESH, which stage their writes to `<slug>-context.proposed/` for
explicit user review before promotion (see `discover/SKILL.md` §
Staging directory), bootstrap stamps straight into
`.claude/skills/<slug>-context/`. There is nothing to review yet — the
user has explicitly invoked bootstrap to scaffold a fresh
contextualizer from templates, and there is no pre-existing live tree
to diff against. The staging-dir model exists to prevent silent
overwrites of curated state; bootstrap's first-stamp is not that.

Copy the following files from the plugin's `engine-bootstrap-templates/`
directory into `.claude/skills/<contextualizer-slug>-context/` under the
project working directory, preserving line endings as-is (LF-only in the
bundle).

- `verify.sh` → `.claude/skills/<contextualizer-slug>-context/verify.sh`
  (mark executable: `chmod +x .claude/skills/<contextualizer-slug>-context/verify.sh`)
- Choose the navigator template based on the inferred topology:
  - 1 source → `navigator.md.template` → `.claude/skills/<contextualizer-slug>-context/SKILL.md`
  - 2+ sources → `navigator-multi-domain.md.template` → `.claude/skills/<contextualizer-slug>-context/SKILL.md`
- `source-paths.json.template` → `.claude/skills/<contextualizer-slug>-context/research/source-paths.json`
- `research-state.json.template` → `.claude/skills/<contextualizer-slug>-context/research/.research-state.json`

Create the parent directories (`.claude/skills/<contextualizer-slug>-context/`,
`.claude/skills/<contextualizer-slug>-context/research/`) as part of the
stamp.

**If a stamp write is rejected** — a denied `cp` / `mkdir -p` / `chmod`,
or a non-zero / `EPERM` exit under a restricted sandbox on a
`.claude/skills/<contextualizer-slug>-context/` path — do not retry
blindly or skip the file. Emit the sandbox-block diagnostic per
[`04-delivery.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/04-delivery.md)
§ "When a `.claude/skills/**` write is blocked": name the exact path, the
scoped `sandbox.filesystem.allowWrite` (or remove-`deny`) remedy, the
literal failed command, and the retry (`/skill-engine:engine-bootstrap`).

All `research/...` references below resolve under the contextualizer
root (`.claude/skills/<contextualizer-slug>-context/`). The user does not
need to `cd` into that directory to use the engine — every workflow
locates the root itself from the project working directory.

### Stamping `research/source-paths.json`

Replace the empty `"sources": []` from the template with one entry per
intaken source, in the order supplied. The per-entry shape depends on
`kind`:

**`kind: "git-managed"`** — set `url`; add `"branch": "<name>"` only if
Step 2.4 recorded a non-default branch:

```json
{
  "id": "<computed-slug>",
  "kind": "git-managed",
  "url": "<original-url>",
  "status": "intake",
  "archived": false,
  "lifecycle": { "state": "unknown", "last_checked": null, "last_checked_sha": null, "proposed_url": null },
  "discovered_via": null
}
```

**`kind: "web-doc"`** — set `url`; default `crawl_mode` to `"sitemap"`.
Bootstrap does not resolve the sitemap or page list here; Step 3.6
populates the cache and the optional `sitemap_url` / `page_list` fields
remain absent until the user edits them (or DISCOVER proposes them):

```json
{
  "id": "<computed-slug>",
  "kind": "web-doc",
  "url": "<original-url>",
  "crawl_mode": "sitemap",
  "status": "intake",
  "archived": false,
  "lifecycle": { "state": "unknown", "last_checked": null, "last_checked_sha": null, "proposed_url": null },
  "discovered_via": null
}
```

**`kind: "local-path"`** — set `path` to the resolved absolute path:

```json
{
  "id": "<computed-slug>",
  "kind": "local-path",
  "path": "<resolved-absolute-path>",
  "status": "intake",
  "archived": false,
  "lifecycle": { "state": "unknown", "last_checked": null, "last_checked_sha": null, "proposed_url": null },
  "discovered_via": null
}
```

Bootstrap does **not** produce `kind: "external-doc"` entries: that kind
is for pre-curated local `.md` content addressed by a contextualizer-
internal `path`, not for a URL the user pastes at intake. External-doc
entries land in `source-paths.json` via DISCOVER or hand-edit.

`schema_version: 1` from the template stays as-is. The schema is additive;
existing v1 files continue to parse cleanly.

### Stamping the navigator template

The navigator templates ship with **derived placeholders, not user-typed
ones.** Replace each `<contextualizer-slug>` token with the inferred slug
(see *Slug derivation* below). The `<area-domain>` / `<Area Domain>` /
`<topic-N>` tokens from the pre-8.1 templates are **eliminated** — see
"Placeholder elimination" below.

#### Slug derivation

The contextualizer slug is derived in Step 2 (as a default) and confirmed
or overridden by the user in Step 2.5. By the time stamping runs, the
slug is the user-confirmed name from Step 2.5; the navigator skill name
is `<slug>-context`.

#### Placeholder elimination

Earlier-generation navigator templates contained four placeholder tokens
that demanded manual fill-in: `<area-domain>`, `<Area Domain>`,
`<topic-N>`, `<domain-N>`. These are **eliminated**. Concretely:

- The `description:` frontmatter field is stamped with a generic line
  ("Answers questions about the `<sources-summary>` ecosystem. References
  load on demand from `references/`.") where `<sources-summary>` is the
  source-id list (1 source) or "the configured sources" (2+). The user is
  encouraged in the exit message to tighten the description after the first
  DISCOVER run produces a catalog.
- The Catalog table starts **empty** with a one-line note: "No references
  yet. Run `/skill-engine:discover` to populate this catalog."
- Catalog rows that referenced `<area-domain>-<topic-N>` are simply not
  stamped; they appear after DISCOVER's first run emits reference files.
- The Cross-reference map and Cross-domain map sections start with a single
  italicized "(populated as references accumulate)" placeholder line — not
  a templated row.

The principle: **a fresh-stamped contextualizer is a valid skill** (loads,
parses, lints clean) — it just has no catalog yet because DISCOVER hasn't
run. The user fills the catalog by running DISCOVER, not by hand-editing
placeholder rows.

### Stamping `verify.sh`

The `verify.sh` shipped in `engine-bootstrap-templates/verify.sh` is the
**contextualizer-flavored variant** — it audits the stamped contextualizer's
own artifacts (navigator file shape, source-paths.json schema, catalog
bijection, etc.), not the engine-authoring repo it came from. This resolves
an earlier friction in which an engine-authoring check suite was stamped raw
into fresh contextualizers and then failed for missing sibling `.template`
files.

**Expected first-run output** on a fresh-stamped contextualizer with no
DISCOVER run: `Passed: N, Failed: 0`, where catalog-bijection and reference-
shape checks are skipped with `[N/A]` (not `[FAIL]`) because no references
exist yet. After the first DISCOVER run populates references and the
catalog, those checks become live.

## Step 3.5 — Offer to seed local cache

After stamping completes, iterate over the intaken sources filtered to
`kind: git-managed`. For each such source, prompt the user **once**:

```
Pre-clone <source_id> from <url> into ~/.cache/skill-engine/git-managed/?
This speeds up later DISCOVER runs. Skip if unsure. [y/N]
```

Accept `y` or `yes` (case-insensitive, leading/trailing whitespace
trimmed) as consent. Treat `N`, blank input, or anything else as
decline; do not re-prompt.

On consent, clone via an atomic-rename idiom so a failed or interrupted
clone does not leave a half-written cache directory at the canonical
path:

```bash
# Guard: refuse a source_id that is not a safe path component, so a crafted
# id (e.g. one containing '/' or '..') cannot escape the cache directory
# when interpolated into `dest` below. source_id is kebab-case by
# construction; assert it before building any path. On a bad id, skip THIS
# source's cache seed — do not exit, so a multi-source intake does not lose
# every later source to one bad id.
case "<source_id>" in
  ""|-*|*[!a-z0-9-]*)
    echo "skill-engine: refusing unsafe source_id '<source_id>' — skipping cache seed for this source" >&2 ;;
  *)
    # `--` terminates git option parsing, so a URL beginning with '-' cannot be
    # interpreted as a flag (e.g. --upload-pack=...), closing an argument-
    # injection vector on the user-supplied url.
    sha=$(git ls-remote -- "<url>" HEAD | cut -f1)
    if [ -z "$sha" ]; then
      # Empty SHA (unreachable repo, flaky ls-remote): building `<source_id>-`
      # would land a cache path no later `<source_id>-<sha>` lookup matches.
      # Skip the seed for this source instead.
      echo "skill-engine: couldn't resolve <source_id> HEAD (empty ls-remote) — skipping cache seed for this source" >&2
    else
      mkdir -p ~/.cache/skill-engine/git-managed/
      dest="$HOME/.cache/skill-engine/git-managed/<source_id>-$sha"
      tmpdir="${dest}.tmp.$$"
      if git clone --depth=1 --filter=blob:none -- "<url>" "$tmpdir"; then
        mv "$tmpdir" "$dest"
      else
        rm -rf "$tmpdir"
      fi
    fi ;;
esac
```

The `$$` PID tag scopes `tmpdir` per-process; two concurrent bootstraps
against the same source land in distinct tmpdirs and neither corrupts
the other. The final `mv` is atomic on a single filesystem, so the
canonical `<source_id>-<sha>/` directory either exists complete or does
not exist at all — DISCOVER's pre-flight checks for `.git/` inside the
directory before treating it as a warm cache (see
[`08-discover-pipeline.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/08-discover-pipeline.md)).

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

## Step 4 — Exit

After stamping completes, render exactly four lines to the user (substitute
the actual source count, the first id, and the user-confirmed slug; for
2+ sources, use a phrasing that summarizes the set):

```
Bootstrap complete. <N> source<s?> registered: <id-1[, id-2[, ...]]>.
Contextualizer stamped at .claude/skills/<slug>-context/.
Run /skill-engine:discover next — it'll scan each source and propose how to slice it.
Run /skill-engine:status anytime to see what's registered.
```

For 4+ sources, render `<id-1>, <id-2>, ... (N total)` rather than the full
list.

**State-aware next-step recommendation.** The bootstrap exit message
recommends `discover` because bootstrap's exit state (sources registered,
no references yet) is exactly the precondition DISCOVER needs. DISCOVER
is goal-given: it accepts a fresh contextualizer as its first task and
returns reference files that satisfy the four reference invariants — no
separate "warm-up" step required.

**Do NOT** in the exit message:

- Recommend a workflow whose precondition wasn't produced by bootstrap.
- Tell the user to edit `.claude/skills/<slug>-context/research/source-paths.json`
  by hand — auto-detection already populated it; manual edits are a
  fallback, not a default.
- Surface engine taxonomy (kind, topology, scope) the user wasn't asked
  about.

## Doctrine surface

The full scaffolder contract — what each stamped file means, how it evolves,
how a contextualizer transitions across major plugin revisions — is
documented in [`10-version-evolution.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/10-version-evolution.md). The artifact contract every
stamped file must satisfy is in [`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md). The DISCOVER
posture (goal-given delegation) is documented in
[`08-discover-pipeline.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/08-discover-pipeline.md).

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

The engine does not clone without consent. Two consent points exist:

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

## What this skill does NOT do

- It does not crawl, fetch, or probe upstream for content. The only
  network operation bootstrap performs is the explicit user-consented
  `git clone` in Step 3.5, and it writes solely to
  `~/.cache/skill-engine/git-managed/<source_id>-<sha>/`. Lifecycle probes and
  content crawls belong to DISCOVER and REFRESH (see
  [`08-discover-pipeline.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/08-discover-pipeline.md)).
- It does not propose additional sources or expand source coverage —
  those belong to DISCOVER.
- It does not validate the existence or reachability of supplied sources at
  intake. If the user pastes a broken URL or a path that doesn't exist,
  bootstrap stamps the entry anyway and the lifecycle probe on the first
  DISCOVER run surfaces the issue. (The Step 3.5 clone offer may also
  reveal the URL is broken — but its failure mode is a one-line
  "couldn't clone" notice; it does not gate intake.) Failing fast at
  intake would force a multi-source intake to abort halfway; failing on
  DISCOVER lets the user paste the whole list and address broken entries
  in batch.
- It does not produce `kind: "external-doc"` entries. external-doc
  sources are pre-curated local markdown addressed by a contextualizer-
  internal `path` (see [`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md#kind-external-doc)); they arrive in `source-paths.json`
  via DISCOVER or hand-edit, not via URL intake.
