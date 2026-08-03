# Contextualizer selection and staging directory

How `discover` resolves which contextualizer to write to when more than one is installed, and how it stages every write through `$CTX_PROPOSED` instead of touching the live contextualizer directly.

### Selecting a contextualizer

A positional argument to `discover` primarily names a **registered
source id** (see "Targeted invocation" under Pre-flight below), so
contextualizer selection resolves in this order:

1. Run the locator above with `name` empty. If exactly one
   contextualizer is found, the positional argument keeps its primary
   meaning — a source-id filter inside that contextualizer.
2. If the locator lists multiple contextualizers and the positional
   argument matches one of the listed slugs (the directory name without
   `-context`), rerun the locator with that slug as `name` — the
   argument selected a contextualizer, and source scope stays
   unnarrowed. If the selected contextualizer then also registers a
   source id equal to the same argument, ask the user which they meant;
   do not guess.
3. If the locator lists multiple contextualizers and the argument
   matches none of their slugs, surface both namespaces — the
   contextualizer list and a note that the argument matched no slug —
   and exit.

The slug grammar matches `review`/`apply`/`discard`: `<name>` is the
contextualizer directory name without the `-context` suffix.

`$CTX_PROPOSED` is the **staging directory** that mirrors the live
contextualizer's structure. DISCOVER and REFRESH write to it instead
of `$CTX_ROOT`; the live skill is untouched until the user runs
`/skill-engine:apply <name>` to promote the proposal. See the next
subsection.

Read every subsequent `research/foo` path as `$CTX_ROOT/research/foo`
**for reads**, and `$CTX_PROPOSED/research/foo` **for writes**. Same
asymmetry for `references/foo`, `SKILL.md`, and `verify.sh`. The
exception is `~/.cache/skill-engine/...` — upstream-source clones land
in the live cache, not in the proposed dir (the proposed-dir model is
about contextualizer-internal writes, not the upstream-source cache).

### Staging directory

The proposed directory sits as a sibling of the live contextualizer:

```
<install>/<slug>-context/             ← live (untouched by DISCOVER/REFRESH)
<install>/<slug>-context.proposed/    ← staging (this run writes here)
```

For project- and user-level installs `$CTX_PROPOSED` resolves under
`.claude/skills/`, so a user `deny` on `.claude/**` or a tightened sandbox
blocks staging writes just as it blocks live writes. **If a write into
`$CTX_PROPOSED` is rejected** — a denied `Write`/`Edit` or a non-zero /
`EPERM` exit under a restricted sandbox — do not retry blindly or skip the
file. Emit the sandbox-block diagnostic per
[`04-delivery.md`](../../../docs/04-delivery.md)
§ "When a `.claude/skills/**` write is blocked": name the exact path, the
scoped `sandbox.filesystem.allowWrite` (or remove-`deny`) remedy, and the
retry (`/skill-engine:discover` or `/skill-engine:refresh`).

Two cases for how `$CTX_PROPOSED` is populated:

- **First run** (no prior DISCOVER against this contextualizer; `$CTX_ROOT/references/` is empty): create `$CTX_PROPOSED/` from scratch with the full set of generated files. The promoted apply lands the first reference set into the live tree.

- **REFRESH-against-existing** or **incremental DISCOVER**: `$CTX_PROPOSED/` is a shallow copy-on-write. Files this run regenerates are written under `$CTX_PROPOSED/`; files left untouched are not copied — the manifest (see below) records them as `unchanged`, and `/skill-engine:apply <name>` leaves the corresponding live files alone.

At the end of every DISCOVER or REFRESH run, after `verify.sh` passes against the merged post-apply view (see § Post-run summary — the proposed tree is sparse, so verify runs against an ephemeral merge of live + this run's changes, not against `$CTX_PROPOSED/` directly), write `$CTX_PROPOSED/.review/manifest.json` with `schema_version: 1` and one entry per file in the contextualizer:

```json
{
  "schema_version": 1,
  "entries": [
    { "path": "references/foo.md", "status": "added",    "sha_before": null,      "sha_after": "abc1234" },
    { "path": "references/bar.md", "status": "modified", "sha_before": "def5678", "sha_after": "9abc012" },
    { "path": "references/baz.md", "status": "removed",  "sha_before": "11112222","sha_after": null },
    { "path": "research/source-paths.json", "status": "unchanged", "sha_before": "33334444", "sha_after": "33334444" }
  ]
}
```

Null-field convention is pinned: `status: "added"` ⇒ `sha_before: null`; `status: "removed"` ⇒ `sha_after: null`; `status: "unchanged"` ⇒ both shas populated and equal.

**Removed-detection is deterministic, not agent-recall.** When finalizing the manifest, enumerate the live `$CTX_ROOT/references/` baseline rather than relying on the agent to remember what it dropped. Any live reference the proposed navigator's catalog no longer cites — its catalog row was removed or rewritten away this run — is recorded as a `removed` entry (`sha_before` = the live file's content-hash, `sha_after: null`), even when this run never wrote to the proposed tree for that path. A live reference the proposed catalog still cites is `unchanged`; one it no longer cites is `removed`. Without this diff, a regeneration that simply stops emitting a reference would leave the live file (and its orphaned catalog absence) in place indefinitely, surfacing only later as a Check 4 (catalog↔references bijection) failure.

Also stamp the `REVIEW.md.template` into `$CTX_PROPOSED/.review/REVIEW.md` so the user has the predict-then-compare scaffold to fill. The template ships in the plugin's `engine-bootstrap-templates/` directory; resolve it at runtime as `$CLAUDE_PLUGIN_ROOT/engine-bootstrap-templates/REVIEW.md.template` (the same convention `engine-bootstrap` uses for the navigator templates). Stamp it with one substitution: the literal token `<name>` in the template body becomes the contextualizer slug without the `-context` suffix (e.g., for `$CTX_ROOT = ~/.claude/skills/vitejs-vite-context/`, `<name>` ⇒ `vitejs-vite`).

Three commands gate the promotion: `/skill-engine:review <name>` inspects the manifest and opens `REVIEW.md`; `/skill-engine:apply <name>` promotes the proposed dir to live; `/skill-engine:discard <name>` removes the proposed dir without promoting. The user signs off in `REVIEW.md` Step 3 before `apply` will run.
