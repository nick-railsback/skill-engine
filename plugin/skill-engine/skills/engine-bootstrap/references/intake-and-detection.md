# Intake and detection

Source-input recognition, auto-detected `id`/`kind`/topology, and the two always-prompted confirmations (branch, contextualizer name).

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
