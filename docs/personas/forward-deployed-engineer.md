# The Forward-Deployed Engineer

> Answers wrong in a customer call. Reclaims credibility. Doesn't get
> blindsided again.

## The scenario

Hannah just made a lateral move from software engineer to forward-deployed
engineer. The role is new to her — and relatively new to the industry. She
reports to the director of innovation, who has been told by leadership to
deliver tangibles fast. Hannah worked in a subset of the codebase at her
previous role, but the rest of the ecosystem is only vaguely familiar.

## The moment

Third week in the new role. Hannah is on a customer call — a technical
deep-dive with the client's platform team. Someone asks how the product
handles a specific edge case in the auth layer. Hannah worked adjacent to
auth at her last position. She *should* know this. She answers confidently.
She is wrong. The customer catches it. Her director is on the call. He
says nothing — but she sees him type something into Slack.

## The intervention

That evening Hannah installs skill-engine. She points it at her team's core
repositories and the customer-facing documentation site. She runs
`/skill-engine:discover` with a hint that names her actual job: *"I'm
forward-deployed at customer accounts. Surface integration patterns, auth
flows, and the gotchas FDEs hit most often."* She accepts the discover
recommendation to add two adjacent repos to the contextualizer. The next
morning she runs `/skill-engine:refresh` before standup.

## The result

The next customer call goes differently. When the same kind of question
lands, Hannah pauses, asks Claude through her contextualizer, and answers
correctly with a specific file path and the relevant constraint. Over the
following weeks she starts pre-loading her contextualizer for every
customer engagement. She also begins finding inefficiencies — duplicate
auth flows across repos, undocumented patterns the team should standardize.
Her director starts asking her for the writeups.

## Why it works

- **[Goal-given DISCOVER](../../CAPABILITIES.md#how-it-gets-built)** lets her tune the contextualizer to her FDE role
  with a single hint, not a custom config.
- **[Drift detection + REFRESH](../../CAPABILITIES.md#how-it-stays-accurate)** keeps her contextualizer fresh through her
  morning routine, so the next customer call uses today's truth, not last
  month's.
- **[Multi-source synthesis](../../CAPABILITIES.md#how-it-scales)** spans codebase + customer docs + integration
  patterns in one navigator.

[← Back to all personas](./README.md)
