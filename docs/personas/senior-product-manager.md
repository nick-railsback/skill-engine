# The Senior Product Manager

> Technical-adjacent, not a coder. Pressure-tests roadmap features against
> the platform's actual constraints before championing them upward.

## The scenario

Priya owns a product surface that sits between three engineering teams —
personalization, recommendations, and onboarding. Six years in product,
four at this company, the last eighteen months on this surface after
inheriting it from a predecessor who got promoted to Director. She uses
Claude Desktop daily. The handoff was generous: a Confluence space full
of strategy memos, quarterly planning decks, and post-mortems, plus
standing access to every team's repos.

## The moment

It's the Tuesday before quarterly planning. Priya is reviewing capability
requests from her three engineering partners and a phrase keeps catching
her ear: personalization wants "contextual user signals," recommendations
is scoping "session-aware ranking inputs," onboarding is proposing
"intent inference at first-touch." Three teams. Three pitches. They read
like they're describing the same primitive with three different names —
and none of them know it yet. Worse: she has a creeping suspicion her
predecessor saw this coming. There were memos. There was a doc called
*Unified Context Layer — Q3 thinking*. She remembers skimming it. She
can't remember what it concluded. Planning is in six days.

## The intervention

Priya registers two sources with skill-engine. The first is
`web-doc`: her predecessor's Confluence space, crawled (via
`crawl_mode: sitemap` where the space exposes a sitemap, otherwise
`crawl_mode: list` with an explicit `page_list`) — eighteen months of
strategy memos, planning decks, and retros, with `source_url` pointing
back to the live pages and a `crawl_date` so she knows what's stale. That's *intent* — the thread of what the surface was
supposed to become. The second is `git-managed`: the platform monorepo
where all three teams ship — services, schemas, feature flags. That's
*reality* — what the surface actually is. She runs the navigator with
one prompt: *where does the documented direction disagree with the
deployed architecture?* The output isn't a recommendation. It's a list
of seams — places where the memos assumed a shared context primitive
that the code never built, and places where the code grew structure the
memos never named. She walks into planning with the disagreements in
hand, asks the three tech leads to react to the same artifact, and the
conversation finally has a shared object instead of three vocabularies
talking past each other.

## The result

The three tech leads leave planning having converged on a single shared
context primitive — the one the predecessor's memos had named eighteen
months earlier — two teams extending it, the third consuming it rather
than reinventing. The navigator stays registered. When next quarter's
capability requests arrive, Priya re-runs it before her one-on-ones;
because each source is SHA-pinned and content-hashed, she sees at a
glance which memos and which services have moved since her last query.
The disagreements she brings to engineering aren't *hers* — they're the
artifact's, which makes them the conversation's, which makes them
solvable.

## Why it works

- **[Multi-source synthesis across substrates](../../CAPABILITIES.md#how-it-synthesizes-across-sources)** —
  a Confluence-exported memo archive and a live monorepo are not the
  same kind of source; skill-engine's navigator holds them together so
  disagreement between *intent* and *reality* becomes a visible,
  queryable artifact.
- **[Four first-class source kinds](../../CAPABILITIES.md#how-it-gets-built)** —
  `web-doc` registration with `source_url` and `crawl_date`
  provenance means Priya's predecessor's documentation participates as
  a first-class source, not as pasted-in context. The schema, not a
  one-off prompt, is what holds.
- **[Reviewer-in-the-loop](../../CAPABILITIES.md#how-human-review-fits)** —
  when the navigator surfaces a seam, it surfaces evidence (which memo,
  which service, at which SHA). Priya audits each finding before she
  takes it to her tech leads; nothing propagates unreviewed.

[← Back to all personas](./README.md)
