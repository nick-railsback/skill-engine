# Usage modes

The [case-study series](./case-studies/) records specific real engagements
where skill-engine has been used. This file does the complementary job:
sketching the shapes the engine takes across different kinds of work, so a
reader landing here can recognize their own situation before reaching for an
example. None of the modes below describe a particular person; they describe
the role the engine plays when the work has a certain shape.

## Dropping into an unfamiliar codebase

A forward-deployed engineer joining a customer engagement, or any engineer
inheriting a codebase they did not write, often needs to be useful inside it
faster than reading the whole thing allows. The mode that fits is registering
the handful of repositories the role actually depends on — the core product
repo, a couple of adjacent services, the customer-facing documentation site —
and running `/skill-engine:discover` with a hint that names the work, not the
codebase. The contextualizer's job here is not encyclopedia coverage; it is
giving Claude enough of the right surface to be answer-grade on the questions
the role keeps getting asked. Drift detection through `/skill-engine:refresh`
matters more in this mode than in any other, because the cost of an outdated
answer in a customer conversation is paid in credibility.

## Onboarding into a large internal ecosystem

The same mechanism — registered sources, composed context, `refresh` as a
discipline — fits a newly-hired engineer onboarding into a company whose
ecosystem is too large to hold in one head. The orientation document the
company should have written and didn't is, in effect, what the contextualizer
becomes: not the canonical onboarding doc, but a navigable index that points
Claude at the right files, the conventional patterns, the shared packages
worth knowing about. The discipline that distinguishes this mode from the
forward-deployed one is `/skill-engine:self-audit` — internal ecosystems
accumulate stale links and abandoned conventions, and the audit surfaces them
before they propagate into Claude's answers. A morning `refresh` keeps the
contextualizer aligned with overnight commits.

## Evaluating competing options on equal terms

When the work is comparing protocols, vendors, or libraries against an
existing business context, one contextualizer per option — composed against
the business contextualizer — lets the comparison happen on a level surface.
Each option's contextualizer registers its own documentation and source
repositories; the navigator description per the WHEN-not-WHAT discipline
keeps the options from cross-firing. Asking Claude a question about fit then
pulls the business context plus only the relevant option, rather than a single
mega-contextualizer that tries to hold everything at once. The advantage is
operational: when one option drops out of the comparison, the corresponding
contextualizer simply stops being loaded — no merged config to unpick. This
mode describes a *shape* of evaluation; it does not endorse any specific
vendor or protocol.

## Bridging documented intent and deployed reality

A technically-adjacent reader — a product manager, a tech lead inheriting a
surface, anyone responsible for a roadmap they did not write — often needs to
hold *what the system was supposed to become* and *what the system actually
is* in the same view. The mode that fits is registering both: a `web-doc`
source for the strategy memos, planning decks, and post-mortems (with
`source_url` and `crawl_date` provenance so freshness is legible), and a
`git-managed` source for the platform code that ships against it. (The four
[source-kind discriminators](../CAPABILITIES.md#how-it-gets-built) —
`git-managed`, `external-doc`, `web-doc`, `local-path` — and the provenance
fields they carry are documented in the capabilities reference.) A single
prompt asking *where does the documented direction disagree with the deployed
architecture?* turns the navigator into a surfacer of seams — places where
intent and code drifted, places where code grew structure the documentation
never named. The output is not a recommendation; it is a list of disagreements
that a meeting can react to.

---

These are *shapes*, not stories. For specific engagements where one of these
shapes was real and concrete, see the [case studies](./case-studies/).
