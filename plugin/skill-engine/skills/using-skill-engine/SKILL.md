---
name: using-skill-engine
description: When the user invokes any engine workflow from a contextualizer directory and the appropriate sub-workflow needs to be selected based on the directory's setup state.
---

# Using the skill engine

This is the entry-point skill. It detects whether the current directory holds a
contextualizer that has already been set up, and routes to the matching
workflow.

## Routing

When invoked, do the following in order. A contextualizer is installed at
`.claude/skills/<slug>-context/`; its `research/.research-state.json` is
the canonical setup-state marker.

From the project working directory (the parent of `.claude/`), locate the
contextualizer root:

```bash
ctx_roots=$(find .claude/skills -mindepth 1 -maxdepth 1 -type d -name '*-context' 2>/dev/null)
ctx_count=$(printf '%s\n' "$ctx_roots" | grep -c .)
```

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
   ships five distinct slash-commands plus the router, the scaffolder,
   and `clean-cache` (eight skills total): the chapter's `SKILL` workflow
   — single-reference targeted update — is reachable via `new-reference`
   with an existing reference named in scope, so the two collapse to one
   plugin command. `/skill-engine:clean-cache` is invoked directly, not
   routed through this entry-point skill.

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
