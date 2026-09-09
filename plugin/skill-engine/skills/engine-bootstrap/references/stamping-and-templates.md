# Stamping and templates

What Step 3 copies into the live tree, the per-kind `source-paths.json` entry shapes, navigator-template placeholder elimination, and the contextualizer-flavored `verify.sh`.

## Step 3 — Stamping

**Bootstrap writes directly to the live tree.** Unlike DISCOVER and
REFRESH, which stage their writes to `<slug>-context.proposed/` for
explicit user review before promotion (see
`discover/references/staging-and-contextualizer-model.md`
§ Staging directory), bootstrap stamps straight into
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
- `eval/*.template` (3 files, `.template` suffix stripped, both `.sh`
  files marked executable) → `.claude/skills/<contextualizer-slug>-context/evals/`
  — see *Stamping `evals/`* below

Create the parent directories (`.claude/skills/<contextualizer-slug>-context/`,
`.claude/skills/<contextualizer-slug>-context/research/`,
`.claude/skills/<contextualizer-slug>-context/evals/`) as part of the
stamp.

**If a stamp write is rejected** — a denied `cp` / `mkdir -p` / `chmod`,
or a non-zero / `EPERM` exit under a restricted sandbox on a
`.claude/skills/<contextualizer-slug>-context/` path — do not retry
blindly or skip the file. Emit the sandbox-block diagnostic per
[`04-delivery.md`](../../../docs/04-delivery.md)
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

### Stamping `evals/`

Copy the three eval templates from `engine-bootstrap-templates/eval/`
into `.claude/skills/<contextualizer-slug>-context/evals/`, `.template`
suffix stripped and the `<area-domain>` placeholder replaced with
`<contextualizer-slug>-context` — the same substitution the navigator
template gets (see *Stamping the navigator template* above):

- `eval/run-eval.sh.template` → `evals/run-eval.sh` (mark executable:
  `chmod +x`)
- `eval/eval-viewer.html.template` → `evals/eval-viewer.html`
- `eval/render-eval-results.sh.template` → `evals/render-eval-results.sh`
  (mark executable: `chmod +x`)

Then write `evals/evals.json`: a single file (schema_version 1) — not
the train/test split `12-evaluation.md` reserves for eval sets over ten
entries — seeded with exactly one entry per source registered in
`research/source-paths.json`, in registration order:

```json
{
  "schema_version": 1,
  "entries": [
    {
      "query": "What does <source-id> cover?",
      "expected": "<source-id>",
      "notes": "Bootstrap-seeded placeholder — <source-id> is not a real reference filename. Correct `expected` to the actual reference this query should route to once /skill-engine:discover has populated references/."
    }
  ]
}
```

Substitute each registered source's own `id` for every `<source-id>`
above — one object in `entries` per source. Each entry's three fields:

- `query` — contains the source's `id` as a substring.
- `expected` — set to the source's own `id`, unchanged.
- `notes` — flags the entry as a bootstrap-seeded placeholder and says
  to correct `expected` to a real reference filename once
  `/skill-engine:discover` has populated `references/`.

This is a starting scaffold, not a finished eval set;
[`docs/12-evaluation.md`](../../../docs/12-evaluation.md) documents it
as exactly that.
