---
name: discover
description: When the user wants the engine to discover the essence of registered sources and emit reference files. Suitable for first runs against a fresh contextualizer and for recurring rediscovery against a maturing one. The engine hands you a task and validates your output via the four reference invariants and verify.sh.
---

# Discover

You receive a task: **discover the essence of the registered sources,
then write reference files for the parts that matter**. The engine
validates your output via the four reference invariants and the named
checks in `verify.sh`. How you reason about the corpus is your call —
there is no Stage 0/1/2 prescription, no fixed keystroke menu, no
required worker dispatch. Vary your approach by what the corpus
rewards.

## Contextualizer root

Engine workflows operate inside a contextualizer installed as a project
skill at `.claude/skills/<slug>-context/`. Every path below —
`research/...`, `references/...`, `verify.sh` — resolves relative to that
directory.

Before reading or writing anything, locate the root from the project
working directory:

```bash
ctx_roots=$(find .claude/skills -mindepth 1 -maxdepth 1 -type d -name '*-context' 2>/dev/null)
n=$(printf '%s\n' "$ctx_roots" | grep -c .)
if [ "$n" -eq 0 ]; then
  echo "No contextualizer found under .claude/skills/*-context/. Run /skill-engine:engine-bootstrap first."
  exit 1
elif [ "$n" -gt 1 ]; then
  echo "Multiple contextualizers under .claude/skills/; specify one:"
  printf '%s\n' "$ctx_roots"
  exit 1
fi
CTX_ROOT="$ctx_roots"
```

Read every subsequent `research/foo` path as `$CTX_ROOT/research/foo`,
every `references/foo` as `$CTX_ROOT/references/foo`, and `verify.sh` as
`$CTX_ROOT/verify.sh`.

## Output contract

Two things, both load-bearing:

