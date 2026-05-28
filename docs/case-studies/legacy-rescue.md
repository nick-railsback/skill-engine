# Legacy rescue

A twenty-year-old application. A one-month window to ship a modernized application with new functionality a
major client had asked for. No original builders left in the company — not on
the team, not down the hall, not on a Slack channel anyone remembered. No
architecture document, no PRD, no inventory of what the application did —
there was only code. Nobody at the company could describe the full surface or
how it had been built; the codebase had outlived the people who could vouch
for it. Comparable
modernizations elsewhere in the industry had run multiple quarters. The team
had two two-week sprints.

The shape of the problem was not "the codebase is large." Large is a tractable
problem; you read more of it. The shape was: *the team had to ship against a
system no one could describe, and there was no surviving authority to describe
it.* Producing the documentation by hand was not a one-month problem — it was
the problem the month was supposed to *solve*. Producing one by hand would have meant spending
the deadline writing the artifact that was supposed to make the deadline
possible.

The rescue described here was done with a domain-specific predecessor tool I built
inside that company — purpose-built for its codebase and not portable. This
public skill-engine is a separate, general-purpose tool I built afterward from
the same ideas, with capabilities the prototype never had. The predecessor was
already in daily use against the company's own ecosystem: a contextualizer
mapping the internal modules, shared packages, microservice conventions, and
design-system primitives the team's other applications were built on. That
contextualizer existed because I had built it for routine feature work — by
the time the rescue landed, dozens of engineers across the company had been
using it as a daily tool, with a handful of product managers and owners
reaching for it during discovery and ideation. By the time I left the company
it had spread to roughly two-thirds of engineering, somewhere around two
hundred of three hundred. The rescue used the
contextualizer as raw material, not as a target; the rescue is also what made
the rest of engineering notice it.

The team itself had not done spec-driven development before — the
modernization was going to be their on-ramp to it, not just a deadline. A
colleague had been building a separate workflow that read a running
application and extracted draft `PRD.md` and `architecture.md` files from it —
reverse-engineering the system into the artifacts BMAD would expect on the way
in. Run against the legacy application, that workflow produced a PRD that was
plausibly correct and an architecture document that was generically correct
and locally useless: it described the legacy app's endpoints in a vacuum, with
no awareness that the company already had shared modules the modernization
should reuse, conventions the modernization should follow, or packages the
modernization should depend on rather than reimplement.

I composed the two — the colleague's extraction workflow and my company
contextualizer — and re-ran the extraction with a single steering line:
`"the architecture.md should be in full accordance with how modern
applications work as defined in the contextualizer."` One sentence, written
into the prompt as a hard constraint. The composition was the move. The contextualizer
produced the architecture that named the real modules, packages, and
conventions; the team built and shipped against it the following sprint. Hand-
editing the generic version into the company-specific one would have cost the
month; composing two tools that already existed cost an afternoon.

The composition produced the artifact; the team still had to learn to use it.
I embedded with the team through the first of the two sprints — the one they
spent learning spec-driven development on this engagement's specifics: how
the architecture document's named modules and conventions translated into
implementation decisions, where the BMAD workflow's unfamiliar parts caught
them, where the spec and the legacy code disagreed and what to do about it.
By the end of that sprint they were running the workflow themselves. The
second sprint, in which they implemented and shipped, they did on their own.
The architecture document was the deliverable from the engine's side; the
embedded sprint was the deliverable from mine — and the team shipping without
me afterward was the test that both had landed.

The architecture document that came out of that composition was not a
description of the legacy app. It was a plan for the modernization, written
against the company's actual architecture: which shared modules to reuse,
which internal packages to depend on, which design-system primitives the new
surface would inherit, which conventions the implementation would follow. It
named things by their real names. It was the document the codebase had never
had — and the kind of document that is supposed to predate an application but,
in this case, was instead going to enable one.

I remember watching teammates read through the document
and respond on two registers: rediscovering conventions they had forgotten,
and learning facts about their own ecosystem they had not known, which they
then went off to verify and confirmed were real. The contextualizer had no
privileged knowledge — every claim came from sources the team itself owned
— but the document was naming those sources back to them in a way the team
had stopped, or never started, being able to see. The composition let the
team rebuild from inside their own ecosystem rather than from outside it.

Comparable modernizations elsewhere had run multiple quarters; this one
shipped the following sprint, and the client was retained. That is the
defensible shape of the outcome. The rest of the math — the counterfactual
cost, the engagement value, the multi-quarter alternative — belongs in a
private channel where I can defend the assumptions live, not nailed to a
public wall.

The contextualizer that worked here was bespoke — built inside that ecosystem,
for that codebase, not portable. What survived the engagement was not the tool
but the move: register the sources you actually depend on, compose them with
the workflow that needs them, steer the model with one sentence that names
which side wins on conflict. That move is what this public repo generalizes —
a tool that lets a maintainer build a contextualizer in any domain they
choose, rather than the one domain a bespoke version is fused to. Most of the
engine's capabilities followed from generalizing rather than preceding it:
[multi-source synthesis](../../CAPABILITIES.md#how-it-synthesizes-across-sources)
holding across [four first-class source kinds](../../CAPABILITIES.md#how-it-gets-built),
the [coverage-testing discipline](../../plugin/skill-engine/docs/13-coverage-testing.md)
that keeps a contextualizer's prose anchored to upstream sources rather than
paraphrased, and [DISCOVER](../../CAPABILITIES.md#how-it-gets-built) plus
[SELF-AUDIT](../../CAPABILITIES.md#how-it-knows-its-still-right) as workflows
the bespoke version never had to provide.

The contribution chain matters here, because it is easy to overclaim and
nothing in this case study should. The contextualizer produced the
architecture document. The team built and shipped the application from that
document the following sprint. The engine's hand stops at the architecture;
the team's hand built the rest. Naming where the engine stops is the
credibility signal — the engine did the part it actually did, and the team did
the part they actually did, and the engagement worked because both happened.
