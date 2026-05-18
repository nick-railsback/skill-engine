# skill-engine

**Teach Claude your codebase. Keep it taught.**

You get dropped into a codebase. No docs. No original builders. You ask Claude a
question and it gives you a textbook answer — correct for some repo, not for yours.

Skill-engine fixes that. It reads your repository, writes down what it finds, and
hands that context to Claude on every question. Your codebase, not the internet's
best guess.

**Same question. Two different realities.**

```
You: What's the convention for adding a new API endpoint here?

Claude: In most frameworks you'd register a route on the app object —
        Flask uses @app.route, FastAPI uses @router.get, Express uses
        app.get(). Check your framework's docs for middleware patterns.
```

```
You: What's the convention for adding a new API endpoint here?

Claude: Use register_route() in src/api/routing.py — that's the single
        entrypoint. The gateway middleware at src/api/gateway.py:42
        injects correlation IDs for every request, so bare @app.route
        decorators will silently skip tracing.
```

**→ [Get started in 2 minutes](#quickstart)**

## What this is

Anthropic publishes [a spec](https://resources.anthropic.com/hubfs/The-Complete-Guide-to-Building-Skill-for-Claude.pdf) for giving Claude reusable
skills — directories of markdown files Claude reads on demand. Skill-engine is the
operational infrastructure that makes that spec production-grade for real codebases:
multi-source synthesis, drift detection, reviewer gates, and a self-auditing eval
layer the spec never had to provide.

If pip is to PEPs what Kubernetes is to container primitives — skill-engine is that
layer for Anthropic's skill-directory pattern.

## Why I built this

The spec existed. Anthropic had published it: a skill maps to a directory of
reference markdown files Claude reads on demand. The pattern was sound. For
simple cases, it was enough.

But my actual work wasn't simple. A vast ecosystem — many repos, conflicting
conventions across teams, internal modules I needed Claude to know about every
day. Maintaining one skill folder by hand against a moving target wasn't
sustainable. The spec described a destination. It did not describe how to
build the road.

So I built a prototype of this engine. First for daily feature development. Then to identify
efficiency opportunities across the ecosystem. Then — once — to rescue a
20-year-old legacy application on a one-month deadline, when the original
builders were gone and the documentation didn't exist. Each use surfaced the
next gap the spec hadn't addressed: drift detection, multi-source synthesis,
reviewer gates, evaluation. Each gap is now closed.

## The load-bearing capability

Multi-source synthesis. Register N sources — git repositories, external docs,
local paths, a giant monorepo — and skill-engine emits a single navigator skill
that reasons across all of them. When Claude answers a question that touches
four sources at once, it holds the tensions between them: the older intent,
the newer correction, the constraint that overrides both.

Not because it works on any single source. Because it holds across all of them.

## What else is in the box

Multi-source synthesis was one of several gaps the spec left for an operator to
close. Each feature below is something Anthropic's published Agent Skills spec
does not ship.

**[Drift detection + REFRESH](./CAPABILITIES.md#how-it-stays-accurate).** Every source is pinned to its content hash at
ingest time. When upstream shifts, skill-engine notices and proposes updated
references for review. Your contextualizer never silently goes stale.

**[Goal-given DISCOVER](./CAPABILITIES.md#how-it-gets-built).** State what you're trying to do; the engine reads your
sources, decides what matters, and emits the references — validating its own
output against four invariants before surfacing it. Autonomous skill construction
with guardrails.

**[SELF-AUDIT](./CAPABILITIES.md#how-it-knows-its-still-right).** Five drift checks the skill runs against itself: stale dates,
broken URLs, long-untouched references, catalog-vs-content divergence,
cross-reference accuracy. The skill audits itself; you review the findings.

**[Reviewer-in-the-loop (by default)](./CAPABILITIES.md#how-human-review-fits).** The engine surfaces every proposed
change for review before applying it. The contents of a contextualizer become
Claude's source of truth for an entire domain — silent propagation of wrong
content is a worse failure than five minutes of review. Review-first is the
default; future versions may add opt-in autonomy flags for low-risk operations.

**[source-paths.json — a schema, not a config file](./CAPABILITIES.md#how-it-gets-built).** Three first-class source
kinds (`git-managed`, `external-doc`, `local-path`) with a machine-readable
schema other tools can conform to. The schema is the contract.

[**→ Full capabilities reference**](./CAPABILITIES.md)

## See it in practice

The legacy-rescue story is one shape skill-engine takes. Here are others.

- **[The Senior Engineer Rescuing a Legacy Application](./docs/personas/legacy-rescue.md)** —
  A 20-year-old codebase, a one-month deadline, no original builders. The
  founding-myth case.
- **[The Forward-Deployed Engineer](./docs/personas/forward-deployed-engineer.md)** —
  Answers wrong in a customer call. Reclaims credibility and never gets
  blindsided again.
- **[The Newly-Hired Engineer](./docs/personas/new-hire-engineer.md)** —
  Drops into an enterprise SaaS codebase with a 6-12 month onboarding tradition.
  Becomes a leading contributor in his first sprints.
- **[The Solutions Engineer](./docs/personas/solutions-engineer.md)** — Evaluates
  five competing agentic-payments protocols by spinning up one contextualizer
  per protocol and composing them against his business context.
- **[The Senior Product Manager](./docs/personas/senior-product-manager.md)** —
  Technical-adjacent, not a coder. Composes her predecessor's strategy memos
  with the live platform monorepo to surface where intent and reality have
  drifted — before championing the next roadmap.

Not your situation? [Open an issue](https://github.com/nick-railsback/skill-engine/issues)
describing how you'd want to use it.

## Where this is in its life

This is v0.1.1. There is one worked example, one maintainer who built it because
he needed it and it did not yet exist.

If you've ever stood in front of a codebase that outlived its authors, or
handed a junior engineer documentation you couldn't vouch for, you already
understand what this is for. The rest is just building.

## Quickstart

```
/plugin marketplace add nick-railsback/skill-engine
/plugin install skill-engine@skill-engine-marketplace
/skill-engine:engine-bootstrap https://github.com/<your-org>/<your-repo>
/skill-engine:discover
```

Twenty minutes from a fresh Claude Code session to a working contextualizer.
[Full quickstart →](./plugin/skill-engine/docs/quickstart.md)

## Doctrine and dependencies

Skill-engine sits in the category I'd call **Skill Infrastructure** — operational
tooling on top of Anthropic's published Agent Skills spec. The full doctrine
lives in [docs/doctrine.md](./plugin/skill-engine/docs/doctrine.md).

Dependencies: bash, git, `jq`. No Node, no npm, no scheduler. The default
cadence is manual; reviewer-in-the-loop is the default operating mode. Both
defaults are deliberate — and revisable as the project matures.