1. **Reference files in `references/`.** Each cites its source by path
   plus content-hash (see [`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md)). Each
   satisfies the four reference invariants:
   - **first-5K** — the first 5K bytes of every reference are
     self-contained enough to anchor a follow-up search.
   - **depth-1** — no more than one level of pointer indirection.
   - **max-100-line-TOC** — the navigator catalog stays under 100 lines.
   - **SHA-pin** — every citation pins to a specific SHA, not a moving
     branch or tag.
2. **A post-run summary** for the author (see "Post-run summary" below).

`verify.sh` is the trust mechanism. Variance below the invariant floor
is acceptable and expected — two sessions on the same corpus may
produce different reference counts, different topical partitions,
different prose styles. The invariants plus the named checks are what
bind quality.

## Pre-flight

When `/skill-engine:discover` is invoked:

1. **Locate state.** Read `research/source-paths.json`. If the file is
   missing, unparseable, or `sources[]` is empty, render:

   ```
   No sources registered. Run /skill-engine:engine-bootstrap first.
   ```

   and exit cleanly.

2. **Identify in-scope sources.** A source is in-scope if:
   - `archived: false` (or field absent — defaults to false),
   - `lifecycle.state ∈ {reachable, unknown}` (`removed` is skipped;
     `moved` surfaces for user accept but is not crawled until the URL
     is updated),
   - `status ∈ {intake, proposed, confirmed}` (rejected is skipped).

3. **Targeted invocation.** If a positional argument matches a
   registered source id (e.g., `/skill-engine:discover vitejs-vite`),
   narrow scope to that source. An unmatched argument → render an
   error naming the supplied id and listing registered ids, then exit.

4. **Hint passthrough.** A `--hint='<hint>'` argument provides extra
   context for the current session (e.g., `--hint='you missed
   packages/plugin-vue'`, `--hint='include docs/guide/ at high
   priority'`). Treat hints as authoritative author input that shapes
   your discovery emphasis.

5. **Idempotency check (no-op gate).** Before re-reading any source,
   check `research/.discover-cache.json` (gitignored runtime state)
   against current upstream SHAs. If every in-scope source's SHA is
   unchanged since its last cache entry AND no `--hint` argument was
   supplied this run, summarize "no work to do" in the post-run summary
   and exit cleanly. Repeated DISCOVER invocations against an unchanged
   corpus should not churn. (A hint always overrides the gate — it
   signals the author wants a re-look at fixed inputs.)

6. **Cache-miss offer (per in-scope git-managed source).** For each
   in-scope source with `kind: git-managed`, probe for an existing local
   clone — and require that the matched directory actually contain a
   `.git/` subdirectory before treating it as a warm cache:

   ```bash
   cache_dir=$(ls -d ~/.cache/skill-engine/<source_id>-*/ 2>/dev/null | head -n1)
   if [ -n "$cache_dir" ] && [ -d "${cache_dir%/}/.git" ]; then
     # cache hit — skip prompt
   else
     # cache miss — prompt the user
   fi
   ```

   The `.git/` presence check defends against a half-written directory
   that lacks a usable repo (e.g., a clone that failed mid-fetch in an
   older run before the atomic-rename idiom landed in
   `engine-bootstrap/SKILL.md` Step 3.5, or a manual `mkdir` the user
   left behind). A bare directory match without `.git/` is treated as
   a cache miss, the same as no directory at all.

   If no match exists, prompt the user **once**:

   ```
   No local cache for <source_id>. Pre-clone from <url> into
   ~/.cache/skill-engine/? This speeds up this DISCOVER run and
   future REFRESH cycles. Skip if unsure. [y/N]
   ```

   Accept `y` or `yes` (case-insensitive, leading/trailing whitespace
   trimmed) as consent. Treat `N`, blank input, or anything else as
   decline.

   On consent, clone via the same atomic-rename idiom used by
   `engine-bootstrap/SKILL.md` Step 3.5 so a failed or interrupted
   clone does not leave a half-written cache directory at the canonical
   path. The `<ref>` token below resolves to the source entry's
   `branch` field if present, else `HEAD`. The `--branch` flag on
   `git clone` is included only when an explicit branch is set:

   ```bash
   # ref = source entry's "branch" if present, else HEAD
   sha=$(git ls-remote "<url>" "<ref>" | cut -f1)
   mkdir -p ~/.cache/skill-engine/
   dest="$HOME/.cache/skill-engine/<source_id>-$sha"
   tmpdir="${dest}.tmp.$$"
   if [ "<ref>" = "HEAD" ]; then
     git clone --depth=1 --filter=blob:none "<url>" "$tmpdir"
   else
     git clone --depth=1 --filter=blob:none --branch "<ref>" "<url>" "$tmpdir"
   fi && mv "$tmpdir" "$dest" || rm -rf "$tmpdir"
   ```

   A `git ls-remote` that returns an empty SHA for an explicitly-named
   branch means the branch does not exist upstream — surface a one-line
   diagnostic naming the source and the branch, decline to clone, and
   fall back to the CLI path for the remainder of this DISCOVER run.

   On success, prefer local reads under the new cache directory for the
   rest of this DISCOVER run. On clone failure, emit one line ("Couldn't
   clone <source_id>; falling back to gh/git CLI") and proceed with the
   CLI fallback documented in "Tool preference" below — do not abort
   DISCOVER on a cache failure.

   On decline, proceed with the CLI fallback. Do not re-prompt within
   this DISCOVER run; the user's "no" is sticky for the session.

   This step catches users who declined the offer at `engine-bootstrap`
   Step 3.5, who deleted their cache via `/skill-engine:clean-cache`,
   who added a source post-bootstrap, or whose cache directory was lost
   for any other reason. A cache hit (existing match for `<source_id>-*/`
   with a valid `.git/` inside) skips the prompt entirely.

## Tool preference for git-managed sources

For each in-scope source, you decide how to read its content. Prefer
the `gh` / `git` command-line tools over WebFetch when the source has
`kind: git-managed`:

- `gh repo view <owner>/<repo>`, `gh api repos/<owner>/<repo>/contents/<path>?ref=<ref>`,
- `git ls-tree --recursive <ref>`, `git show <ref>:<path>`.

The `<ref>` token resolves to the source entry's `branch` field when
present, else `HEAD`. Reference SHAs cite the resolved commit on that
ref, not the repo-wide default.

The CLIs return clean structured output; WebFetch returns rendered HTML
that consumes roughly 10× more tokens to parse. Reserve WebFetch for
`kind: external-doc` (per [`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md)) or for git
sources where CLI access fails.

## Source materialization (optional local cache)

The engine facilitates a local cache; the author orchestrates the
clone. The recommended cache location is:

```
~/.cache/skill-engine/<source_id>-<sha>/
```

This follows the XDG cache-directory convention (`~/.cache/<tool>/`)
used by `gh`, `cargo`, and most modern CLI tooling on macOS and Linux.
`source_id` is the entry's id from `research/source-paths.json` and
`<sha>` is the per-source SHA from the cache contract (see
`engine-bootstrap/SKILL.md` and [`08-discover-pipeline.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/08-discover-pipeline.md)).

The engine does not clone without consent. Pre-flight step 6 above is
the consent point at DISCOVER time; `engine-bootstrap` Step 3.5 is the
consent point at scaffold time. When the user replies `y` to either
prompt, the skill itself runs the documented
`git clone --depth=1 --filter=blob:none <url> ~/.cache/skill-engine/<source_id>-<sha>/`
on the user's behalf; otherwise the cache directory simply remains
absent and reads fall back to the CLI tools above. The user may also
clone manually at any time (or choose a different cache location) —
the prompts are a convenience, not a requirement.

If the cache directory exists when you start, prefer a local read
over remote CLI calls; if absent, fall back to the CLI tools above.

## Lifecycle handling

For each in-scope source, decide whether its upstream is still
`reachable`, `moved`, `removed`, or `unknown` (see
[`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md) for the four-state field). If you
detect a transition:

- Update `source-paths.json` immediately (the file is the single
  source of truth for `lifecycle.state`).
- If the transition would affect existing reference files or the
  navigator (a `moved` URL is cited; a `removed` source is
  referenced), emit a lifecycle sweep dry-run per [`04-delivery.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/04-delivery.md).
  The user accepts or rejects the sweep through the protocol
  documented there (proposal-token + per-file SHA integrity gates).
- Conservative default: any non-zero probe exit maps to `unknown`,
  not `removed`. Auto-flipping `archived` is prohibited — the user
  sets it.

## Discovering essence

You have license to choose what to cover and at what depth. Reasoning
aids that may help (resolve them under the plugin root —
`$CLAUDE_PLUGIN_ROOT/data/` when the engine is installed as a plugin,
or `plugin/skill-engine/data/` when consumed from a checkout — and
read at your discretion, ignore as you see fit):

- `data/public-orgs.json` — known-public scope allowlist per
  ecosystem; useful when distinguishing integral first-party scopes
  from generic open-source dependencies.
- `data/popular-names.json` — top-N most-popular bare names per
  ecosystem; useful when deciding whether a dependency is commodity
  vs. worth a reference.

The engine does not require you to use them and does not require any
particular procedural shape. It requires that the references you emit
satisfy the four invariants and that the named checks in `verify.sh`
pass.

## Proposal threshold

**Default = propose, not exclude.** When a candidate companion source
is plausibly within the contextualizer's domain, surface it in
**Proposed companions** in the post-run summary, not Skip-reasoning.
The user's approval gate (the `status: "proposed" → confirmed/rejected`
flip in `source-paths.json`) is the filter. Pre-filtering by agent
judgment defeats the design: a silent exclusion narrows the catalog
without the user ever seeing the call.

**Skip-reasoning is for clear non-fits** — off-domain repos, unrelated
forks, accidental name collisions, archived/abandoned candidates. It
is not the bucket for "I judged this shouldn't be a separate
reference." That judgment belongs to the user.

**Named exception: different-language ports.** Same-domain,
different-language ports (e.g., a JS port of a Python project) are
candidates — do not skip them. Surface them in **Proposed
companions** with `recommend: reject` and the following rationale,
verbatim: "Different-language port — typically belongs in its own
contextualizer because the navigator's `description` field drives
invocation; if mixed in, queries about the ported language fire the
wrong skill. Recommend rejecting unless your navigator serves
polyglot authors." The user makes the call.

**Docs repos and higher-level packages layered on the core are not
language ports.** Propose them by default. Their content is distinct
signal from the source code — docs repos carry tutorial and concept
scaffolding; layered packages carry their own API surface — and the
user is the right one to decide whether they warrant a reference.

## Markdown style for emitted references

Reference files emitted by DISCOVER use **soft wrapping**: one paragraph
per line, no hard line breaks at fixed column widths. Editors and
rendered Markdown reflow paragraphs at viewport width. Do not insert
manual line breaks within a prose paragraph to keep lines under ~80
columns — that produces mid-sentence breaks in rendered output, makes
diffs noisier, and is inconsistent with the soft-wrapping convention
used by the example contextualizer at [`examples/library-context/`](https://github.com/nick-railsback/skill-engine/tree/main/examples/library-context).

Code blocks, tables, bullet lists, and headings follow their own
conventions; this directive applies only to prose paragraphs. The
prose in this SKILL.md file itself is hard-wrapped for legacy reasons
and is NOT the style to imitate — the example contextualizer at
[`examples/library-context/SKILL.md`](https://github.com/nick-railsback/skill-engine/blob/main/examples/library-context/SKILL.md) is the style to imitate.

## Post-run summary

At end-of-run, produce a paragraph-form summary for the author with
four components (no multi-column tables, no interactive menus):

1. **Coverage report.** Explicit enumeration of what you covered:
   "I read N files. The codebase's essence is X. I wrote Y references
   covering A, B, C…" or equivalent. Cite sources by `source_id` and
   path; cite content by path+content-hash. If this run populated or
   read from a local clone cache, point at the location once at the end
   of the Coverage report (e.g., `Cached source clones at
   ~/.cache/skill-engine/<source_id>-<sha>/; run /skill-engine:status to
   inspect, /skill-engine:clean-cache to free disk.`).
2. **Skip-reasoning.** For files and companion sources you
   considered but excluded: "I deliberately skipped Z because… I
   considered companions P, Q and excluded them because…" Empty-skip
   case allowed — say so explicitly ("Nothing of note was skipped.").
   Reserve this bucket for clear non-fits (off-domain repos, unrelated
   forks, accidental name collisions, archived/abandoned candidates).
   If a candidate is plausibly in-domain, it belongs in **Proposed
   companions** with a rationale — even one that recommends against
   acceptance — not here. See `## Proposal threshold` above.
3. **Proposed companions.** For each companion source surfaced this
   run with `status: "proposed"` in `source-paths.json`, emit one
   line: what was proposed, a one-sentence rationale (mirror or
   summarize `discovered_via`), and the accept path — author edits
   `source-paths.json`, flips `status` to `confirmed` or `rejected`,
   then re-runs `/skill-engine:discover` to crawl accepted sources.
   Empty case allowed — say so explicitly ("No companions surfaced
   this run."). Recommend-against proposals (the canonical case is
   different-language ports per `## Proposal threshold`) belong here
   too — each carries an explicit `recommend: reject` clause in its
   rationale. Note the distinction from Skip-reasoning: any plausibly
   in-domain candidate lives here, even one you'd argue against; only
   clear non-fits go in Skip-reasoning.

   Example shape (illustrative — two entries, accept and reject):

   ```
   Proposed companions:
     - vite-plugin-react (github.com/vitejs/vite-plugin-react)
       recommend: accept
       Same-domain Vite plugin; navigator's description field
       already covers plugin-authoring queries.

     - vite-py (github.com/some-org/vite-py)
       recommend: reject
       Different-language port — typically belongs in its own
       contextualizer because the navigator's `description` field
       drives invocation; if mixed in, queries about the ported
       language fire the wrong skill. Recommend rejecting unless
       your navigator serves polyglot authors.
   ```
4. **Creative-input "rerun with hint" gesture.** End with an
   invitation: `If you'd like me to revise, tell me a hint and rerun:
   /skill-engine:discover --hint='<your hint>'` — for example,
   `--hint='you missed packages/plugin-vue'` or `--hint='include
   docs/guide/ at high priority'`. The `--hint` flag is consumed by
   the next session as additional context.

The summary is paragraph-form; ≤30 lines of text is typical. It is the
author's primary signal that your choices were defensible (coverage +
skip-reasoning) and that a lateral revision is one keystroke away
(creative-input gesture).

## Cadence

DISCOVER runs when the user invokes it — no daemon, no cron. Typical
rhythm: quarterly for mature contextualizers; on-demand when the
catalog-vs-asks gap is widening; opportunistically for fresh
contextualizers (first runs are welcome).

## Doctrine surface

- [`02-artifact-contract.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/02-artifact-contract.md) — the four invariants;
  `source-paths.json` thin schema; reference shape contract.
- [`04-delivery.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/04-delivery.md) — when to add DISCOVER; lifecycle sweep dry-run
  semantics; proposal-token + per-file SHA gates.
- [`08-discover-pipeline.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/08-discover-pipeline.md) — pipeline doctrine (one-pager).
- [`09-discover-config.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/09-discover-config.md) — persisted-state layout (thin per-source
  schema; cache contract).

## What this skill does NOT do

- It does not auto-clone proposed companion sources. The author runs
  `git clone` themselves into the cache location (or any chosen
  directory).
- It does not recurse companion discovery past depth-1. Single-hop
  limit by doctrine.
- It does not parse lockfiles (`package-lock.json`, `Cargo.lock`,
  `go.sum`). Manifests are input to your reasoning, not an enforced
  schema.
- It does not do live registry calls for commodity filtering by
  default.
- It does not auto-detect "archived" upstream state. The user sets
  `archived: true` manually on a source entry.
- It does not track inner-path changes on `moved` sources. The outer
  URL is rewritten on accept; inner-path drift is flagged for manual
  review.
- It does not auto-rewrite SHA-pinned URLs on moved sources to point
  at the new host's equivalent SHAs. SHA history may not transfer on
  org rename; stale source-shas are flagged in the dry-run for manual
  spot-check.
