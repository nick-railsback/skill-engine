# The Newly-Hired Engineer

> Drops into an enterprise SaaS codebase with a 6-12 month onboarding
> tradition. Becomes a leading contributor in his first sprints.

## The scenario

Bobby was just hired as an engineer at a SaaS enterprise company with
a vast and complex software ecosystem. Leadership there estimates 6-12
months for a new hire to ramp before delivering real value. His onboarding
period — a few days of reading the Onboarding Docs repo — was painful: dry
prose, 404 links, four-year-old screen recordings with no mention of what's
been added since. He diligently bookmarked the core repositories: CMS,
billing, advertising, design system, internal modules, shared scripts, CI
workflows.

## The moment

His new team is going through an AI transition. Leadership has mandated
AI-first development. Adoption across the team is uneven — some excited,
some resistant, most without the skill sets to fully use the tooling they've
been given. Bobby gets his first ticket: update an endpoint to return new
data. He has the acceptance criteria. He has no idea where to start.

## The intervention

Bobby installs skill-engine, feeds it the repositories he bookmarked, and
runs:

```
/skill-engine:discover I've just been hired to manage these repos. Lean toward
reusing existing shared components and design-system primitives. Identify when
an existing pattern is an anti-pattern that should NOT be propagated. Important
topics: architecture, maintainability, duplication, UX signals, performance,
security, reliability, testing, consistency, documentation, technical debt,
and strategic fitness.
```

The initial discover finishes and recommends additional repositories for
crawling. Bobby accepts. His `saas-ecosystem-context` skill now maps to
dozens of markdown files across the whole ecosystem. He runs
`/skill-engine:self-audit`, which catches some broken internal links and
fixes them. Every morning before standup, he runs `/skill-engine:refresh`
to catch overnight commits.

## The result

Bobby paste-bombs his first ticket's acceptance criteria into Claude with
his contextualizer loaded. The task is done in minutes — and Claude points
him at the actual OpenAPI specs to verify his request shape. Wanting to
stress-test, he asks Claude to enumerate every way this change could be
tested in his company's ecosystem. He uses that list to test the feature
end-to-end on non-prod the same afternoon. His PR is approved with minimal
feedback. He becomes one of the team's leading contributors before his
60-day review.

## Why it works

- **[Goal-given DISCOVER](../../CAPABILITIES.md#how-it-gets-built)** lets him tune the contextualizer to his job
  description in plain English.
- **[SELF-AUDIT](../../CAPABILITIES.md#how-it-knows-its-still-right)** catches the broken links and stale references his
  contextualizer would otherwise inherit from the company's actual docs.
- **[REFRESH as a morning routine](../../CAPABILITIES.md#how-it-stays-accurate)** keeps him current with overnight
  ecosystem changes — the maintenance cost is one command before standup.

[← Back to all personas](./README.md)
