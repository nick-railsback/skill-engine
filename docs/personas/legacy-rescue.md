# The Senior Engineer Rescuing a Legacy Application

> A 20-year-old codebase. No original builders. A one-month deadline. The
> founding-myth case for skill-engine.

## The scenario

Maria is a senior engineer on a scrum team at a mid-sized SaaS company. She's
an early adopter of AI-assisted development — comfortable with spec-driven
workflows (BMAD, Google Spec Kit) but also maintains her own
`marias-company-context` contextualizer, created through skill-engine, for day-to-day work in her company's
ecosystem.

## The moment

A major client requests new functionality on a 20-year-old internal
application — and they want it shipped in a month. The application is in a
language nobody on the current team is fluent in. The original builders left
the company years ago. There is no architecture document. There is no
inventory of what functionality the application already has. Previous
modernization efforts on similar systems took 3-4 quarters. The team has
two two-week sprints.

## The intervention

Maria runs a reverse-engineering workflow that extracts business requirements
from the legacy application and emits draft `PRD.md` and `architecture.md`
files that can be dropped into BMAD. The PRD is accurate — but the architecture document is generic. It describes the legacy app's endpoints in a vacuum, with no awareness of her
company's shared internal modules, microservice patterns, or dependency
management.

She runs the reverse-engineering workflow again, this time with her
`marias-company-context` skill loaded alongside it: *"The architecture.md
should be in full accordance with how modern applications work as defined
in the marias-company-context skill."*

## The result

The new `architecture.md` doesn't just describe the legacy app — it positions
the modernization plan inside her company's actual architecture, naming the
shared modules to reuse, the internal packages to depend on, the design system, and the conventions to follow. Reading through it, some of her teammates actually learn things about their own ecosystem they didn't previously know. The team implements and ships the modernization in the following sprint. The client is retained.

## Why it works

- **[Multi-source synthesis](../../CAPABILITIES.md#how-it-scales):** Maria's contextualizer already contained her codebase's context formatted to optimize agentic navigation through that context.
- **[Composability](../../CAPABILITIES.md#how-it-composes)**: contextualizers are project skills, so they are able to activate
  alongside other workflows without special wiring.
- **The architecture document a codebase never had** is the artifact in her
  hands at the end — auditable, version-controlled, reviewable by humans
  before it ships.

[← Back to all personas](./README.md)
