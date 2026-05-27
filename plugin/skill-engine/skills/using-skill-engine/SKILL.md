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
one of three install levels (`~/.claude/skills/`, `~/.claude/local/skills/`,
or `<repo>/.claude/skills/`); its `research/.research-state.json` is
the canonical setup-state marker.

Locate the contextualizer root by searching all three install levels:

```bash
ctx_roots=$(
  for root in "$HOME/.claude/skills" "$HOME/.claude/local/skills" "$PWD/.claude/skills"; do
    [ -d "$root" ] || continue
    find "$root" -mindepth 1 -maxdepth 1 -type d -name '*-context' 2>/dev/null
  done
)
ctx_count=$(printf '%s\n' "$ctx_roots" | grep -c .)
```

### Pending-proposal pre-step (runs before case dispatch)

Before dispatching to a workflow, check for pending proposals — any
`*-context.proposed/` directory that DISCOVER or REFRESH left behind
under the same three install roots:

```bash
proposed_dirs=$(
  for root in "$HOME/.claude/skills" "$HOME/.claude/local/skills" "$PWD/.claude/skills"; do
    [ -d "$root" ] || continue
    find "$root" -mindepth 1 -maxdepth 1 -type d -name '*-context.proposed' 2>/dev/null
  done
)
```

If any proposed dirs exist, surface a one-line note naming each one and
the three commands that gate its disposition, then exit without
dispatching to any workflow (the note is the entire output):

```
Pending proposal at <path>. Run /skill-engine:review <slug>, /skill-engine:apply <slug>, or /skill-engine:discard <slug> before re-running discover/refresh.
```

Rationale: re-running DISCOVER or REFRESH while a proposed dir already
exists would either overwrite the pending changes silently or surface
a confusing diff. The user is the right one to decide whether to
promote, discard, or keep iterating; the router refuses to choose for
them. The pre-step short-circuits before any case-1/case-2/case-3/case-4
branch fires.

Bootstrap (`engine-bootstrap`) is exempt from this gate — it is
explicitly invoked to scaffold a new contextualizer and writes
directly to the live tree, not through the staging model. The router
only short-circuits the workflows that operate on an already-stamped
contextualizer (`discover`, `refresh`, `status`, `self-audit`,
`new-reference`).

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
   **engine-bootstrap** so the maintainer can re-scaffold over the broken
   substrate (the bootstrap workflow surfaces an existing-files warning
   before overwriting).

3. **Multiple contextualizer roots present.** `ctx_count > 1` ⇒ surface
   the list and ask the user which contextualizer to operate on. Do not
   guess.

4. **State file present and parses.** Route to the workflow named in the user's
   invocation context. The five plugin-surfaced maintenance workflows are:

    - `refresh` — full freshness sweep across tracked resources
    - `new-reference` — register a new resource and create the reference
    - `discover` — goal-given scan that writes references for what matters
    - `status` — read-only freshness dashboard
    - `self-audit` — read-only drift audit

   The chapter doctrine in [`03-engine.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/03-engine.md) enumerates six workflows
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
preflight) and the menu live in the engine chapter [`03-engine.md`](https://github.com/nick-railsback/skill-engine/blob/main/plugin/skill-engine/docs/03-engine.md) under
`## Activation` and `## The menu (six workflows)`. The orchestrator the
maintainer pastes into a fresh Claude Code session is the contextualizer's
navigator skill at `.claude/skills/<slug>-context/SKILL.md`, which is
stamped from one of the navigator templates under
`engine-bootstrap-templates/` by the `engine-bootstrap` skill.

Routing in this revision is the binary present-or-absent check above; a richer
compatibility audit is deferred to a later revision.
