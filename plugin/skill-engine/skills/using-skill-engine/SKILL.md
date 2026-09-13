---
name: using-skill-engine
description: When the user mentions skill-engine or "the engine" without naming a specific workflow, or wants first-run setup. Inspects `.claude/skills/*-context/` install state (and any pending `*-context.proposed/` proposals) across all three install levels, then dispatches to engine-bootstrap when no contextualizer exists, to discover / refresh / status / self-audit / new-reference when one is present, or asks which workflow when the choice is ambiguous.
---

# Using the skill engine

This is the entry-point skill. It detects whether the current directory holds a
contextualizer that has already been set up, and routes to the matching
workflow.

## Routing

When invoked, do the following in order. A contextualizer is installed at
one of three install levels: `~/.claude/skills/`, `~/.claude/local/skills/`,
or `<repo>/.claude/skills/` at the project level. The project level is not
only the directory sitting at the repository root — it reaches any nested
`.claude/skills/` below it, so a contextualizer can live beside the slice of
the code it describes. A contextualizer's `research/.research-state.json` is
the canonical setup-state marker.

Resolve what is installed with the script in
[`shared/locator-block.md`](../../shared/locator-block.md), the engine's one
root-resolution definition — this skill does not carry a root list of its
own. The script exits on both the nothing-found and the several-found-and-
none-named paths, so it leaves no count behind in a variable; run it with
its enumeration flag and read its stdout instead:

```bash
ctx_all=$(bash -s -- --all <<'LOCATOR'
# …the fenced script from shared/locator-block.md, verbatim, with its
# name="<name>" line substituted to name="" …
LOCATOR
) && ctx_count=$(printf '%s\n' "$ctx_all" | grep -c '^/' || true) || ctx_count=0
[ "$ctx_count" -gt 0 ] || ctx_all=""
ctx_root=$(printf '%s\n' "$ctx_all" | head -n1)
```

Exit 0 means the enumeration printed one absolute path per line, and
`ctx_count` is that line count. Any non-zero exit means none was found, so
`ctx_count` is 0 and what landed on stdout is the script's own diagnostic
sentence rather than a path — which is why `ctx_all` is cleared on that
branch before anything reads it.

### Pending-proposal pre-step (runs before case dispatch)

Before dispatching to a workflow, check for pending proposals — any
`*-context.proposed/` directory that DISCOVER or REFRESH left behind. A
proposal is always staged as a sibling of the live contextualizer it was
derived from, so the enumeration above is the input this needs and no
second search is required:

```bash
proposed_dirs=$(
  printf '%s\n' "$ctx_all" | while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    ls -d "${ctx%/*}"/*-context.proposed 2>/dev/null
  done
)
```

If any proposed dirs exist and the requested workflow is a **mutating**
one (`discover`, `refresh`, `new-reference`), surface a one-line note
naming each proposal and the three commands that gate its disposition,
then exit without dispatching (the note is the entire output):

```
Pending proposal at <path>. Run /skill-engine:review <slug>, /skill-engine:apply <slug>, or /skill-engine:discard <slug> before re-running discover/refresh.
```

Rationale: re-running DISCOVER or REFRESH while a proposed dir already
exists would either overwrite the pending changes silently or surface
a confusing diff. The user is the right one to decide whether to
promote, discard, or keep iterating; the router refuses to choose for
them. The pre-step short-circuits before any case-1/case-2/case-3/case-4
branch fires.

The **read-only** workflows (`status`, `self-audit`) are exempt: a
pending proposal is precisely the state STATUS exists to surface ("how
far has its review progressed"), and SELF-AUDIT's default path writes
nothing. SELF-AUDIT's opt-in fix flow does write to the live tree; the
hazard that creates — a later `/skill-engine:apply` promoting a
proposal staged before those fixes landed — is closed on the apply
side, whose live-tree gate (apply/SKILL.md § Pre-promotion gates)
refuses to overwrite a live file whose hash no longer matches the
manifest's `sha_before`. Dispatch them normally, prepending the
pending-proposal note above to the dispatch so the user still sees it.

Bootstrap (`engine-bootstrap`) is also exempt — it is explicitly
invoked to scaffold a new contextualizer and writes directly to the
live tree, not through the staging model.

1. **No contextualizer installed.** `ctx_count == 0` ⇒ this is a fresh
   project with no contextualizer yet. Route to **engine-bootstrap**:
   surface a one-line note that no `.claude/skills/*-context/` was found,
   then hand off to the `engine-bootstrap` skill to scaffold from
   templates.

2. **Contextualizer root present, state file absent or unparseable.**
   `[ ! -f "$ctx_root/research/.research-state.json" ]` OR
   `jq empty "$ctx_root/research/.research-state.json"` exits non-zero ⇒
   the state file is missing or corrupt. Surface a one-line diagnostic
   naming the path and the parse error, then route to
   **engine-bootstrap**, which pauses for explicit confirmation before
   overwriting any existing contextualizer files (its activation guard
   triggers on files-present, so a corrupt marker cannot bypass it).

3. **Multiple contextualizer roots present.** `ctx_count > 1` ⇒ surface
   the list and ask the user which contextualizer to operate on, or — when
   the request applies to all of them — rerun the locator with `--all` and
   operate on every path it enumerates. Do not guess which one was meant.

4. **State file present and parses.** Route to the workflow named in the user's
   invocation context. The five plugin-surfaced maintenance workflows are:

    - `refresh` — full freshness sweep across tracked resources
    - `new-reference` — register a new resource and create the reference
    - `discover` — goal-given scan that writes references for what matters
    - `status` — read-only freshness dashboard
    - `self-audit` — read-only drift audit

   The chapter doctrine in [`03-engine.md`](../../docs/03-engine.md) enumerates six workflows
   (REFRESH, SKILL, NEW, STATUS, DISCOVER, SELF-AUDIT). The plugin surface
   ships twelve skills: the five maintenance workflows above that this
   router dispatches to, plus the router itself, the scaffolder
   (`engine-bootstrap`), `clean-cache`, and the four review-workflow skills
   (`review`, `apply`, `discard`, `config-set`). The chapter's `SKILL`
   workflow — single-reference targeted update — is reachable via
   `new-reference` with an existing reference named in scope, so the two
   collapse to one plugin command. `clean-cache` and the four
   review-workflow skills are invoked directly, not routed through this
   entry-point skill (the pending-proposal pre-step above surfaces the
   `review` / `apply` / `discard` commands when a staged proposal exists).

   If the user did not name a workflow, render the menu from the engine
   chapter's "The menu" section and wait for the human to pick one.

## Doctrine surfaces

The full activation protocol (engine doctor, reflections, rejection-log
preflight) and the menu live in the engine chapter [`03-engine.md`](../../docs/03-engine.md) under
`## Activation` and `## The menu (six workflows)`. The orchestrator the
maintainer pastes into a fresh Claude Code session is the contextualizer's
navigator skill at `.claude/skills/<slug>-context/SKILL.md`, which is
stamped from one of the navigator templates under
`engine-bootstrap-templates/` by the `engine-bootstrap` skill.

Routing in this revision is the binary present-or-absent check above; a richer
compatibility audit is deferred to a later revision.
