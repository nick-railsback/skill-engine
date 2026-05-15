# skill-engine

**Teach Claude your codebase. Keep it taught.**

You maintain something with a lot of canon — a monorepo, a framework, a docs
site. There's a CLAUDE.md, a best-practices doc, conventions everyone on the
team knows. When you ask Claude for help, you re-explain that canon every
time. Claude still drifts: wrong file paths, outdated patterns, suggestions
that violate rules you wrote down two years ago.

skill-engine builds Claude a curated index of your project — the files that
matter, organized so Claude reads only what's relevant to the question. You
point it at your repo once. It produces a Claude skill that knows your
canon. When the repo changes, you re-run it; the index stays accurate.

## A real example

> A 90-second receipt — what one Claude Desktop session looked like with
> `astro-context` and `langchain-context` both loaded.

Asked Claude — with `astro-context` and `langchain-context` loaded — to
brainstorm how a langchain agent layer could help the team that maintains
Astro, scored on weighted-shortest-job-first. The reply substituted two of
the four candidates I'd seeded ("onboarding nudges" folded into a broader
pre-flight agent; an issue-triage assistant beat the breaking-change pipeline
on size). The top-scored idea — a pre-flight PR agent that checks changeset
bump levels, explains CI failures, and welcomes first-timers — won on
frequency: every PR, every day, three days to build.

| # | Job | UBV | TC | RR/OE | CoD | Size | **WSJF** |
|---|---|---|---|---|---|---|---|
| 1 | Pre-flight PR agent (changeset bump-level check + CI-failure explainer + first-timer welcome) | 8 | 5 | 5 | 18 | 3 | **6.0** |
| 2 | Issue triage assistant (duplicate detection, p1–p5 suggestion, needs-repro lifecycle) | 5 | 5 | 5 | 15 | 3 | **5.0** |
| 3 | Migration-guide first-draft from changesets at major-bump time | 13 | 2 | 5 | 20 | 5 | **4.0** |
| 4 | Breaking-change advisory pipeline (core PR → integration-author notice) | 13 | 8 | 8 | 29 | 8 | **3.6** |
| 5 | Integration-PR contract triage against the 11 lifecycle hooks | 8 | 3 | 5 | 16 | 5 | **3.2** |

Inside the pre-flight recommendation, the reply flags
`.github/workflows/congrats.yml` as a workflow the agent must NOT duplicate;
notes that `dorny/paths-filter` is already used in `ci.yml` and the agent
should compose with it rather than invent its own routing; and proposes a
`create_agent` with `before_model` middleware as the architectural shape —
one model call, narrow tool surface, scoped per PR.

> The reply cites the fixture-`outDir` trap — tribal knowledge that lives
> nowhere in `CONTRIBUTING.md`, captured only by the contextualizer. Without
> it, the answer would have been a generic "check your test fixtures" nudge.
> The contextualizer is the difference.

*From the reply, on the migration-guide draft idea (#3 above):*

> *This is the natural fit for `create_deep_agent`: it needs planning (outline
> the doc structure), filesystem (write the MDX file in the docs repo's
> expected location), and sub-agents (one per major surface — content layer,
> transitions, server islands — each writing its own section in parallel).*

[Full conversation with both contextualizers loaded →](./plugin/skill-engine/docs/examples/astro-langchain-conversation.md)

## What just happened

What you just saw is a **contextualizer** — a curated index of your codebase
that Claude reads before it answers. skill-engine helps you build one; you
and your team maintain it.

## Who this is for

skill-engine builds the context; you and your team own and maintain it, the
same way you own your CONTRIBUTING.md. It's for engineers maintaining a body
of knowledge — code, docs, framework, ecosystem — who want Claude to be
opinionated about it. Platform and DX engineers standardizing internal AI
workflows. Solo builders with a serious-enough corpus that manual
`grep`-and-pray has stopped scaling. OSS maintainers wanting to ship
contributors a "here's what Claude needs to know about our project" artifact.

## What you're actually adopting

This is your team's living context. You own it, you shape it, it grows with
your codebase. skill-engine ships the tooling; you ship the freshness.

Maintenance is concrete work: keep the engine plugin updated; run `refresh`
when the codebase shifts so the index catches up; review the proposed diffs
before they land; decide when to override the engine's defaults. It isn't a
heavy lift, but it isn't zero.

This is intentional: a context maintained by strangers is a context you can't
trust.

## Not for you if

- You want automated re-indexing, vector search, or a hosted service.
- You want the tool to write docs *for* you (it maintains, doesn't author).
- You won't read the proposed diffs. The reviewer is load-bearing; if nobody
  reviews, the index drifts and the trust collapses.

## Why these constraints (engineering taste, not apology)

The constraints below are the contract. Each is a stance, not a limitation
flagged for a future lift. Together they keep the tool boring in the places
where boring is the win.

- bash + markdown + JSON, no third-party deps
- No cron, no daemon, no auto-merge
- Reviewer-in-the-loop on every change
- Manual cadence is load-bearing

## Start here

- **Quickstart** — install the plugin, build your first contextualizer, run
  a refresh: [docs/quickstart.md](./plugin/skill-engine/docs/quickstart.md).

## How it works

Two pieces. The **engine** is this plugin: a small set of slash-command
workflows that build a contextualizer, keep it current, and surface what's
on disk. The **contextualizer** is the artifact those workflows produce — a
curated index of one codebase, owned by the team that ships that codebase.

Eight workflows ship with the plugin, in roughly the order you'll meet them:
`engine-bootstrap`, `discover`, `refresh`, `new-reference`, `status`,
`self-audit`, `clean-cache`, and the `using-skill-engine` router that
dispatches any "do something with the engine here" intent to the right
workflow. A local-clone cache backs discovery and moves through four named
stages: seed (opt-in) → REFRESH GC → STATUS → `clean-cache`.

See [`examples/library-context/`](./examples/library-context/) for a worked
example of the contextualizer artifact's shape — built around Flask, renamed
to the generic `library-context` to highlight the engine's shape rather than
Flask itself; see [11-walkthrough.md](./plugin/skill-engine/docs/11-walkthrough.md) for the narrative
behind it.

## Doctrine

A short log of the load-bearing decisions behind skill-engine — the calls
made when the path forked, why the project landed where it did, and what was
deliberately chosen not to build. [Read the doctrine →](./plugin/skill-engine/docs/doctrine.md).

## Install

skill-engine ships as a Claude Code plugin. From any Claude Code session,
register the repository as a marketplace and install:

```
/plugin marketplace add nick-railsback/skill-engine
/plugin install skill-engine@skill-engine-marketplace
```

After install, the plugin's slash commands
(`/skill-engine:engine-bootstrap`, `/skill-engine:discover`, and the others)
are available in any Claude Code session.

Dependencies: bash, git, `jq`. No Node, no npm, no scheduler.

**Working on the plugin source?** Clone the repo and register the local
directory as a marketplace instead:

```
git clone https://github.com/nick-railsback/skill-engine.git
cd skill-engine
/plugin marketplace add .
```

The plugin name and marketplace name don't change — the same
`/plugin install skill-engine@skill-engine-marketplace` works.
