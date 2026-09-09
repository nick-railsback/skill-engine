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

### Batch intake: `--sources-file`

`--sources-file <path>` reads one source per line from a plain-text
file — each line names a URL or a local path — as an alternative to
positional arguments or the interactive loop. Blank lines and lines
starting with `#` are ignored. An optional second, whitespace-separated
column names a branch for that entry (see Step 2.4). Entries from
`--sources-file` are combined with any positional arguments supplied in
the same invocation — both are intaken.

Each `--sources-file` entry's first column is intaken exactly as a
positional argument would be: it runs through the same recognition
table above, with the same kind inference and the same source_id
derivation.

An unreadable, empty, or entirely-comment sources file halts intake
before anything is stamped, with an error naming the path and the
reason. A line that is neither a URL nor an existing path is reported
with its 1-indexed line number and halts intake likewise.

A sources file:

```
# acme's registered sources — one per line, blank lines ignored
https://github.com/acme/widgets
~/work/local-repo dev
```

The following block is illustrative of the accept/reject contract
above — it reads the sources-file path given as its first argument,
skips blank and `#`-comment lines, splits each remaining line into a
source and an optional branch value, and for each source either
accepts it (URL-shaped, or a `~`-expanded path that exists) or rejects
it with a diagnostic naming the path and, for a bad line, its line
number:

```bash
sources_file="$1"
if [ ! -r "$sources_file" ]; then
  printf 'sources file unreadable or missing: %s\n' "$sources_file" >&2
  exit 1
fi
entries=()
line_no=0
while IFS= read -r line || [ -n "$line" ]; do
  line_no=$((line_no + 1))
  [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
  read -r source_col branch_col _ <<<"$line"
  expanded="${source_col/#\~/$HOME}"
  if [[ "$source_col" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]] \
    || [[ "$source_col" =~ ^git@ ]] \
    || [ -e "$expanded" ]; then
    entries+=("$source_col"$'\t'"$branch_col")
  else
    printf 'sources file %s line %d: neither a URL nor an existing path: %s\n' \
      "$sources_file" "$line_no" "$source_col" >&2
    exit 1
  fi
done < "$sources_file"
if [ "${#entries[@]}" -eq 0 ]; then
  printf 'sources file %s has no entries (empty or all comments)\n' "$sources_file" >&2
  exit 1
fi
printf '%s\n' "${entries[@]}"
```

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

**`--branch-default-all` suppresses Step 2.4's per-source prompt:**
every git-managed source that has no branch value yet — no
`--sources-file` entry for it, no earlier answer — is recorded with
`branch` omitted from its entry, the same absent-branch record pressing
Enter produces today, without being prompted. A source that already
carries its own branch column is recorded prompt-free whether or not
`--branch-default-all` is given: the flag only ever suppresses the
source left unanswered, never overrides an explicit column value.
Without `--branch-default-all`, Step 2.4 prompts exactly as described
above for every git-managed source lacking a branch value, regardless
of intake method — positional, paste-loop, or `--sources-file`.

| Step | Prompts with --sources-file + --branch-default-all |
|---|---|
| Step 1 — Intake | 0 |
| Step 2.4 — Confirm branch | 0 |
| Step 2.5 — Confirm contextualizer name | 1 |

With both flags supplied, the only interactive prompt remaining before
Step 3.5 is the Step 2.5 contextualizer-name prompt.

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

## Activation guard — same-slug collision only

The guard runs after the slug is known (Step 2.5) and before anything
is stamped: once the slug is accepted, check whether a contextualizer
with that exact slug already exists, before Step 3 stamps anything:

<!-- doctrine:activation-guard-find:start -->
```bash
slug="$1"
find .claude/skills -mindepth 1 -maxdepth 1 -type d -name "${slug}-context" 2>/dev/null
```
<!-- doctrine:activation-guard-find:end -->

If the match is a non-empty directory, surface a one-line warning
naming the path, list the files that would be overwritten, and pause
for explicit confirmation before continuing. The condition is
files-present, NOT a parseable `research/.research-state.json`: a
corrupted state marker must not bypass this guard, because the
directory may still hold a curated `SKILL.md` and a populated
`research/source-paths.json` that stamping would overwrite. The
`using-skill-engine` router sends both new and corrupt-marker
directories here; either way, existing files pause for confirmation. A
*different* slug's contextualizer existing alongside it is not a
collision — bootstrapping proceeds with no pause.

## Reachability probe — `--probe`

With `--probe`, after the activation guard and before Step 3
(stamping), run the recipe below once per intaken `git-managed` source
(non-`git-managed` sources get no row) and print one table: one row
per URL, `reachable` or `unreachable`, and for unreachable rows the
first line of git's error.

<!-- doctrine:reachability-probe:start -->
```bash
url="$1"
ref="${2:-}"
if [ -z "$ref" ]; then
  ref="HEAD"
fi
err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT
export GIT_TERMINAL_PROMPT=0
unset GIT_ASKPASS SSH_ASKPASS
export GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10'
out="$(git ls-remote -- "$url" "$ref" 2>"$err_file")"
rc=$?
err="$(head -n1 "$err_file")"
if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
  if [ -z "$err" ]; then
    err="no error text was returned"
  fi
  printf 'unreachable\t%s\t%s\n' "$url" "$err"
else
  printf 'reachable\t%s\t\n' "$url"
fi
```
<!-- doctrine:reachability-probe:end -->

Classify unreachable whenever the invocation exits non-zero **or**
returns empty stdout — never on exit code alone. A reachable
repository probed against a nonexistent branch exits zero with nothing
on either stream; that row states plainly that no error text was
returned rather than showing a blank field.

The three environment settings are what make this safe to run
unattended, which is the only way it is ever run: `--sources-file` can
carry dozens of URLs and nobody is watching the terminal. A private
HTTPS repository asks for a username and password; a `git@host:` URL
for a host absent from `known_hosts` asks to confirm a host key; a host
that no longer answers waits out the TCP default. Any one of those
turns the whole probe into a run with no table, no error, and no
indication which URL it is stuck on. `GIT_TERMINAL_PROMPT=0` refuses
the terminal prompt, unsetting the askpass helpers stops git preferring
an inherited GUI credential dialog over that refusal (a configured
`GIT_ASKPASS` is common and defeats `GIT_TERMINAL_PROMPT` on its own),
and `BatchMode=yes` plus a `ConnectTimeout` make SSH fail rather than
ask or wait. Each becomes an ordinary `unreachable` row carrying git's
own error text. What this does not bound is a host that completes a
connection and then stalls mid-transfer; there is no portable timeout
for that, and `--probe` does not claim one.

The table is shown before the confirmation question below it. When
any row is unreachable, ask once:

> `<N>` of `<M>` sources are unreachable (see table above). Continue
> anyway? [y/N]

On decline, nothing is stamped. On consent, every source is stamped
and unreachable sources are excluded from any `--clone-all` seed (see
[`cache-seeding.md`](cache-seeding.md)) — the per-source `[y/N]`
prompt and `--clone-none` are unaffected. Without `--probe`, none of
this runs and intake makes no network call, exactly as today.
